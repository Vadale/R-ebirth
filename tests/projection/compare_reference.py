"""Approved portable comparison of recomputed observations with frozen references.

Frozen artifacts and their hashes remain exact. Only explicitly named F64
observations use the reference's predeclared absolute-plus-relative 1e-12 bound.
"""
import csv
import hashlib
import json
import math

FROZEN_MANIFEST_SHA = "78729e5fe710e30dffa83e76a9d084ee15091a0ef7074230172c3293f2463959"
F64_TOL = 1e-12
NUMERIC_COLUMNS = {
    "forward-logits.csv": {"logit"},
    "forward-row-witnesses.csv": {"before_norm", "after_norm"},
}
CASE_OBSERVATIONS = {
    "final_logits", "wrong_full_replay_max_logit_delta",
    "missing_max_logit_delta", "noop_max_logit_delta",
    "read_only_max_logit_delta", "residual_site_max_logit_delta",
    "last_row_only_final_logit_delta",
}


def f64_equal(actual, expected):
    assert not isinstance(actual, bool) and not isinstance(expected, bool)
    a, e = float(actual), float(expected)
    assert math.isfinite(a) and math.isfinite(e), "nonfinite observation"
    if a == e == 0:
        assert math.copysign(1, a) == math.copysign(1, e), "zero sign changed"
    assert abs(a - e) <= F64_TOL * (1 + abs(e)), "F64 observation outside frozen bound"


def manifest(directory):
    with (directory / "manifest.csv").open(newline="") as stream:
        reader = csv.DictReader(stream)
        assert reader.fieldnames == ["file", "bytes", "sha256"]
        rows = list(reader)
    names = [row["file"] for row in rows]
    assert len(names) == len(set(names))
    assert set(names) == {p.name for p in directory.iterdir()} - {"manifest.csv"}
    for row in rows:
        path = directory / row["file"]
        assert path.is_file() and path.parent == directory
        raw = path.read_bytes()
        assert str(len(raw)) == row["bytes"], "manifest size mismatch"
        assert hashlib.sha256(raw).hexdigest() == row["sha256"], "manifest hash mismatch"
    return names


def metadata(actual, expected, path=()):
    assert type(actual) is type(expected), ("metadata type", path)
    if isinstance(expected, dict):
        assert actual.keys() == expected.keys(), ("metadata keys", path)
        for key in expected:
            metadata(actual[key], expected[key], path + (key,))
    elif isinstance(expected, list):
        assert len(actual) == len(expected), ("metadata length", path)
        for index, (a, e) in enumerate(zip(actual, expected)):
            metadata(a, e, path + (index,))
    elif len(path) in (3, 4) and path[0] == "cases" and path[2] in CASE_OBSERVATIONS:
        assert isinstance(expected, float), ("F64 field type", path)
        f64_equal(actual, expected)
    else:
        assert actual == expected, ("exact metadata", path)


def numeric_detail(actual, expected):
    """Controls keep names/outcomes exact; only numeric diagnostic details vary."""
    try:
        a, e = json.loads(actual), json.loads(expected)
    except (ValueError, TypeError):
        assert actual == expected, "nonnumeric control detail changed"
        return
    if type(e) in (float, int):
        assert type(a) in (float, int)
        f64_equal(a, e)
    elif isinstance(e, list) and all(type(x) in (float, int) for x in e):
        assert isinstance(a, list) and len(a) == len(e)
        for x, y in zip(a, e):
            assert type(x) in (float, int)
            f64_equal(x, y)
    else:
        assert actual == expected, "nonnumeric control detail changed"


def table(actual, expected, name):
    with actual.open(newline="") as stream:
        a = list(csv.reader(stream))
    with expected.open(newline="") as stream:
        e = list(csv.reader(stream))
    assert len(a) == len(e) and a[0] == e[0], ("table shape", name)
    columns = NUMERIC_COLUMNS.get(name, set())
    for ar, er in zip(a[1:], e[1:]):
        assert len(ar) == len(er) == len(e[0]), ("row width", name)
        for field, av, ev in zip(e[0], ar, er):
            if field in columns:
                f64_equal(av, ev)
            elif name == "controls.csv" and field == "detail":
                numeric_detail(av, ev)
            else:
                assert av == ev, ("exact table field", name, field)


def compare_reference(actual, expected):
    assert hashlib.sha256((expected / "manifest.csv").read_bytes()).hexdigest() == FROZEN_MANIFEST_SHA, "frozen manifest changed"
    names = manifest(expected)
    assert manifest(actual) == names, "manifest inventory/order changed"
    for name in names:
        a, e = actual / name, expected / name
        if name == "manifest.json":
            metadata(json.loads(a.read_text()), json.loads(e.read_text()))
        elif name in NUMERIC_COLUMNS or name == "controls.csv":
            table(a, e, name)
        else:
            assert a.read_bytes() == e.read_bytes(), ("exact reference bytes", name)
    return {"files": len(names) + 1, "f64_abs": F64_TOL, "f64_rel": F64_TOL,
            "frozen_sha256": FROZEN_MANIFEST_SHA}
