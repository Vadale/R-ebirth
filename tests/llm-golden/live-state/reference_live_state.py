#!/usr/bin/env python3
"""Independent F6a prefix goldens; run with the existing pinned golden venv.

No engine outputs are inputs. --check validates committed bytes, provenance,
recomputed values and adversarial controls without writing any fixture.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.metadata
import io
import json
import platform
from pathlib import Path
import sys

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SYNTHETIC = HERE.parent / "synthetic"
sys.path.insert(0, str(SYNTHETIC))

from reference_forward import (  # noqa: E402
    ACTIVATION_COMPONENTS,
    CHECK_ATOL,
    CHECK_RTOL,
    Intervention,
    STEER_VECTOR,
    gguf_weights_match_source,
    hidden_states,
    softmax_lastdim,
)
from synthetic_model import (  # noqa: E402
    CONFIG,
    INPUT_TOKENS,
    build_weights,
    canonical_gguf_path,
    package_fixture_path,
)

OUT = HERE / "goldens"
TOP = 5
# Existing synthetic native activation/logit tolerance, never tuned to live data.
ENGINE_ATOL = 1e-2
HEADERS = {
    "states.csv": ["case", "state_id", "token_pos", "token_id", "context_pos",
                   "source_pos", "source", "source_token_id", "prompt_token_count"],
    "activations.csv": ["case", "state_id", "layer", "component", "neuron", "value"],
    "logits.csv": ["case", "state_id", "token_id", "logit", "prob"],
    "top.csv": ["case", "state_id", "rank", "token_id", "logit", "prob"],
}
FLOAT_COLUMNS = {"value", "logit", "prob"}


def cases() -> list[dict]:
    # Indices in this specification are native zero-based and labelled as such
    # in the manifest. Both deliberately ablates a coordinate that was steered.
    def case(name, prompt, count, steer=False, ablate=None):
        return {"name": name, "prompt_tokens_native": prompt, "state_count": count,
                "steer_layer_native": 1 if steer else None,
                "steer_vector": STEER_VECTOR.tolist() if steer else [],
                "ablate_native": ablate or []}

    long_prompt = (INPUT_TOKENS * 65)[:513]
    return [
        case("baseline", [1, 7], 4),
        case("steer", [1, 7], 4, steer=True),
        case("ablate", [1, 7], 4, ablate=[{"layer": 0, "neurons": [2], "value": 0.0}]),
        case("both", [1, 7], 4, steer=True,
             ablate=[{"layer": 0, "neurons": [2], "value": 0.0},
                     {"layer": 1, "neurons": [2], "value": 0.25}]),
        case("long_prefill", long_prompt, 2),
    ]


def intervention(spec: dict) -> Intervention:
    steer = {} if spec["steer_layer_native"] is None else {
        spec["steer_layer_native"]: np.asarray(spec["steer_vector"], dtype=np.float32)}
    ablate = {item["layer"]: (item["neurons"], item["value"])
              for item in spec["ablate_native"]}
    return Intervention(steer=steer, ablate=ablate)


def ranked(logits: np.ndarray, top: int) -> tuple[np.ndarray, np.ndarray]:
    """Descending raw logit, ascending native ID on a tie; full softmax."""
    ids = np.arange(logits.size)
    order = np.lexsort((ids, -logits))[:top]
    return order, softmax_lastdim(logits)


def prefix(weights: dict, tokens: list[int], change: Intervention):
    capture = {}
    hidden = hidden_states(weights, tokens, capture=capture, intervene=change)
    return hidden @ weights["output.weight"].astype(np.float64).T, capture


def compute() -> tuple[dict[str, list], list[dict], dict]:
    weights = build_weights()
    tables = {name: [] for name in HEADERS}
    details = []
    first_states = {}
    min_shift = float("inf")
    min_margin = float("inf")
    for spec in cases():
        name = spec["name"]
        tokens = list(spec["prompt_tokens_native"])
        prompt_count = len(tokens)
        change = intervention(spec)
        generated, margins, shifts = [], [], []
        for state_id in range(1, spec["state_count"] + 1):
            all_logits, capture = prefix(weights, tokens, change)
            logits = all_logits[-1]
            order, probabilities = ranked(logits, TOP)
            selected = int(order[0])
            source_pos = len(tokens)
            assert source_pos == prompt_count + state_id - 1
            tables["states.csv"].append([
                name, state_id, state_id, selected + 1, source_pos + 1,
                source_pos, "prompt" if state_id == 1 else "generated",
                tokens[-1] + 1, prompt_count])
            for layer in range(int(CONFIG["n_layer"])):
                for component in ACTIVATION_COMPONENTS:
                    values = capture[(layer, component)]
                    for neuron, value in enumerate(values[-1]):
                        tables["activations.csv"].append([
                            name, state_id, layer + 1, component, neuron + 1, float(value)])
            for token_id, (logit, prob) in enumerate(zip(logits, probabilities)):
                tables["logits.csv"].append([
                    name, state_id, token_id + 1, float(logit), float(prob)])
            for rank, token_id in enumerate(order, 1):
                tables["top.csv"].append([
                    name, state_id, rank, int(token_id) + 1,
                    float(logits[token_id]), float(probabilities[token_id])])
            # Every fixture must distinguish the previous row from the source
            # row, even when successive generated vocabulary IDs are identical.
            shift = max(float(np.max(np.abs(value[-1] - value[-2])))
                        for value in capture.values())
            assert shift > 10 * ENGINE_ATOL, (name, state_id, "weak position guard", shift)
            shifts.append(shift)
            margin = float(logits[order[0]] - logits[order[1]])
            assert margin > 2 * ENGINE_ATOL, (name, state_id, "weak argmax margin", margin)
            margins.append(margin)
            assert abs(float(probabilities.sum()) - 1.0) < 1e-14
            assert float(probabilities[order].sum()) < 0.95
            if state_id == 1:
                first_states[name] = (logits, capture)
            # Exact forced values prove residual is post-intervention.
            for item in spec["ablate_native"]:
                assert np.all(capture[(item["layer"], "residual")][-1, item["neurons"]]
                              == item["value"])
            generated.append(selected)
            tokens.append(selected)
        min_shift = min(min_shift, *shifts)
        min_margin = min(min_margin, *margins)
        details.append({**spec, "generated_tokens_native": generated,
                        "min_top2_margin": min(margins), "min_previous_row_delta": min(shifts)})

    base_logits, base_capture = first_states["baseline"]
    effects = {}
    for name in ("steer", "ablate", "both"):
        effects[name] = float(np.max(np.abs(first_states[name][0] - base_logits)))
        assert effects[name] > 10 * ENGINE_ATOL, (name, "no-op guard too weak")
    steer_capture = first_states["steer"][1]
    # Steering occurs after both same-block component taps; only residual moves.
    for component in ("attn_out", "mlp_out"):
        np.testing.assert_array_equal(steer_capture[(1, component)], base_capture[(1, component)])
    np.testing.assert_allclose(steer_capture[(1, "residual")] - base_capture[(1, "residual")],
                               np.broadcast_to(STEER_VECTOR, base_capture[(1, "residual")].shape),
                               atol=1e-14, rtol=0)
    both_capture = first_states["both"][1]
    # Reversing composition would add +1.5 to this forced +0.25 coordinate.
    assert both_capture[(1, "residual")][-1, 2] == 0.25
    return tables, details, {"min_previous_row_delta": min_shift,
                             "min_top2_margin": min_margin,
                             "first_state_logit_effects": effects}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_environment_and_model() -> dict:
    assert sys.version_info[:2] == (3, 13), "use the pinned Python 3.13 golden venv"
    versions = {name: importlib.metadata.version(name) for name in ("numpy", "gguf")}
    assert versions == {"numpy": "2.5.1", "gguf": "0.19.0"}, versions
    gguf_weights_match_source()
    canonical, packaged = Path(canonical_gguf_path()), Path(package_fixture_path())
    assert canonical.read_bytes() == packaged.read_bytes(), "GGUF fixture copies differ"
    return {"python": platform.python_version(), **versions}


def provenance() -> dict:
    paths = [Path(__file__).resolve(), SYNTHETIC / "reference_forward.py",
             SYNTHETIC / "synthetic_model.py", HERE.parent / "requirements.txt",
             Path(canonical_gguf_path()), Path(package_fixture_path())]
    return {str(path.relative_to(ROOT)): sha256(path) for path in paths}


def csv_bytes(name: str, rows: list) -> bytes:
    stream = io.StringIO(newline="")
    writer = csv.writer(stream, lineterminator="\n")
    writer.writerow(HEADERS[name])
    for row in rows:
        writer.writerow([format(value, ".17g") if isinstance(value, float) else value
                         for value in row])
    return stream.getvalue().encode("utf-8")


def compare_tables(expected: dict, actual: dict) -> None:
    assert expected.keys() == actual.keys(), "artifact names differ"
    for name, expected_rows in expected.items():
        actual_rows = actual[name]
        assert len(expected_rows) == len(actual_rows), (name, "row count")
        for row_index, (wanted, found) in enumerate(zip(expected_rows, actual_rows), 1):
            assert len(wanted) == len(found), (name, row_index, "column count")
            for column, a, b in zip(HEADERS[name], wanted, found):
                if column in FLOAT_COLUMNS:
                    assert np.isclose(float(a), float(b), atol=CHECK_ATOL, rtol=CHECK_RTOL), (
                        name, row_index, column, a, b)
                else:
                    assert str(a) == str(b), (name, row_index, column, a, b)


def controls(tables: dict) -> None:
    # Test the comparison itself: keys and values cannot be silently ignored.
    def must_reject(changed):
        try:
            compare_tables(tables, changed)
        except AssertionError:
            return
        raise AssertionError("corrupted live-state golden was accepted")

    for name, row_index, column, replacement in (
        ("states.csv", 0, "source_pos", 1),
        ("states.csv", 0, "token_id", 999),
        ("activations.csv", 0, "value", 0.0),
        ("top.csv", 0, "prob", 1.0),
    ):
        changed = {key: [row.copy() for row in rows] for key, rows in tables.items()}
        changed[name][row_index][HEADERS[name].index(column)] = replacement
        must_reject(changed)
    ids, probs = ranked(np.asarray([1.0, 2.0, 2.0, -3.0]), 3)
    assert ids.tolist() == [1, 2, 0], "equal logits must use ascending native ID"
    assert probs[1] == probs[2]
    assert probs[ids].sum() < 1, "probabilities must not renormalize selected rows"
    assert ranked(np.zeros(48), 0)[0].size == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="recompute and verify without writes")
    args = parser.parse_args()
    versions = verify_environment_and_model()
    tables, specs, evidence = compute()
    controls(tables)
    if args.check:
        manifest = json.loads((OUT / "manifest.json").read_text())
        assert manifest["provenance_sha256"] == provenance(), "producer/model provenance changed"
        actual = {}
        for name in HEADERS:
            path = OUT / name
            assert sha256(path) == manifest["artifacts"][name]["sha256"], (name, "bytes changed")
            with path.open(newline="") as source:
                reader = csv.reader(source)
                assert next(reader) == HEADERS[name], (name, "schema changed")
                actual[name] = list(reader)
            assert len(actual[name]) == manifest["artifacts"][name]["rows"]
        compare_tables(tables, actual)
        # Same-machine determinism is exact; committed cross-machine comparison
        # above uses the established float64 oracle tolerance.
        again, _, _ = compute()
        assert all(csv_bytes(name, rows) == csv_bytes(name, again[name])
                   for name, rows in tables.items()), "same-machine output is not deterministic"
        assert [item["generated_tokens_native"] for item in specs] == [
            item["generated_tokens_native"] for item in manifest["cases"]]
        print("PASS: model/provenance/artifact bytes, all values, deterministic rerun, 8 controls")
    else:
        OUT.mkdir(exist_ok=True)
        artifacts = {}
        for name, rows in tables.items():
            path = OUT / name
            path.write_bytes(csv_bytes(name, rows))
            artifacts[name] = {"rows": len(rows), "sha256": sha256(path)}
        manifest = {
            "schema_version": 1, "feature": "F6a independent live source states",
            "reason": "New D-041 numerical feature; no existing fixture is regenerated",
            "compute_dtype": "float64", "model_config": CONFIG, "versions": versions,
            "coordinate_convention": "CSV indices are 1-based; manifest *_native indices are 0-based",
            "state_boundary": "state[k] uses final row of prompt plus generated tokens before k",
            "probability_convention": "raw pre-sampling logits; full-vocabulary softmax at temperature 1",
            "top": TOP, "cases": specs, "controls": evidence,
            "provenance_sha256": provenance(), "artifacts": artifacts,
        }
        (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print("Wrote only live-state/goldens:", {name: len(rows) for name, rows in tables.items()})
    print(json.dumps(evidence, sort_keys=True))


if __name__ == "__main__":
    main()
