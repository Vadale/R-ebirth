#!/usr/bin/env python3
"""Independent D-045 arithmetic/encoding oracle; stdlib only, pinned test venv."""
import argparse
import copy
import csv
from decimal import Decimal, localcontext
import hashlib
import importlib.metadata
import io
import math
from pathlib import Path
import platform
import struct
import sys
import tempfile

VERSION = "1"
ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
PREFIX = b"relm_direction/1\0"
GUARD = 64 * sys.float_info.epsilon
TOL = 1e-12
CHUNK = 4096


def require(ok, message):
    if not ok:
        raise AssertionError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def number(value):
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "Inf" if value > 0 else "-Inf"
    return format(value, ".17g")


class Refusal(Exception):
    def __init__(self, reason, pair_id=""):
        self.reason, self.pair_id = reason, pair_id


def norm(values):
    scale = max(map(abs, values), default=0.0)
    if not math.isfinite(scale):
        raise Refusal("nonfinite_norm")
    result = scale * math.sqrt(math.fsum((value / scale) ** 2 for value in values)) if scale else 0.0
    if not math.isfinite(result):
        raise Refusal("nonfinite_norm")
    return result


def mean(rows):
    # Each contribution is divided before accumulation, avoiding an overflowing
    # raw sum. fsum supplies a separately implemented reference accumulator.
    return [math.fsum(row[j] / len(rows) for row in rows) for j in range(len(rows[0]))]


def arithmetic(target, control, ids, normalize_pairs=False, orthogonalize=False):
    used, pair_rows, controls = [], [], []
    for name, t, c in zip(ids, target, control, strict=True):
        if not all(math.isfinite(value) for value in t + c):
            raise Refusal("nonfinite_input", name)
        difference = [a - b for a, b in zip(t, c, strict=True)]
        if not all(math.isfinite(value) for value in difference):
            raise Refusal("nonfinite_difference", name)
        tn, cn, dn = norm(t), norm(c), norm(difference)
        if dn == 0 or dn <= GUARD * max(tn, cn):
            raise Refusal("degenerate_pair", name)
        row = [value / dn for value in difference] if normalize_pairs else difference
        un = norm(row)
        used.append(row)
        controls.append(c)
        pair_rows.append((name, tn, cn, dn, un))
    direction = mean(used)
    mean_pair_norm = math.fsum(row[4] / len(ids) for row in pair_rows)
    pre = norm(direction)
    if pre == 0 or pre <= GUARD * mean_pair_norm:
        raise Refusal("degenerate_mean")
    control_mean = mean(controls)
    control_mean_norm = norm(control_mean)
    mean_control_norm = math.fsum(row[2] / len(ids) for row in pair_rows)
    if orthogonalize:
        if control_mean_norm == 0 or control_mean_norm <= GUARD * mean_control_norm:
            raise Refusal("degenerate_control_mean")
        unit = [value / control_mean_norm for value in control_mean]
        projection = math.fsum(a * b for a, b in zip(unit, direction, strict=True))
        direction = [a - b * projection for a, b in zip(direction, unit, strict=True)]
    post = norm(direction)
    if post == 0 or post <= GUARD * pre:
        raise Refusal("degenerate_projection")
    result = [value / post for value in direction]
    diagnostics = dict(guard_relative=GUARD, mean_pair_norm=mean_pair_norm,
        control_mean_norm=control_mean_norm, mean_control_norm=mean_control_norm,
        pre_projection_norm=pre, post_projection_norm=post, final_norm=norm(result))
    return result, diagnostics, pair_rows


def decimal_direction(target, control, normalized, projected):
    # A second high-precision calculation checks the accepted unit vectors.
    # It has no scaled-double norm, binary64 accumulation or guard machinery.
    with localcontext() as ctx:
        ctx.prec = 90
        t = [[Decimal.from_float(x) for x in row] for row in target]
        c = [[Decimal.from_float(x) for x in row] for row in control]
        magnitude = lambda row: sum(x * x for x in row).sqrt()
        differences = [[a - b for a, b in zip(x, y)] for x, y in zip(t, c)]
        if normalized:
            differences = [[x / magnitude(row) for x in row] for row in differences]
        average = lambda rows: [sum(row[j] for row in rows) / len(rows) for j in range(len(rows[0]))]
        d = average(differences)
        if projected:
            cm = average(c)
            unit = [x / magnitude(cm) for x in cm]
            dot = sum(a * b for a, b in zip(d, unit))
            d = [a - b * dot for a, b in zip(d, unit)]
        length = magnitude(d)
        return [float(x / length) for x in d]


def close(actual, expected):
    return len(actual) == len(expected) and all(abs(a - b) <= TOL + TOL * abs(b)
                                              for a, b in zip(actual, expected))


def cases():
    result = []
    def add(name, t, c, normalized=False, projected=False, reason="", pair=""):
        result.append(dict(case=name, target=t, control=c, normalized=normalized,
            projected=projected, reason=reason, pair=pair,
            ids=[f"pair-{i + 1}" for i in range(len(t))]))
    c = [[2., 1., -1., .5], [1., 3., .5, -2.], [-1., 2., 2., 1.]]
    delta = [[1., 2., -1., .5], [4., -2., 3., 1.], [-.5, .25, .75, 2.]]
    t = [[a + b for a, b in zip(x, y)] for x, y in zip(c, delta)]
    for normalized in (False, True):
        for projected in (False, True):
            add(f"unequal_n{int(normalized)}_o{int(projected)}", t, c, normalized, projected)
    for normalized in (False, True):
        add(f"reversed_sign_n{int(normalized)}", c, t, normalized)
    for label, scale in (("large", 1e200), ("tiny", 1e-200)):
        cc = [[scale, 0., 0.], [0., scale, 0.]]
        tt = [[2 * scale, scale, 0.], [0., 2 * scale, scale]]
        for normalized in (False, True):
            for projected in (False, True):
                add(f"{label}_n{int(normalized)}_o{int(projected)}", tt, cc, normalized, projected)
    add("encoding_exact", [[3., 4.], [6., 8.]], [[-0., 0.], [0., 0.]])
    result[-1]["ids"] = ["pair-α", "pair-東京"]
    add("above_pair_guard", [[1. + 2**-45, 0.], [0., 2.]], [[1., 0.], [0., 1.]])
    add("zero_pair", [[0., 0.], [1., 0.]], [[0., 0.], [0., 0.]], reason="degenerate_pair", pair="pair-1")
    for normalized in (False, True):
        add(f"near_pair_n{int(normalized)}", [[1. + 2**-47, 0.], [0., 2.]],
            [[1., 0.], [0., 1.]], normalized, reason="degenerate_pair", pair="pair-1")
    add("at_pair_guard", [[1. + GUARD, 0.], [0., 2.]], [[1., 0.], [0., 1.]],
        reason="degenerate_pair", pair="pair-1")
    add("cancelled_mean", [[1., 0.], [-1., 0.]], [[0., 0.], [0., 0.]], reason="degenerate_mean")
    add("near_cancelled_mean", [[1., 0.], [-1., 2**-47]], [[0., 0.], [0., 0.]], reason="degenerate_mean")
    add("normalized_cancelled_mean", [[1., 0.], [-2., 0.]], [[0., 0.], [0., 0.]], True, reason="degenerate_mean")
    add("zero_control_mean", [[1., 0.], [0., 1.]], [[0., 0.], [0., 0.]], projected=True, reason="degenerate_control_mean")
    add("cancelled_control_mean", [[1., 1.], [-1., 2.]], [[1., 0.], [-1., 0.]], projected=True, reason="degenerate_control_mean")
    add("near_cancelled_control_mean", [[1., 1.], [-1., 2.]], [[1., 0.], [-1., 2**-48]], projected=True, reason="degenerate_control_mean")
    for label, residual in (("parallel", 0.), ("near_parallel", 2**-47)):
        add(label, [[2., residual], [3., residual]], [[1., 0.], [2., 0.]], projected=True, reason="degenerate_projection")
    for label, value in (("input_inf", math.inf), ("input_nan", math.nan)):
        add(label, [[value, 0.], [1., 0.]], [[0., 0.], [0., 0.]], reason="nonfinite_input", pair="pair-1")
    add("difference_overflow", [[1e308, 0.], [0., 1.]], [[-1e308, 0.], [0., 0.]], reason="nonfinite_difference", pair="pair-1")
    add("norm_overflow", [[1.7e308, 1.7e308], [1., 0.]], [[0., 0.], [0., 0.]], reason="nonfinite_norm")
    return result


# Explicit typed nodes prevent Python's bool/int inheritance or scalar/vector
# ambiguity from silently choosing an encoding. Records arrive in schema order.
def scalar(tag, value=None): return (tag, value)
def vector(tag, values): return (tag, list(values))
def record(**fields): return ("R", list(fields.items()))
def frame(**columns): return ("F", list(columns.items()))
def matrix(rows, ids):
    return ("M", (len(rows), len(rows[0]), ids, [str(i + 1) for i in range(len(rows[0]))],
                  [value for row in rows for value in row]))


def count(value):
    require(type(value) is int and 0 <= value <= 2147483647, "invalid canonical count")
    return struct.pack("<I", value)


def utf8(value):
    require(type(value) is str and "\0" not in value, "invalid canonical string")
    return value.encode("utf-8", errors="strict")


def scalar_bytes(tag, value):
    if tag == "N":
        require(value is None, "invalid NULL")
        return b""
    if tag == "L":
        require(type(value) is bool, "invalid logical")
        return bytes([value])
    if tag == "I":
        require(type(value) is int and -2147483647 <= value <= 2147483647, "invalid integer")
        return struct.pack("<i", value)
    if tag == "D":
        require(type(value) is float and math.isfinite(value), "invalid double")
        return struct.pack("<d", value)
    if tag == "S":
        return utf8(value)
    raise AssertionError(f"unknown scalar tag {tag}")


def encode(node):
    tag, value = node
    yield tag.encode("ascii")
    if tag in "NLIDS":
        data = scalar_bytes(tag, value)
        if tag == "S": yield count(len(data))
        yield data
    elif tag in "lids":
        yield count(len(value))
        for item in value:
            data = scalar_bytes(tag.upper(), item)
            if tag == "s": yield count(len(data))
            yield data
    elif tag in ("R", "F"):
        require(len({name for name, _ in value}) == len(value), "duplicate field")
        if tag == "F":
            require(value and all(column[0] in "lids" for _, column in value), "invalid frame")
            lengths = {len(column[1]) for _, column in value}
            require(len(lengths) == 1, "unequal frame columns")
            yield count(next(iter(lengths)))
        yield count(len(value))
        for name, child in value:
            yield from encode(scalar("S", name))
            yield from encode(child)
    elif tag == "M":
        nr, nc, names, columns, values = value
        require(len(names) == nr and len(columns) == nc and len(values) == nr * nc, "invalid matrix")
        yield count(nr)
        yield count(nc)
        yield from encode(vector("s", names))
        yield from encode(vector("s", columns))
        yield from encode(vector("d", values))
    else:
        raise AssertionError(f"unknown tag {tag}")


def stream(domain, node):
    yield PREFIX
    yield from encode(scalar("S", domain))
    yield from encode(node)


class Writer:
    def __init__(self, destination, limit):
        self.destination, self.limit = destination, limit
        self.bytes = self.maximum = 0
        self.digest = hashlib.sha256()

    def write(self, pieces):
        for piece in pieces:
            for start in range(0, len(piece), CHUNK):
                chunk = piece[start:start + CHUNK]
                require(self.bytes + len(chunk) <= self.limit, "canonical byte cap exceeded")
                self.destination.write(chunk)
                self.digest.update(chunk)
                self.bytes += len(chunk)
                self.maximum = max(self.maximum, len(chunk))
        return self.digest.hexdigest()


def encoded_digest(domain, node):
    # Digest-only sink keeps no concatenated canonical buffer.
    class Sink:
        def write(self, _): pass
    writer = Writer(Sink(), 2**31 - 1)
    return writer.write(stream(domain, node))


def context_fixture():
    prompts = ["Risposta breve: caffè.", "Una risposta più lunga sul caffè.",
               "Target 東京 🚀", "Control 東京: more explanation.",
               "Selection fixture only", "Evaluation fixture only"]
    hashes = [sha(text.encode("utf-8")) for text in prompts]
    pairs = frame(pair_id=vector("s", ["pair-α", "pair-東京"]),
        target_sha256=vector("s", hashes[::2][:2]), control_sha256=vector("s", hashes[1::2][:2]),
        target_pos=vector("i", [7, 9]), control_pos=vector("i", [11, 13]))
    splits = frame(prompt_sha256=vector("s", hashes),
        split=vector("s", ["construction"] * 4 + ["selection", "evaluation"]))
    context = record(model=record(sha256=scalar("S", sha(b"F6d synthetic provenance fixture; no model")),
        architecture=scalar("S", "llama"), quantization=scalar("S", "F32"),
        hidden_size=scalar("I", 2), layers=scalar("I", 3), engine_revision=scalar("S", "fixture-engine/1")),
        capture=record(component=scalar("S", "residual"), positions=scalar("S", "last"),
            input_format=scalar("S", "raw_text"), tokenizer=scalar("S", "gguf_embedded"),
            add_special=scalar("L", True), parse_special=scalar("L", False),
            template_sha256=scalar("N"), context_length=scalar("I", 128),
            backend=scalar("S", "cpu"), relm_version=scalar("S", "0.0.0")),
        pairs=pairs, splits=splits, seed=scalar("I", 17))
    return context, pairs, splits, prompts


def encoding_fixtures(exact):
    inputs, values, diagnostics, norms = exact
    context, pairs, splits, prompts = context_fixture()
    value_node = record(neuron=vector("i", [1, 2]), value=vector("d", values))
    target, control = matrix(inputs["target"], inputs["ids"]), matrix(inputs["control"], inputs["ids"])
    digests = dict(target=encoded_digest("matrix", target), control=encoded_digest("matrix", control),
        pairs=encoded_digest("pairs", pairs), splits=encoded_digest("splits", splits),
        values=encoded_digest("values", value_node))
    per_pair = frame(pair_id=vector("s", inputs["ids"]), **{
        field: vector("d", [row[i + 1] for row in norms])
        for i, field in enumerate(("target_norm", "control_norm", "difference_norm", "used_norm"))})
    diagnostic_node = record(guard_relative=scalar("D", GUARD), pairs=per_pair,
        **{field: scalar("D", value) for field, value in diagnostics.items() if field != "guard_relative"})
    metadata = record(schema=scalar("S", "relm_direction/1"), layer=scalar("I", 2),
        component=scalar("S", "residual"), context=context,
        method=record(algorithm=scalar("S", "paired_difference_mean/1"),
            normalize_pairs=scalar("L", False), orthogonalize=scalar("L", False)),
        diagnostics=diagnostic_node,
        producer=record(relm_version=scalar("S", "0.0.0"), r_version=scalar("S", "4.6.1")),
        digests=record(**{name: scalar("S", value) for name, value in digests.items()}))
    artifact = record(neuron=vector("i", [1, 2]), value=vector("d", values), direction=metadata)
    digests["payload"] = encoded_digest("artifact", artifact)
    null_seed = copy.deepcopy(context)
    null_seed[1][-1] = ("seed", scalar("N"))
    primitives = dict(null=scalar("N"), empty_strings=vector("s", []),
        logical_true=scalar("L", True), integer_one=scalar("I", 1), double_one=scalar("D", 1.),
        positive_zero=scalar("D", 0.), negative_zero=scalar("D", -0.),
        utf8_text=scalar("S", "caffè 東京 🚀"),
        strings_ab_c=vector("s", ["ab", "c"]), strings_a_bc=vector("s", ["a", "bc"]),
        vector_types=record(logicals=vector("l", [False, True]),
            integers=vector("i", [-2147483647, 0, 2147483647]),
            doubles=vector("d", [-0., 0., 2**-1074, sys.float_info.max]),
            strings=vector("s", ["", "é", "e\u0301"]), empty_doubles=vector("d", [])))
    fixtures = [(name, "primitive", node) for name, node in primitives.items()]
    fixtures += [("target", "matrix", target), ("control", "matrix", control),
        ("pairs", "pairs", pairs), ("splits", "splits", splits),
        ("context", "context", context), ("context_null_seed", "context", null_seed),
        ("values", "values", value_node), ("artifact", "artifact", artifact)]
    return fixtures, digests, prompts


def node_rows(case, node, path="", field=""):
    tag, value = node
    row = [case, path, tag, field, "", "", "", "", ""]
    children = []
    if tag in "NLIDS":
        row[7] = "" if tag == "N" else (number(value) if tag == "D" else str(value))
        row[8] = scalar_bytes(tag, value).hex()
    elif tag in "lids":
        row[4] = len(value)
        children = [(str(i + 1), scalar(tag.upper(), item)) for i, item in enumerate(value)]
    elif tag in ("R", "F"):
        row[4] = len(value)
        if tag == "F": row[5:7] = [len(value[0][1][1]), len(value)]
        children = value
    else:
        nr, nc, names, columns, values = value
        row[5:7] = [nr, nc]
        children = [("row_names", vector("s", names)), ("column_names", vector("s", columns)),
                    ("values", vector("d", values))]
    yield row
    for name, child in children:
        yield from node_rows(case, child, path + "/" + name, name)


def controls(accepted, fixtures):
    results = []
    def check(name, ok):
        require(ok, "control failed: " + name)
        results.append((name, "passed"))
    main = accepted["unequal_n0_o0"][1]
    check("wrong_sign_is_detected", not close([-x for x in main], main))
    for normalized in (0, 1):
        forward = accepted[f"unequal_n{normalized}_o0"][1]
        reverse = accepted[f"reversed_sign_n{normalized}"][1]
        check(f"target_minus_control_sign_n{normalized}", close(reverse, [-x for x in forward]))
    check("unequal_pair_weighting_changes_direction", not close(main, accepted["unequal_n1_o0"][1]))
    check("nonorthogonal_control_projection_changes_direction", not close(main, accepted["unequal_n0_o1"][1]))
    source = accepted["unequal_n0_o0"][0]
    d = mean([[a - b for a, b in zip(t, c)] for t, c in zip(source["target"], source["control"])])
    wrong_mean = mean([[x / norm(row) for x in row] for row in source["control"]])
    wrong_unit = [x / norm(wrong_mean) for x in wrong_mean]
    wrong_projection = math.fsum(a * b for a, b in zip(d, wrong_unit))
    wrong_result = [a - b * wrong_projection for a, b in zip(d, wrong_unit)]
    wrong_result = [x / norm(wrong_result) for x in wrong_result]
    check("normalizing_control_rows_before_mean_is_detected", not close(wrong_result, accepted["unequal_n0_o1"][1]))
    check("final_unit_normalization_is_required", not close([x * 2 for x in main], main))
    check("naive_large_squared_norm_overflows", math.isinf(sum(x * x for x in [1e200, 1e200])))
    check("naive_tiny_squared_norm_underflows", sum(x * x for x in [1e-200, 1e-200]) == 0)
    for name, (case, value, _, _) in accepted.items():
        check("decimal90_" + name, close(value, decimal_direction(case["target"], case["control"],
            case["normalized"], case["projected"])))
        check("unit_norm_" + name, abs(norm(value) - 1) <= TOL)
    hashes = {name: encoded_digest(domain, node) for name, domain, node in fixtures}
    check("sha256_standard_abc_vector", sha(b"abc") ==
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    for a, b in (("positive_zero", "negative_zero"), ("integer_one", "double_one"),
                 ("logical_true", "integer_one"), ("strings_ab_c", "strings_a_bc"),
                 ("context", "context_null_seed")):
        check(a + "_differs_from_" + b, hashes[a] != hashes[b])
    nodes = {name: node for name, _, node in fixtures}
    matrix_node = copy.deepcopy(nodes["target"])
    nr, nc, names, columns, values = matrix_node[1]
    reordered = ("M", (nr, nc, list(reversed(names)), columns, values[nc:] + values[:nc]))
    check("pair_order_changes_matrix_digest", encoded_digest("matrix", reordered) != hashes["target"])
    column_major = ("M", (nr, nc, names, columns, [values[i * nc + j] for j in range(nc) for i in range(nr)]))
    check("column_major_mutation_is_detected", encoded_digest("matrix", column_major) != hashes["target"])
    check("domain_separation_is_required", encoded_digest("context", nodes["artifact"]) != hashes["artifact"])
    reordered_context = ("R", list(reversed(nodes["context"][1])))
    check("noncanonical_field_order_is_detected", encoded_digest("context", reordered_context) != hashes["context"])
    check("unicode_normalization_changes_digest", encoded_digest("primitive", scalar("S", "é")) !=
          encoded_digest("primitive", scalar("S", "e\u0301")))
    check("double_endianness_is_bound", struct.pack("<d", 1.) != struct.pack(">d", 1.))
    for tag, value in (("D", math.inf), ("D", math.nan), ("I", True), ("I", -2147483648),
                       ("S", "bad\0string"), ("S", "\ud800")):
        try:
            encoded_digest("primitive", scalar(tag, value))
        except (AssertionError, UnicodeError):
            results.append((f"reject_{tag}_{len(results)}", "passed"))
        else:
            raise AssertionError("invalid canonical primitive accepted")
    with io.BytesIO() as sink:
        writer = Writer(sink, CHUNK * 2 + 9)
        writer.write([b"x" * (CHUNK * 2 + 9)])
        check("stream_chunk_bound", writer.maximum == CHUNK and writer.bytes == CHUNK * 2 + 9)
        try:
            writer.write([b"x"])
        except AssertionError:
            check("stream_cap_refuses_before_write", len(sink.getvalue()) == CHUNK * 2 + 9)
        else:
            raise AssertionError("byte cap bypassed")
    return results


def write_csv(path, header, rows):
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.writer(output, lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    accepted, case_rows, input_rows, values, diagnostics, pairs = {}, [], [], [], [], []
    for case in cases():
        outcome, reason, pair = "accepted", "", ""
        try:
            value, diagnostic, pair_norms = arithmetic(case["target"], case["control"], case["ids"],
                case["normalized"], case["projected"])
        except Refusal as error:
            outcome, reason, pair = "rejected", error.reason, error.pair_id
        require((reason, pair) == (case["reason"], case["pair"]), f"unexpected outcome: {case['case']}: {reason}/{pair}")
        name = case["case"]
        case_rows.append((name, int(case["normalized"]), int(case["projected"]),
            len(case["target"]), len(case["target"][0]), outcome, reason, pair))
        for i, (t, c) in enumerate(zip(case["target"], case["control"])):
            input_rows.extend((name, case["ids"][i], i + 1, j + 1, number(a), number(b))
                              for j, (a, b) in enumerate(zip(t, c)))
        if not reason:
            accepted[name] = (case, value, diagnostic, pair_norms)
            values.extend((name, i + 1, number(x)) for i, x in enumerate(value))
            diagnostics.extend((name, field, number(x)) for field, x in diagnostic.items())
            pairs.extend((name, row[0], *map(number, row[1:])) for row in pair_norms)
    write_csv(directory / "cases.csv", ["case", "normalize_pairs", "orthogonalize", "n_pairs", "width", "outcome", "reason", "pair_id"], case_rows)
    write_csv(directory / "inputs.csv", ["case", "pair_id", "row", "neuron", "target", "control"], input_rows)
    write_csv(directory / "expected.csv", ["case", "neuron", "value"], values)
    write_csv(directory / "diagnostics.csv", ["case", "field", "value"], diagnostics)
    write_csv(directory / "pair-norms.csv", ["case", "pair_id", "target_norm", "control_norm", "difference_norm", "used_norm"], pairs)
    fixtures, digests, prompts = encoding_fixtures(accepted["encoding_exact"])
    fields, index = [], []
    for name, domain, node in fixtures:
        binary = directory / f"{name}.bin"
        with binary.open("wb") as output:
            writer = Writer(output, 1024 * 1024)
            checksum = writer.write(stream(domain, node))
        raw = binary.read_bytes()  # Tiny fixture export only; not the streaming serializer.
        (directory / f"{name}.hex").write_text(raw.hex() + "\n", encoding="ascii")
        require(sha(raw) == checksum, "streamed digest mismatch")
        fields.extend(node_rows(name, node))
        index.append((name, domain, writer.bytes, checksum, binary.name, f"{name}.hex", writer.maximum))
    write_csv(directory / "encoding.csv", ["case", "domain", "bytes", "sha256", "binary", "hex", "max_chunk_bytes"], index)
    write_csv(directory / "encoding-fields.csv", ["case", "path", "kind", "field", "length", "nrow", "ncol", "value", "scalar_hex"], fields)
    write_csv(directory / "artifact-digests.csv", ["field", "sha256"], digests.items())
    write_csv(directory / "prompts.csv", ["id", "text", "sha256"],
              [(i + 1, prompt, sha(prompt.encode("utf-8"))) for i, prompt in enumerate(prompts)])
    checks = controls(accepted, fixtures)
    checks.extend(("guard_" + row[0], "passed") for row in case_rows if row[5] == "rejected")
    write_csv(directory / "controls.csv", ["control", "outcome"], checks)
    provenance = dict(producer="reference_directions.py", producer_version=VERSION,
        python_version=platform.python_version(), python_implementation=platform.python_implementation(),
        interpreter_invocation=".golden-venv/bin/python", numpy_version=importlib.metadata.version("numpy"),
        gguf_version=importlib.metadata.version("gguf"), arithmetic="Python binary64 + math.fsum; Decimal90 cross-check",
        producer_sha256=sha(Path(__file__).read_bytes()), encoding_sha256=sha((ROOT / "ENCODING.md").read_bytes()),
        requirements_sha256=sha((REPO / "tests/llm-golden/requirements.txt").read_bytes()),
        tolerance_absolute=number(TOL), tolerance_relative=number(TOL), guard_relative=number(GUARD),
        accepted_cases=str(len(accepted)), rejected_cases=str(len(case_rows) - len(accepted)),
        expected_values=str(len(values)), encoding_vectors=str(len(fixtures)), controls=str(len(checks)))
    write_csv(directory / "provenance.csv", ["key", "value"], provenance.items())
    files = sorted(path for path in directory.iterdir() if path.name != "manifest.csv")
    write_csv(directory / "manifest.csv", ["file", "bytes", "sha256"],
              [(path.name, path.stat().st_size, sha(path.read_bytes())) for path in files])
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="generate only these new D-045 goldens")
    mode.add_argument("--check", action="store_true", help="recompute and byte-check every frozen fixture")
    args = parser.parse_args()
    require(platform.python_version() == "3.13.5", "use the pinned Python 3.13.5 reference venv")
    require(importlib.metadata.version("numpy") == "2.5.1", "pinned NumPy environment differs")
    require(importlib.metadata.version("gguf") == "0.19.0", "pinned gguf environment differs")
    goldens = ROOT / "goldens"
    if args.write:
        require(not goldens.exists() or not any(goldens.iterdir()), "refusing to replace nonempty goldens; document a new reason first")
        provenance = generate(goldens)
    else:
        with tempfile.TemporaryDirectory(prefix="relm-directions-check-") as temporary:
            expected = Path(temporary)
            provenance = generate(expected)
            require({p.name for p in expected.iterdir()} == {p.name for p in goldens.iterdir()}, "golden file inventory differs")
            for path in expected.iterdir():
                require(path.read_bytes() == (goldens / path.name).read_bytes(), "golden byte mismatch: " + path.name)
    print("D045_REFERENCE_OK " + " ".join(f"{name}={provenance[name]}" for name in
        ("accepted_cases", "rejected_cases", "expected_values", "encoding_vectors", "controls", "python_version")))
    print("producer_sha256=" + provenance["producer_sha256"])
    print("manifest_sha256=" + sha((goldens / "manifest.csv").read_bytes()))


if __name__ == "__main__":
    main()
