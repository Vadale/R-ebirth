#!/usr/bin/env python3
"""D046 new-feature arithmetic, schema2 encoding and causal tiny-model oracle."""
from __future__ import annotations

import argparse
import copy
import csv
from decimal import Decimal, localcontext
import hashlib
import importlib.metadata
import io
import json
import math
from pathlib import Path
import platform
import struct
import sys
import tempfile

import gguf
import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SYNTHETIC = HERE.parent / "synthetic"
DIRECTIONS = HERE.parent / "directions"
F6B = HERE.parent / "live-state/f6b"
for path in (SYNTHETIC, DIRECTIONS, F6B):
    sys.path.insert(0, str(path))
import reference_directions as typed
import synthetic_model
from reference_forward import Intervention, STEER_VECTOR
from incremental_reference import IncrementalReference
from forward_projection import ProjectionForward

VERSION = "1"
PREFIX = b"relm_direction/2\0"
MODEL = F6B / "synthetic-llama-3l.gguf"
MODEL_SHA256 = "e255ed5db07f318cbc3bd1d4d5a5a261bdef0867b3bbd1e26228f015b872bd05"
F64_TOL, SITE_TOL, DOWNSTREAM_TOL = 1e-12, 2e-6, .01
F32_MAX = float(np.finfo(np.float32).max)
COMPONENTS = ("attn_out", "mlp_out", "residual")
CHECKS = []


def sha(raw): return hashlib.sha256(raw).hexdigest()
def num(value): return format(float(value), ".17g")
def check(name, condition, detail=""):
    if not condition: raise AssertionError(name + ": " + str(detail))
    CHECKS.append((name, "passed", str(detail)))
def close(a, b, tol=F64_TOL):
    return all(abs(float(x) - float(y)) <= tol + tol * abs(float(y))
               for x, y in zip(a, b, strict=True))
def csv_out(directory, name, header, rows):
    typed.write_csv(directory / name, header, rows)


class Refusal(ValueError):
    pass


def project_detail(h, direction, coefficient):
    """Strict ascending-coordinate binary64 arithmetic and one F32 store.

    h is the existing F32 producer row; coefficient zero returns it unchanged
    with no dot calculation or write. The diagnostic update list is reference
    tooling only and is not a suggested native allocation strategy.
    """
    if type(coefficient) is not float or not math.isfinite(coefficient) or abs(coefficient) > F32_MAX:
        raise Refusal("invalid_coefficient")
    if len(h) != len(direction) or not len(h): raise Refusal("invalid_shape")
    v = [float(value) for value in direction]
    if not all(math.isfinite(value) for value in v): raise Refusal("nonfinite_direction")
    if abs(typed.norm(v) - 1.0) > F64_TOL: raise Refusal("nonunit_direction")
    if not all(math.isfinite(float(value)) and abs(float(value)) <= F32_MAX for value in h):
        raise Refusal("invalid_f32_row")
    row = np.asarray(h, dtype=np.float32)
    if coefficient == 0.0: return row, 0.0, False, [float(value) for value in row]
    dot = 0.0
    for j in range(len(v)):
        dot = dot + v[j] * float(row[j])
        if not math.isfinite(dot): raise Refusal("nonfinite_dot")
    updated = []
    for j in range(len(v)):
        value = float(row[j]) - (coefficient * v[j]) * dot
        if not math.isfinite(value): raise Refusal("nonfinite_update")
        if abs(value) > F32_MAX: raise Refusal("f32_overflow")
        updated.append(value)
    return np.asarray(updated, dtype=np.float32), dot, True, updated


def project(h, direction, coefficient):
    output, dot, written, _ = project_detail(h, direction, coefficient)
    return output, dot, written


def direction(width):
    # Fixed, weight-independent direction with unequal coordinate magnitudes.
    source = [float((j % 7) - 3) for j in range(width)]
    length = typed.norm(source)
    return [value / length for value in source]


def decimal_projection(h, v, coefficient):
    with localcontext() as context:
        context.prec = 90
        h, v = [[Decimal.from_float(float(x)) for x in values] for values in (h, v)]
        coefficient = Decimal.from_float(coefficient)
        dot = sum(a * b for a, b in zip(h, v))
        return [float(x - coefficient * y * dot) for x, y in zip(h, v)]


def arithmetic_cases(directory):
    accepted, refused, inputs, outputs = [], [], [], []
    general = [value / math.sqrt(30.) for value in (1., 2., 3., 4.)]
    specifications = []
    for label, h, v in (("axis", [3., -4., -0., 2.], [1., 0., 0., 0.]),
                        ("general", [3., -4., 2., 5.], general)):
        for coef in (0., 1., -1., 2.):
            specifications.append((label + "_c" + num(coef).replace("-", "neg"), h, v, coef))
    specifications += [
        ("general_reversed", [3., -4., 2., 5.], [-x for x in general], 1.),
        ("orthogonal", [2., -1., 0., 0.], general, 1.),
        ("cancellation_order", [1e8, 1., -1e8, 1.], [.5] * 4, 1.),
        ("coefficient_f64", [float(np.float32(1e8)), 2., 3., 4.], general, 1. + 2**-30),
        ("zero_signed_bits", [-0., 0., -0., 0.], general, -0.),
    ]
    results = {}
    for name, h, v, coefficient in specifications:
        h = np.asarray(h, dtype=np.float32)
        out, dot, written, f64 = project_detail(h, v, coefficient)
        accepted.append((name, len(h), num(coefficient), num(dot), int(written)))
        results[name] = (h, v, coefficient, out, f64, dot)
        for j, (source, unit, value, rounded) in enumerate(zip(h, v, f64, out), 1):
            inputs.append((name, j, num(source), num(unit), struct.pack("<f", source).hex(), struct.pack("<d", unit).hex()))
            outputs.append((name, j, num(value), num(rounded), struct.pack("<f", rounded).hex()))
        check("decimal90_" + name, close(f64, decimal_projection(h, v, coefficient)))
        if coefficient == 0.:
            check("zero_identity_bits_" + name, out.tobytes() == h.tobytes() and not written)
        if coefficient == 1.:
            check("parallel_removed_" + name,
                  abs(math.fsum(float(a) * b for a, b in zip(out, v))) <= SITE_TOL * (1 + typed.norm([float(x) for x in h])))
        before_dot = math.fsum(float(a) * b for a, b in zip(h, v))
        after_dot = math.fsum(float(a) * b for a, b in zip(f64, v))
        # Subtract each vector's own parallel component to isolate preservation.
        before_orth = [float(a) - b * before_dot for a, b in zip(h, v)]
        after_orth = [float(a) - b * after_dot for a, b in zip(f64, v)]
        check("orthogonal_preserved_" + name, close(after_orth, before_orth, SITE_TOL))
    check("sign_invariant_bits", results["general_c1"][3].tobytes() == results["general_reversed"][3].tobytes())
    check("negative_axis_doubles_parallel", results["axis_cneg1"][3][0] == 6.)
    check("above_one_axis_reverses_parallel", results["axis_c2"][3][0] == -3.)
    check("ascending_cancellation_dot", results["cancellation_order"][5] == 1.)
    h, v, coefficient, _, f64, _ = results["coefficient_f64"]
    check("early_coefficient_f32_rounding_detected", not close(f64, project_detail(h, v, float(np.float32(coefficient)))[3]))
    check("early_direction_f32_rounding_detected", not close(f64, decimal_projection(h, np.asarray(v, dtype=np.float32), coefficient)))
    invalid = [
        ("nonunit", [1., 2.], [2., 0.], 1., "nonunit_direction"),
        ("zero_direction", [1., 2.], [0., 0.], 1., "nonunit_direction"),
        ("nan_direction", [1., 2.], [math.nan, 0.], 1., "nonfinite_direction"),
        ("nan_row", [math.nan, 2.], [1., 0.], 1., "invalid_f32_row"),
        ("inf_row", [math.inf, 2.], [1., 0.], 1., "invalid_f32_row"),
        ("wide_row", [F32_MAX * 2, 2.], [1., 0.], 1., "invalid_f32_row"),
        ("coefficient_inf", [1., 2.], [1., 0.], math.inf, "invalid_coefficient"),
        ("coefficient_range", [1., 2.], [1., 0.], F32_MAX * 2, "invalid_coefficient"),
        ("amplification_overflow", [F32_MAX, 2.], [1., 0.], -1., "f32_overflow"),
        ("scalar_product_overflow", [F32_MAX, F32_MAX], [math.sqrt(.5)] * 2, F32_MAX, "f32_overflow"),
        ("width_mismatch", [1.], [1., 0.], 1., "invalid_shape"),
    ]
    for name, h, v, coefficient, expected in invalid:
        try: project_detail(h, v, coefficient)
        except Refusal as error: reason = str(error)
        else: reason = "accepted"
        check("reject_" + name, reason == expected, reason)
        refused.append((name, expected, num(coefficient), ";".join(map(num, h)), ";".join(map(num, v))))
    csv_out(directory, "arithmetic-cases.csv", ["case", "width", "coef", "dot", "write"], accepted)
    csv_out(directory, "arithmetic-inputs.csv", ["case", "neuron", "h", "direction", "h_f32_hex", "direction_f64_hex"], inputs)
    csv_out(directory, "arithmetic-expected.csv", ["case", "neuron", "updated_f64", "updated_f32", "f32_hex"], outputs)
    csv_out(directory, "arithmetic-refusals.csv", ["case", "reason", "coef", "h", "direction"], refused)
    return {"arithmetic_accepted": len(accepted), "arithmetic_refused": len(refused), "arithmetic_values": len(outputs)}


def stream(domain, node):
    yield PREFIX
    yield from typed.encode(typed.scalar("S", domain))
    yield from typed.encode(node)


def digest(domain, node):
    class Sink:
        def write(self, _): pass
    return typed.Writer(Sink(), 2**31 - 1).write(stream(domain, node))


def replace_field(node, name, value):
    items = node[1]
    index = next(i for i, (key, _) in enumerate(items) if key == name)
    items[index] = (name, value)


def encoding_cases(directory):
    S, V, R, F = typed.scalar, typed.vector, typed.record, typed.frame
    ids, t, c = ["pair-α", "pair-東京"], [[3., 4.], [6., 8.]], [[-0., 0.], [0., 0.]]
    values, diagnostic, pairs_norm = typed.arithmetic(t, c, ids)
    context, pairs, splits, prompts = typed.context_fixture()
    target, control = typed.matrix(t, ids), typed.matrix(c, ids)
    values_node = R(neuron=V("i", [1, 2]), value=V("d", values))
    fixtures = [("positive_zero", "primitive", S("D", 0.)), ("negative_zero", "primitive", S("D", -0.)),
                ("target", "matrix", target), ("control", "matrix", control),
                ("pairs", "pairs", pairs), ("splits", "splits", splits), ("values", "values", values_node)]
    hashes = dict(target=digest("matrix", target), control=digest("matrix", control),
                  pairs=digest("pairs", pairs), splits=digest("splits", splits), values=digest("values", values_node))
    norms_node = F(pair_id=V("s", ids), **{field: V("d", [row[i + 1] for row in pairs_norm])
                  for i, field in enumerate(("target_norm", "control_norm", "difference_norm", "used_norm"))})
    diagnostics = R(guard_relative=S("D", typed.GUARD), pairs=norms_node,
                    **{name: S("D", value) for name, value in diagnostic.items() if name != "guard_relative"})
    digests = []
    for component, layer in (("mlp_out", 1), ("attn_out", 3)):
        ctx = copy.deepcopy(context)
        capture = dict(ctx[1])["capture"]
        replace_field(capture, "component", S("S", component))
        metadata = R(schema=S("S", "relm_direction/2"), layer=S("I", layer), component=S("S", component),
            context=ctx, method=R(algorithm=S("S", "paired_difference_mean/1"), normalize_pairs=S("L", False), orthogonalize=S("L", False)),
            diagnostics=diagnostics, producer=R(relm_version=S("S", "0.0.0"), r_version=S("S", "4.6.1")),
            digests=R(**{name: S("S", value) for name, value in hashes.items()}))
        artifact = R(neuron=V("i", [1, 2]), value=V("d", values), direction=metadata)
        payload = digest("artifact", artifact)
        fixtures.extend([(component + "_context", "context", ctx), (component + "_artifact", "artifact", artifact)])
        digests.extend((component, name, value) for name, value in {**hashes, "payload": payload}.items())
        wrong = copy.deepcopy(artifact)
        replace_field(dict(wrong[1])["direction"], "component", S("S", "residual"))
        check(component + "_component_corruption_detected", digest("artifact", wrong) != payload)
        wrong = copy.deepcopy(artifact)
        replace_field(dict(wrong[1])["direction"], "layer", S("I", layer + 1))
        check(component + "_layer_corruption_detected", digest("artifact", wrong) != payload)
        check(component + "_wrong_domain_detected", digest("context", artifact) != payload)
        check(component + "_old_prefix_detected", typed.encoded_digest("artifact", artifact) != payload)
    index, fields = [], []
    for name, domain, node in fixtures:
        path = directory / (name + ".bin")
        with path.open("wb") as file:
            writer = typed.Writer(file, 1024 * 1024)
            checksum = writer.write(stream(domain, node))
        raw = path.read_bytes()
        (directory / (name + ".hex")).write_text(raw.hex() + "\n", encoding="ascii")
        check("streamed_hash_" + name, sha(raw) == checksum)
        check("schema_domain_separation_" + name, checksum != typed.encoded_digest(domain, node))
        index.append((name, domain, len(raw), checksum, path.name, name + ".hex", writer.maximum))
        fields.extend(typed.node_rows(name, node))
    check("signed_zero_digest_distinct", digest("primitive", S("D", 0.)) != digest("primitive", S("D", -0.)))
    csv_out(directory, "encoding-index.csv", ["case", "domain", "bytes", "sha256", "binary", "hex", "max_chunk_bytes"], index)
    csv_out(directory, "encoding-fields.csv", ["case", "path", "kind", "field", "length", "nrow", "ncol", "value", "scalar_hex"], fields)
    csv_out(directory, "artifact-digests.csv", ["component", "field", "sha256"], digests)
    csv_out(directory, "prompts.csv", ["id", "text", "sha256"], [(i + 1, text, sha(text.encode())) for i, text in enumerate(prompts)])
    return {"encoding_vectors": len(fixtures), "encoding_nodes": len(fields)}


def pure_site_cases(directory):
    """Small site equations including output bias/scale; no Qwen engine claim."""
    v, coef = [0.6, 0.8], 1.
    residual = np.asarray([.25, -.75], dtype=np.float64)
    head = np.asarray([2., -1.], dtype=np.float64)
    wo = np.asarray([[2., .5], [-1., 3.]], dtype=np.float64)
    bias, scale = np.asarray([.125, -.25]), .75
    final_linear = np.asarray([[1., 2.], [-3., .5]], dtype=np.float64)
    rows = []
    for architecture, component in (("llama", "attn_out"), ("llama", "mlp_out"), ("qwen2", "mlp_out")):
        raw = ((head @ wo.T + bias) * scale if component == "attn_out"
               else np.asarray([1.5, -.625]))
        edited = project(raw.astype(np.float32), v, coef)[0].astype(np.float64)
        result = residual + edited
        downstream = result @ final_linear.T
        wrong_residual = project((residual + raw).astype(np.float32), v, coef)[0]
        check(architecture + "_" + component + "_preadd_distinct", not close(result, wrong_residual, SITE_TOL))
        check(architecture + "_" + component + "_causal_effect", not close(downstream, (residual + raw) @ final_linear.T, SITE_TOL))
        if component == "attn_out":
            wrong_prewo = (project(head.astype(np.float32), v, coef)[0] @ wo.T + bias) * scale
            check("postwo_bias_scale_required", not close(edited, wrong_prewo, SITE_TOL))
        for j in range(2):
            rows.append((architecture, component, j + 1, num(v[j]), num(coef), num(residual[j]),
                         num(raw[j]), num(edited[j]), num(result[j]), num(downstream[j])))
    csv_out(directory, "site-math.csv", ["architecture", "component", "neuron", "direction", "coef", "residual", "site_before", "site_after", "residual_after", "downstream"], rows)
    # Inputs for the independent tiny site computation, no hidden matrix constants.
    csv_out(directory, "site-math-inputs.csv", ["object", "row", "column", "value"],
            [(name, i + 1, j + 1, num(value)) for name, array in
             (("wo", wo), ("downstream", final_linear), ("head", head[None, :]),
              ("bias", bias[None, :]), ("scale", np.asarray([[scale]])))
             for i, row in enumerate(array) for j, value in enumerate(row)])
    return {"pure_site_cases": 3, "pure_site_values": len(rows)}


def model_inputs():
    check("existing_model_sha256", sha(MODEL.read_bytes()) == MODEL_SHA256)
    original = synthetic_model.CONFIG.copy()
    try:
        synthetic_model.CONFIG.update(n_layer=3, name="rebirth-synthetic-llama-3l-live-state")
        config = dict(synthetic_model.CONFIG)
        seeded = synthetic_model.build_weights()
    finally:
        synthetic_model.CONFIG.clear()
        synthetic_model.CONFIG.update(original)
    reader = gguf.GGUFReader(str(MODEL))
    disk = {tensor.name: np.array(tensor.data) for tensor in reader.tensors}
    check("seeded_tensor_names", set(disk) == set(seeded))
    for name, values in seeded.items():
        check("seeded_tensor_" + name, np.array_equal(values, disk[name].reshape(values.shape)))
    # Use the read-only GGUF tensors, independently checked against the seed.
    return config, {name: disk[name].reshape(value.shape) for name, value in seeded.items()}


def forward_cases(directory, config, weights):
    v, token_ids = direction(32), [1, 7, 13, 22, 5]
    specs = [("baseline", [], False, False)]
    for component in ("mlp_out", "attn_out"):
        for coef in (0., 1., -1., 2.):
            specs.append((component + "_first_c" + num(coef).replace("-", "neg"), [(0, component, coef)], False, False))
        specs.append((component + "_last_c1", [(2, component, 1.)], False, False))
    specs += [
        ("multiple_sites", [(0, "attn_out", 1.), (0, "mlp_out", 1.), (1, "mlp_out", -1.)], False, False),
        ("projection_steer_ablate", [(1, "attn_out", 1.), (1, "mlp_out", 1.)], True, False),
        ("static_projection_dynamic_steer", [(0, "mlp_out", 1.)], True, True),
        ("long_prefill", [(0, "attn_out", 1.), (0, "mlp_out", 1.)], False, False),
    ]
    cases_rows, spec_rows, tokens_rows, acts, logits_rows, sites_rows, row_checks = [], [], [], [], [], [], []
    details, outcomes = {}, {}
    for name, sites, composition, dynamic in specs:
        long = name == "long_prefill"
        tokens = (([1, 7, 13, 22, 5, 31, 44, 2] * 65)[:513] + [13]) if long else token_ids
        prefill = 513 if long else 3
        kept = {1, 2, 128, 512, 513, 514} if long else set(range(1, len(tokens) + 1))
        site_map = {(layer, component): (v, coefficient) for layer, component, coefficient in sites}
        coefficients = ([1., 1., 1., 0., -1.] if dynamic else [1.] * len(tokens))
        runner = ProjectionForward(weights, config, project, site_map)
        saved = []
        cases_rows.append((name, prefill, len(tokens) - prefill, len(tokens), len(sites), int(composition), int(dynamic)))
        for layer, component, coefficient in sites:
            for neuron, value in enumerate(v, 1):
                spec_rows.append((name, layer + 1, component, num(coefficient), neuron, num(value)))
        for pos, (token, coefficient) in enumerate(zip(tokens, coefficients if not long else [1.] * len(tokens)), 1):
            tokens_rows.append((name, pos, token, "prefill" if pos <= prefill else "decode", num(coefficient) if composition else ""))
            change = Intervention(steer={1: (STEER_VECTOR * coefficient).astype(np.float32)} if composition else {},
                                  ablate={1: ([2], .25)} if composition else {})
            score, capture = runner.decode(token, change)
            saved.append((score.copy(), capture))
            if composition: check(name + "_ablate_wins_" + str(pos), capture[(1, "residual")][2] == .25)
            if pos in kept:
                for (layer, component), values in capture.items():
                    acts.extend((name, pos, layer + 1, component, neuron, num(value)) for neuron, value in enumerate(values, 1))
                logits_rows.extend((name, pos, token_id, num(value)) for token_id, value in enumerate(score))
        for pos, layer, component, before, after, dot, written in runner.rows:
            # Every executed row gets a scalar witness. Large-prefix full vectors
            # are retained only at declared boundaries to keep the fixture small.
            row_checks.append((name, pos, layer, component, num(dot), int(written), num(typed.norm([float(x) for x in before])), num(typed.norm([float(x) for x in after]))))
            if pos in kept:
                sites_rows.extend((name, pos, layer, component, j + 1, num(a), num(b)) for j, (a, b) in enumerate(zip(before, after)))
        check(name + "_all_rows", len(runner.rows) == len(tokens) * len(sites))
        details[name] = dict(projection_rows=len(runner.rows), retained_positions=sorted(kept),
                             final_logits=[float(x) for x in saved[-1][0]])
        outcomes[name] = saved
        if name == "baseline":
            old = IncrementalReference(weights, config)
            largest = 0.
            for token, (score, capture) in zip(tokens, saved):
                old_score, old_capture = old.decode(token, Intervention())
                largest = max(largest, float(np.max(np.abs(score - old_score))))
                for key in capture: largest = max(largest, float(np.max(np.abs(capture[key] - old_capture[key]))))
            check("unprojected_independent_forward_crosscheck", largest < SITE_TOL, num(largest))
        if sites and all(site[2] == 0. for site in sites):
            baseline = outcomes["baseline"]
            check(name + "_exact_zero_logits", all(np.array_equal(a[0], b[0]) for a, b in zip(saved, baseline)))
            check(name + "_no_writes", all(not row[-1] for row in runner.rows))
        if sites and any(site[2] != 0. for site in sites) and not composition:
            # Each wrong implementation must fail downstream with the SAME
            # input token IDs. No sampling discontinuity manufactures an effect.
            for fault in ("missing", "noop", "read_only", "residual_site"):
                if long and fault not in ("read_only", "residual_site"): continue
                wrong = ProjectionForward(weights, config, project, site_map, fault)
                delta = 0.
                for token, (expected, _) in zip(tokens, saved):
                    actual, _ = wrong.decode(token)
                    delta = max(delta, float(np.max(np.abs(actual - expected))))
                check(name + "_reject_" + fault, delta > 2 * DOWNSTREAM_TOL, num(delta))
                details[name][fault + "_max_logit_delta"] = delta
            if long:
                wrong = ProjectionForward(weights, config, project, site_map, "last_prefill_row_only")
                for token in tokens: wrong_logits, _ = wrong.decode(token)
                delta = float(np.max(np.abs(wrong_logits - saved[-1][0])))
                check("long_prefill_reject_last_row_only", delta > 2 * DOWNSTREAM_TOL, num(delta))
                details[name]["last_row_only_final_logit_delta"] = delta
        if dynamic:
            wrong_deltas = []
            for index in (3, 4):
                wrong = ProjectionForward(weights, config, project, site_map)
                change = Intervention(steer={1: (STEER_VECTOR * coefficients[index]).astype(np.float32)}, ablate={1: ([2], .25)})
                for token in tokens[:index + 1]: wrong_score, _ = wrong.decode(token, change)
                wrong_deltas.append(float(np.max(np.abs(wrong_score - saved[index][0]))))
            check("static_projection_dynamic_history_not_replayed", min(wrong_deltas) > 2 * DOWNSTREAM_TOL, wrong_deltas)
            details[name]["wrong_full_replay_max_logit_delta"] = wrong_deltas
    csv_out(directory, "forward-cases.csv", ["case", "prefill_tokens", "decode_tokens", "total_tokens", "projection_sites", "steer_ablate", "dynamic_steer"], cases_rows)
    csv_out(directory, "forward-projections.csv", ["case", "layer", "component", "coef", "neuron", "direction"], spec_rows)
    csv_out(directory, "forward-tokens.csv", ["case", "source_pos", "token_id_native", "phase", "steer_coef"], tokens_rows)
    csv_out(directory, "forward-activations.csv", ["case", "source_pos", "layer", "component", "neuron", "value"], acts)
    csv_out(directory, "forward-logits.csv", ["case", "source_pos", "token_id_native", "logit"], logits_rows)
    csv_out(directory, "forward-sites.csv", ["case", "source_pos", "layer", "component", "neuron", "before", "after"], sites_rows)
    csv_out(directory, "forward-row-witnesses.csv", ["case", "source_pos", "layer", "component", "dot", "write", "before_norm", "after_norm"], row_checks)
    csv_out(directory, "forward-residual-interventions.csv", ["layer", "neuron", "steer_direction", "ablate", "ablate_value"],
            [(2, j + 1, num(value), int(j == 2), num(.25) if j == 2 else "") for j, value in enumerate(STEER_VECTOR)])
    return dict(forward_cases=len(specs), forward_input_tokens=len(tokens_rows), forward_activation_values=len(acts),
                forward_logit_values=len(logits_rows), forward_site_values=len(sites_rows), forward_projected_rows=len(row_checks)), details


def source_files():
    return [Path(__file__).resolve(), HERE / "forward_projection.py", HERE / "ENCODING.md",
            DIRECTIONS / "reference_directions.py", DIRECTIONS / "ENCODING.md",
            F6B / "incremental_reference.py", SYNTHETIC / "reference_forward.py",
            SYNTHETIC / "synthetic_model.py", HERE.parent / "requirements.txt"]


def generate(directory):
    CHECKS.clear()
    directory.mkdir(parents=True, exist_ok=True)
    versions = dict(python=platform.python_version(), numpy=np.__version__, gguf=importlib.metadata.version("gguf"))
    assert versions == dict(python="3.13.5", numpy="2.5.1", gguf="0.19.0"), versions
    config, weights = model_inputs()
    counts = arithmetic_cases(directory)
    counts.update(encoding_cases(directory))
    counts.update(pure_site_cases(directory))
    forward_counts, details = forward_cases(directory, config, weights)
    counts.update(forward_counts)
    counts["controls"] = len(CHECKS)
    csv_out(directory, "controls.csv", ["control", "outcome", "detail"], CHECKS)
    sources = {str(path.relative_to(REPO)): sha(path.read_bytes()) for path in source_files()}
    csv_out(directory, "sources.csv", ["file", "sha256"], sources.items())
    csv_out(directory, "provenance.csv", ["key", "value"], [
        ("producer", "reference_projection.py"), ("producer_version", VERSION),
        ("interpreter", ".golden-venv/bin/python"), *versions.items(),
        ("model", str(MODEL.relative_to(REPO))), ("model_sha256", MODEL_SHA256),
        ("f64_atol", F64_TOL), ("f64_rtol", F64_TOL), ("site_atol", SITE_TOL),
        ("site_rtol", SITE_TOL), ("downstream_atol", DOWNSTREAM_TOL), *counts.items()])
    metadata = dict(schema="relm_projection_reference/1", producer_version=VERSION, versions=versions,
        tolerances=dict(f64_abs=F64_TOL, f64_rel=F64_TOL, site_f32_abs=SITE_TOL, site_f32_rel=SITE_TOL, downstream_abs=DOWNSTREAM_TOL),
        counts=counts, model=dict(path=str(MODEL.relative_to(REPO)), sha256=MODEL_SHA256, config=config),
        source_sha256=sources, cases=details,
        native_acceptance=False, limitations=["No engine/CPU/Metal execution", "Qwen2 is site-math only; no full Qwen model", "No GGUF optional output bias/scale; pure site oracle covers that order", "No final-layer engine row-pruning or actual batching claim"])
    (directory / "manifest.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    files = sorted(path for path in directory.iterdir() if path.name != "manifest.csv")
    csv_out(directory, "manifest.csv", ["file", "bytes", "sha256"], [(path.name, path.stat().st_size, sha(path.read_bytes())) for path in files])
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    destination = HERE / "goldens"
    if args.write:
        assert not destination.exists() or not any(destination.iterdir()), "refusing to overwrite existing goldens"
        # A failed first generation leaves no partially frozen fixtures.
        with tempfile.TemporaryDirectory(prefix="relm-f6e-reference-write-") as tmp:
            metadata = generate(Path(tmp))
            destination.mkdir(exist_ok=True)
            for path in Path(tmp).iterdir(): (destination / path.name).write_bytes(path.read_bytes())
    else:
        with tempfile.TemporaryDirectory(prefix="relm-f6e-reference-check-") as tmp:
            metadata = generate(Path(tmp))
            assert {path.name for path in Path(tmp).iterdir()} == {path.name for path in destination.iterdir()}, "file inventory changed"
            for path in Path(tmp).iterdir():
                assert path.read_bytes() == (destination / path.name).read_bytes(), "golden byte mismatch: " + path.name
    print("D046_REFERENCE_OK " + " ".join(f"{key}={value}" for key, value in metadata["counts"].items()))
    print("producer_sha256=" + sha(Path(__file__).read_bytes()))
    print("manifest_sha256=" + sha((destination / "manifest.csv").read_bytes()))
    print("model_sha256=" + sha(MODEL.read_bytes()))


if __name__ == "__main__":
    main()
