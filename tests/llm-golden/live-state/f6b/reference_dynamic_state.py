#!/usr/bin/env python3
"""F6b independent dynamic reference on a separate seeded three-layer fixture.

The three-layer model is necessary: native cvec cannot steer block zero, and
steering the final block of the existing two-layer model cannot alter its KV.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import csv
import json
from pathlib import Path
import sys
import tempfile

import gguf
import numpy as np

F6B = Path(__file__).resolve().parent
sys.path.insert(0, str(F6B.parent))

from reference_live_state import (
    ACTIVATION_COMPONENTS, CONFIG, ENGINE_ATOL, HEADERS, HERE, ROOT, STEER_VECTOR,
    SYNTHETIC, Intervention, build_weights, compare_tables, controls, csv_bytes,
    prefix, ranked, sha256, verify_environment_and_model,
)
from incremental_reference import IncrementalReference

OUT = F6B / "goldens"
MODEL = F6B / "synthetic-llama-3l.gguf"
PROMPT = [1, 7]
# Coefficient used for the source forward pass of states 1..5. Prefill uses 1.
# Replies after states 1..4 are zero, negative, restored original, unchanged.
COEFFICIENTS = [1.0, 0.0, -1.0, 1.0, 1.0]


@contextmanager
def three_layer_configuration():
    """Locally reuse the existing seeded producer, without editing its inputs."""
    original = CONFIG.copy()
    try:
        CONFIG.update(n_layer=3, name="rebirth-synthetic-llama-3l-live-state")
        yield dict(CONFIG)
    finally:
        CONFIG.clear()
        CONFIG.update(original)


def write_model(path: Path, config: dict, weights: dict) -> None:
    """Same GGUF metadata/writer convention as existing build_synthetic.py."""
    hd = int(config["n_embd"]) // int(config["n_head"])
    writer = gguf.GGUFWriter(str(path), str(config["arch"]))
    writer.add_name(str(config["name"]))
    writer.add_file_type(0)
    writer.add_context_length(int(config["n_ctx_train"]))
    writer.add_embedding_length(int(config["n_embd"]))
    writer.add_block_count(int(config["n_layer"]))
    writer.add_feed_forward_length(int(config["n_ff"]))
    writer.add_head_count(int(config["n_head"]))
    writer.add_head_count_kv(int(config["n_head_kv"]))
    writer.add_key_length(hd)
    writer.add_value_length(hd)
    writer.add_rope_dimension_count(hd)
    writer.add_rope_freq_base(float(config["rope_freq_base"]))
    writer.add_layer_norm_rms_eps(float(config["rms_eps"]))
    writer.add_vocab_size(int(config["n_vocab"]))
    writer.add_tokenizer_model("no_vocab")
    for name, value in weights.items():
        writer.add_tensor(name, value)
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()


def change(coefficient: float, ablate: bool) -> Intervention:
    return Intervention(
        steer={1: (STEER_VECTOR * coefficient).astype(np.float32)},
        ablate={1: ([2], 0.25)} if ablate else {},
    )


def verify_static(config: dict, weights: dict) -> float:
    """Cross-check token-at-a-time KV against full prefixes before dynamic use."""
    largest = 0.0
    for ablate in (False, True):
        for coefficient in (0.0, 1.0, -1.0):
            runner = IncrementalReference(weights, config)
            tokens = []
            for token in PROMPT + [13, 22, 5, 31]:
                tokens.append(token)
                logits, capture = runner.decode(token, change(coefficient, ablate))
                full_logits, full_capture = prefix(weights, tokens, change(coefficient, ablate))
                np.testing.assert_allclose(logits, full_logits[-1], atol=1e-12, rtol=1e-12)
                largest = max(largest, float(np.max(np.abs(logits - full_logits[-1]))))
                for key, value in capture.items():
                    np.testing.assert_allclose(value, full_capture[key][-1], atol=1e-12, rtol=1e-12)
    return largest


def emit(tables, name, state_id, tokens, logits, capture, config):
    order, probabilities = ranked(logits, 5)
    selected = int(order[0])
    source = len(tokens)
    tables["states.csv"].append([
        name, state_id, state_id, selected + 1, source + 1, source,
        "prompt" if state_id == 1 else "generated", tokens[-1] + 1, len(PROMPT)])
    for layer in range(int(config["n_layer"])):
        for component in ACTIVATION_COMPONENTS:
            for neuron, value in enumerate(capture[(layer, component)]):
                tables["activations.csv"].append([
                    name, state_id, layer + 1, component, neuron + 1, float(value)])
    for token_id, (logit, prob) in enumerate(zip(logits, probabilities)):
        tables["logits.csv"].append([name, state_id, token_id + 1, float(logit), float(prob)])
    for rank, token_id in enumerate(order, 1):
        tables["top.csv"].append([
            name, state_id, rank, int(token_id) + 1, float(logits[token_id]), float(probabilities[token_id])])
    return selected, float(logits[order[0]] - logits[order[1]])


def compute(config: dict, weights: dict):
    tables = {name: [] for name in HEADERS}
    details = []
    static_delta = verify_static(config, weights)
    for ablate in (False, True):
        name = "dynamic_both" if ablate else "dynamic_steer"
        runner = IncrementalReference(weights, config)
        tokens = list(PROMPT)
        for token in tokens:
            logits, capture = runner.decode(token, change(COEFFICIENTS[0], ablate))
        generated, margins, replay_deltas, kv_deltas, ignored_deltas = [], [], [], [], []
        for state_id, coefficient in enumerate(COEFFICIENTS, 1):
            assert runner.position == len(tokens)
            selected, margin = emit(tables, name, state_id, tokens, logits, capture, config)
            margins.append(margin)
            generated.append(selected)
            if ablate:
                assert capture[(1, "residual")][2] == 0.25
            # The deliberately wrong oracle replays ALL earlier tokens with the
            # newest coefficient. Fixed token IDs isolate stale KV from sampling.
            wrong_logits, _ = prefix(weights, tokens, change(coefficient, ablate))
            replay_deltas.append(float(np.max(np.abs(logits - wrong_logits[-1]))))
            ignored_logits, _ = prefix(weights, tokens, change(COEFFICIENTS[0], ablate))
            ignored_deltas.append(float(np.max(np.abs(logits - ignored_logits[-1]))))
            replay = IncrementalReference(weights, config)
            for token in tokens:
                replay.decode(token, change(coefficient, ablate))
            kv_deltas.append(float(np.max(np.abs(runner.keys[2] - replay.keys[2]))))
            if state_id < len(COEFFICIENTS):
                tokens.append(selected)
                logits, capture = runner.decode(selected, change(COEFFICIENTS[state_id], ablate))
        assert min(margins) > 2 * ENGINE_ATOL, (name, "weak greedy margin", margins)
        assert replay_deltas[0] < 1e-12
        assert replay_deltas[1] > 10 * ENGINE_ATOL, (name, "zero-removal history guard", replay_deltas)
        assert replay_deltas[3] > 10 * ENGINE_ATOL, (name, "restore history guard", replay_deltas)
        assert kv_deltas[1] > 10 * ENGINE_ATOL
        assert ignored_deltas[1] > 10 * ENGINE_ATOL, (name, "ignored zero-removal guard", ignored_deltas)
        details.append({"name": name, "prompt_tokens_native": PROMPT,
                        "state_count": len(COEFFICIENTS), "steer_layer_native": 1,
                        "steer_vector": STEER_VECTOR.tolist(),
                        "ablate_native": [{"layer": 1, "neurons": [2], "value": 0.25}] if ablate else [],
                        "initial_coefficient": COEFFICIENTS[0],
                        "reply_coefficients_after_states": [0.0, -1.0, 1.0, None, None],
                        "source_coefficients": COEFFICIENTS,
                        "generated_tokens_native": generated, "min_top2_margin": min(margins),
                        "wrong_full_replay_max_logit_delta_by_state": replay_deltas,
                        "ignored_updates_max_logit_delta_by_state": ignored_deltas,
                        "wrong_full_replay_max_block3_key_delta_by_state": kv_deltas})
    return tables, details, static_delta


def source_provenance():
    paths = [Path(__file__).resolve(), HERE / "reference_live_state.py",
             F6B / "incremental_reference.py", SYNTHETIC / "reference_forward.py",
             SYNTHETIC / "synthetic_model.py", SYNTHETIC / "build_synthetic.py",
             HERE.parent / "requirements.txt"]
    return {str(path.relative_to(ROOT)): sha256(path) for path in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    # Also proves neither historical GGUF copy was modified by this producer.
    versions = verify_environment_and_model()
    with three_layer_configuration() as config:
        weights = build_weights()
        tables, specs, delta = compute(config, weights)
        controls(tables)
        if args.check:
            manifest = json.loads((OUT / "manifest.json").read_text())
            assert manifest["provenance_sha256"] == source_provenance(), "producer changed"
            assert manifest["model"]["sha256"] == sha256(MODEL), "model bytes changed"
            reader = gguf.GGUFReader(str(MODEL))
            disk = {tensor.name: np.array(tensor.data) for tensor in reader.tensors}
            assert disk.keys() == weights.keys()
            for name, value in weights.items():
                np.testing.assert_array_equal(disk[name].reshape(value.shape), value)
            with tempfile.TemporaryDirectory(prefix="relm-live-golden-") as directory:
                rebuilt = Path(directory) / MODEL.name
                write_model(rebuilt, config, weights)
                assert rebuilt.read_bytes() == MODEL.read_bytes(), "GGUF rebuild changed bytes"
            actual = {}
            for name in HEADERS:
                assert manifest["artifacts"][name]["sha256"] == sha256(OUT / name), name
                with (OUT / name).open(newline="") as source:
                    reader = csv.reader(source)
                    assert next(reader) == HEADERS[name]
                    actual[name] = list(reader)
                assert len(actual[name]) == manifest["artifacts"][name]["rows"]
            compare_tables(tables, actual)
            again, _, _ = compute(config, weights)
            assert all(csv_bytes(name, rows) == csv_bytes(name, again[name])
                       for name, rows in tables.items())
            assert [item["generated_tokens_native"] for item in specs] == [
                item["generated_tokens_native"] for item in manifest["cases"]]
            print("PASS: F6b model rebuild/tensors/provenance/artifacts, static cross-check, KV history guards")
        else:
            OUT.mkdir(exist_ok=True)
            write_model(MODEL, config, weights)
            artifacts = {}
            for name, rows in tables.items():
                path = OUT / name
                path.write_bytes(csv_bytes(name, rows))
                artifacts[name] = {"rows": len(rows), "sha256": sha256(path)}
            manifest = {
                "schema_version": 1, "feature": "F6b independent history-preserving steering",
                "reason": "New feature needs early steerable block with a later KV-producing block",
                "model": {"path": str(MODEL.relative_to(ROOT)), "sha256": sha256(MODEL),
                          "bytes": MODEL.stat().st_size, "config": config},
                "compute_dtype": "float64", "versions": versions, "top": 5,
                "coordinate_convention": "CSV indices are 1-based; manifest *_native indices are 0-based",
                "static_prefix_vs_incremental_max_logit_delta": delta,
                "cases": specs, "provenance_sha256": source_provenance(), "artifacts": artifacts,
            }
            (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            print("Wrote only live-state F6b model and fixtures:",
                  {name: len(rows) for name, rows in tables.items()})
        for spec in specs:
            print(json.dumps({key: spec[key] for key in (
                "name", "generated_tokens_native", "min_top2_margin",
                "wrong_full_replay_max_logit_delta_by_state")}, sort_keys=True))


if __name__ == "__main__":
    main()
