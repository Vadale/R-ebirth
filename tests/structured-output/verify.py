#!/usr/bin/env python3
"""Offline S0 corpus integrity checks and fixed-record evaluation (stdlib only)."""
import argparse
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FIELDS = ("amount_usd", "amount_qualifier", "duration_years", "conditional_on_funds")
QUALIFIERS = {"stated", "approximate", "at_most", "less_than", "at_least", "more_than", "not_stated"}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def loads(text):
    def invalid_constant(value):
        raise ValueError(f"Non-JSON constant: {value}")
    return json.loads(text, object_pairs_hook=unique_object, parse_constant=invalid_constant)


def check_record(value, text):
    """Independent task assertions, not a general JSON Schema implementation."""
    assert type(value) is dict and set(value) == set(FIELDS) | {"evidence"}
    assert type(value["evidence"]) is dict and set(value["evidence"]) == set(FIELDS)
    for field, low, high in [("amount_usd", 0, 2147483647), ("duration_years", 1, 30)]:
        v = value[field]
        assert v is None or (type(v) is int and low <= v <= high), field
    assert value["amount_qualifier"] in QUALIFIERS
    assert value["conditional_on_funds"] is None or type(value["conditional_on_funds"]) is bool
    assert (value["amount_usd"] is None) == (value["amount_qualifier"] == "not_stated")
    for field in FIELDS:
        quote = value["evidence"][field]
        missing = value[field] is None or value[field] == "not_stated"
        assert (quote is None) == missing, f"{field}: missingness/evidence mismatch"
        if quote is not None:
            assert type(quote) is str and 0 < len(quote) <= 512 and quote in text, field


def audit(cases, manifest):
    for relative, expected in manifest["artifacts"].items():
        assert hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() == expected, relative
    sources = {s["id"]: s for s in manifest["sources"]}
    assert len(sources) == len(manifest["sources"])
    snapshots, groups, ids = {}, {}, set()
    for sid, source in sources.items():
        raw = (ROOT / source["path"]).read_bytes()
        assert hashlib.sha256(raw).hexdigest() == source["sha256"], sid
        snapshots[sid] = raw.decode("utf-8", errors="strict")
        assert source["split"] in {"development", "held_out"}
        previous = groups.setdefault(source["group_id"], source["split"])
        assert previous == source["split"], f"Group leakage: {source['group_id']}"
    for case in cases:
        assert case["id"] not in ids
        ids.add(case["id"])
        assert case["target"] and case["text"]
        if case["kind"] == "source_excerpt":
            source = sources[case["source_id"]]
            assert (case["group_id"], case["split"]) == (source["group_id"], source["split"])
            span = case["source_span"]
            assert 0 <= span["start"] < span["end"] <= len(snapshots[source["id"]])
            assert snapshots[source["id"]][span["start"]:span["end"]] == case["text"]
        else:
            assert case["kind"] == "constructed" and case["split"] == "contract"
            assert case["source_id"] is None and case["source_span"] is None
        check_record(case["expected"], case["text"])
    assert len(cases) == manifest["case_count"]


def evaluate(cases, rows):
    by_id = {}
    for row in rows:
        assert row["id"] not in by_id, "Duplicate prediction ID"
        by_id[row["id"]] = row
    assert set(by_id) == {c["id"] for c in cases}, "Missing or unexpected prediction IDs"
    correct = dict.fromkeys(FIELDS, 0)
    valid = exact = unsupported = predicted = known_amounts = correct_amounts = 0
    for case in cases:
        row, expected = by_id[case["id"]], case["expected"]
        if expected["amount_usd"] is not None:
            known_amounts += 1
        assert row["status"] in {"success", "failure", "abstained"}
        if row["status"] != "success":
            continue  # Failures remain in all-case and known-amount denominators.
        try:
            output = loads(row["output"]) if isinstance(row["output"], str) else row["output"]
            check_record(output, case["text"])
        except (AssertionError, ValueError, TypeError, KeyError):
            continue
        valid += 1
        matches = []
        for field in FIELDS:
            match = output[field] == expected[field]
            correct[field] += int(match)
            anchor, quote = expected["evidence"][field], output["evidence"][field]
            support = (anchor is None and quote is None) or (
                anchor is not None and quote is not None and anchor in quote)
            matches.append(match and support)
            if output[field] is not None and output[field] != "not_stated":
                predicted += 1
                unsupported += int(not (match and support))
        exact += int(all(matches))
        if expected["amount_usd"] is not None:
            correct_amounts += int(output["amount_usd"] == expected["amount_usd"])
    n = len(cases)
    assert n > 0
    return dict(records=n, valid_records=valid, failed_or_invalid=n-valid,
                record_accuracy=exact/n, field_accuracy={k: v/n for k, v in correct.items()},
                known_amount_accuracy=correct_amounts/known_amounts if known_amounts else None,
                unsupported_nonmissing_rate=unsupported/predicted if predicted else None,
                predicted_nonmissing=predicted)


def mutation_checks(cases, manifest):
    def rejected(fn):
        try:
            fn()
        except (AssertionError, ValueError):
            return
        raise AssertionError("A deliberately corrupt fixture was accepted")
    rejected(lambda: loads('{"a":1,"\\u0061":2}'))
    rejected(lambda: loads('{"x":NaN}'))
    example = next(c for c in cases if c["expected"]["amount_usd"] is not None)
    bad = copy.deepcopy(example["expected"]); bad["amount_usd"] = True
    rejected(lambda: check_record(bad, example["text"]))
    bad = copy.deepcopy(example["expected"]); bad["evidence"]["amount_usd"] = "INVENTED SOURCE"
    rejected(lambda: check_record(bad, example["text"]))
    altered = copy.deepcopy(manifest); altered["sources"][0]["sha256"] = "0" * 64
    rejected(lambda: audit(cases, altered))
    altered = copy.deepcopy(manifest); altered["sources"][1]["split"] = "held_out"
    rejected(lambda: audit(cases, altered))
    perfect = [dict(id=c["id"], status="success", output=c["expected"]) for c in cases]
    assert evaluate(cases, perfect)["record_accuracy"] == 1
    failed = [dict(id=c["id"], status="failure") for c in cases]
    assert evaluate(cases, failed)["record_accuracy"] == 0
    rejected(lambda: evaluate(cases, perfect[:-1]))
    brain = next(c for c in cases if c["id"] == "brain-new")
    wrong_quote = copy.deepcopy(brain["expected"])
    wrong_quote["evidence"]["amount_usd"] = "$260 million"
    result = evaluate([brain], [dict(id=brain["id"], status="success", output=wrong_quote)])
    assert result["valid_records"] == 1 and result["record_accuracy"] == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--predictions", type=Path, help="JSONL: id, status, output; all selected IDs required")
    parser.add_argument("--split", choices=["development", "held_out", "contract"])
    parser.add_argument("--gate", action="store_true", help="Apply the D1 pilot correctness gate")
    parser.add_argument("--self-test", action="store_true", help="Reject deliberate corruption; no model needed")
    args = parser.parse_args()
    cases = loads((ROOT / "cases.json").read_text())
    manifest = loads((ROOT / "manifest.json").read_text())
    audit(cases, manifest)
    if args.self_test:
        mutation_checks(cases, manifest)
    selected = [c for c in cases if args.split is None or c["split"] == args.split]
    if args.predictions:
        rows = [loads(line) for line in args.predictions.read_text().splitlines() if line.strip()]
        metrics = evaluate(selected, rows)
        print(json.dumps(metrics, indent=2))
        if args.gate:
            assert args.split == "held_out", "D1 gate requires the frozen held_out split"
            assert metrics["failed_or_invalid"] == 0
            assert metrics["record_accuracy"] >= 0.8
            assert metrics["known_amount_accuracy"] is not None and metrics["known_amount_accuracy"] >= 0.9
            assert metrics["unsupported_nonmissing_rate"] is not None and metrics["unsupported_nonmissing_rate"] <= 0.05
    else:
        assert not args.gate, "--gate needs actual prediction records"
        print(f"PASS: {len(cases)} cases; {len(manifest['sources'])} source snapshots; hashes, spans, grouped splits and task records.")
        if args.self_test:
            print("PASS: corruption/missing-output guards and metric denominator controls.")


if __name__ == "__main__":
    main()
