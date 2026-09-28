#!/usr/bin/env python3
"""Independent WP11a statistical oracles; standard library only, no relm calls."""
import argparse
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import platform
import sys

ROOT = Path(__file__).resolve().parent
REASON = "WP11a freezes independent statistical oracles before llm_probe implementation"
LAMBDAS = [10 ** (4 - i / 5) for i in range(41)]


def bisect(f, lo=-40.0, hi=40.0):
    assert f(lo) <= 0 <= f(hi), "root must be bracketed"
    for _ in range(160):
        mid = (lo + hi) / 2
        value = f(mid)
        if value == 0:
            return mid
        if value < 0:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def sigmoid(x):
    return 1 / (1 + math.exp(-x))


def ridge(rows, lam):
    # Nuisance x2 is balanced separately within every (x1, y) combination.
    # Thus strict convexity makes beta2=0; profile the unpenalized intercept.
    n = len(rows)
    balanced = sum(y for _, _, y in rows) == n/2
    intercept = lambda b: 0.0 if balanced else bisect(lambda a: sum(sigmoid(a + b*x) - y for x, _, y in rows) / n)
    def gradient(b):
        a = intercept(b)
        return sum(x * (sigmoid(a + b*x) - y) for x, _, y in rows) / n + lam*b
    b = bisect(gradient)
    a = intercept(b)
    loss = sum(math.log1p(math.exp(a + b*x)) - y*(a + b*x) for x, _, y in rows) / n
    return [a, b, 0.0, loss + lam*b*b/2, sigmoid(a-b), sigmoid(a+b)]


def metrics(rows):
    positives = [score for y, score in rows if y == 1]
    negatives = [score for y, score in rows if y == 0]
    wins = sum(p > n for p in positives for n in negatives)
    ties = sum(p == n for p in positives for n in negatives)
    pairs = len(positives) * len(negatives)
    auc = (wins + ties/2) / pairs if pairs else None
    accuracy = sum((score >= .5) == y for y, score in rows) / len(rows)
    return [len(rows), len(positives), len(negatives), wins, ties, pairs-wins-ties, auc, accuracy]


def interval(values):
    undefined = sum(v is None for v in values)
    if undefined:
        return [None, None, "undefined_draw", undefined]
    values = sorted(values)
    def quantile(p):
        h = (len(values)-1)*p
        lo = math.floor(h)
        return values[lo] + (h-lo)*(values[math.ceil(h)]-values[lo])
    lo, hi = quantile(.025), quantile(.975)
    return [None, None, "degenerate_bootstrap", 0] if lo == hi else [lo, hi, "available", 0]


def audit_split(rows):
    """Reject group leakage across holdout or CV; folds identify validation groups."""
    ids, groups = set(), {}
    for row in rows:
        ident, group, part, fold = (row[k] for k in ("row_id", "group", "partition", "fold"))
        if not ident or ident in ids or not group or part not in ("train", "test"):
            raise ValueError("invalid row identity/group/partition")
        ids.add(ident)
        if (part == "train" and (not fold.isdigit() or int(fold) < 1)) or (part == "test" and fold):
            raise ValueError("training requires positive fold; test cannot have a fold")
        if group in groups and groups[group][0] != part:
            raise ValueError("same group occurs in train and test")
        if group in groups and groups[group][1] != fold:
            raise ValueError("same training group occurs in multiple CV folds")
        groups[group] = (part, fold)
    if {part for part, _ in groups.values()} != {"train", "test"}:
        raise ValueError("both train and test groups required")
    if len({fold for part, fold in groups.values() if part == "train"}) < 3:
        raise ValueError("at least three training folds required")


def csv_bytes(header, rows):
    out = io.StringIO(newline="")
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(header.split(","))
    writer.writerows([["" if v is None else format(v, ".12g") if isinstance(v, float) else v for v in row] for row in rows])
    return out.getvalue().encode("utf-8")


def fixtures():
    result = {}
    def add(name, header, rows):
        result[name + ".csv"] = csv_bytes(header, rows)
    cases = {
        "separable": [(x, z, int(x > 0)) for x in (-1, 1) for z in (-1, 1)],
        "nonseparable": [(x, z, int(i < (1 if x < 0 else 2))) for x in (-1, 1) for z in (-1, 1) for i in range(4)],
    }
    add("ridge-data", "case,row_id,x1,x2,y", [[name, i+1, *row] for name, rows in cases.items() for i, row in enumerate(rows)])
    add("ridge-expected", "case,lambda,intercept,beta1,beta2,objective,p_minus,p_plus", [[name, lam, *ridge(rows, lam)] for name, rows in cases.items() for lam in LAMBDAS])
    samples = {
        "ties_original": [(0, .1), (1, .2), (0, .2), (1, .1)],
        "ties_three_eighths": [(0, .1), (1, .2), (0, .2), (1, 0.)],
        "constant": [(0, .5), (1, .5), (0, .5), (1, .5)],
        "threshold_inclusive": [(1, .5), (0, .49)],
        "lexical_confound_perfect": [(0, .1), (0, .1), (1, .9), (1, .9)],
        "permuted_label_control": [(0, .1), (1, .1), (0, .9), (1, .9)],
    }
    add("metric-data", "case,row_id,y,score", [[name, i+1, *row] for name, rows in samples.items() for i, row in enumerate(rows)])
    metric_header = "n,positive,negative,wins,ties,losses,auc,accuracy"
    add("metric-expected", "case," + metric_header, [[name, *metrics(rows)] for name, rows in samples.items()])
    # A/B/C have unequal sizes and both labels. D/E make undefined AUC draws.
    clusters = {"A": [(0, .1), (1, .8)], "B": [(0, .6), (0, .2), (1, .4)],
                "C": [(0, .9), (1, .7), (1, .8), (1, .95)], "D": [(0, .1)], "E": [(1, .9)]}
    draws = {"mixed": ["AAA", "BBB", "CCC", "ABC", "AAC", "BCC", "CAB", "BBA"],
             "undefined": ["DE", "DD", "EE"], "degenerate": ["AAA", "AAA", "AAA"]}
    add("bootstrap-data", "group,row_id,y,score", [[g, g+str(i+1), *row] for g, rows in clusters.items() for i, row in enumerate(rows)])
    add("bootstrap-indices", "case,draw,position,group", [[name, i+1, j+1, group] for name, values in draws.items() for i, value in enumerate(values) for j, group in enumerate(value)])
    boot = [[name, i+1, *metrics([row for group in value for row in clusters[group]])] for name, values in draws.items() for i, value in enumerate(values)]
    add("bootstrap-expected", "case,draw," + metric_header, boot)
    add("bootstrap-ci", "case,metric,lower,upper,reason,undefined_draws", [[name, metric, *interval([row[index] for row in boot if row[0] == name])] for name in draws for metric, index in (("auc", 8), ("accuracy", 9))])
    scale_rows = [["train", "t1", 1, 5], ["train", "t2", 2, 5], ["train", "t3", 3, 5], ["validation", "v1", 1000, -999]]
    add("scaling-data", "partition,row_id,x1,x2", scale_rows)
    add("scaling-expected", "column,center,scale,keep", [["x1", 2, math.sqrt(2/3), 1], ["x2", 5, 0, 0]])
    add("scaling-transformed", "row_id,x1", [[row[1], (row[2]-2)/math.sqrt(2/3)] for row in scale_rows])
    valid = [["a1", "a", "train", "1"], ["a2", "a", "train", "1"], ["b1", "b", "train", "2"], ["d1", "d", "train", "3"], ["c1", "c", "test", ""], ["c2", "c", "test", ""]]
    leaks = {"valid": valid, "holdout-leak": valid + [["a3", "a", "test", ""]], "cv-leak": valid + [["a3", "a", "train", "2"]]}
    for name, rows in leaks.items():
        add("split-" + name, "row_id,group,partition,fold", rows)
    # Selection is the arithmetic mean across folds, not row-weighted pooling.
    add("fold-diagnostics", "lambda,fold,n,auc", [[1, 1, 4, 1], [1, 2, 8, .5], [1, 3, 4, 1], [.1, 1, 4, .75], [.1, 2, 8, .875], [.1, 3, 4, .75]])
    add("fold-expected", "lambda,mean_fold_auc", [[1, 5/6], [.1, 19/24]])
    add("interval-display", "groups,positive_groups,negative_groups,undefined_draws,lower,upper,reason", [
        [0, 0, 0, 0, None, None, "not_evaluated"], [19, 9, 10, 0, .2, .8, "insufficient_groups"],
        [20, 4, 16, 0, .2, .8, "insufficient_class_groups"], [20, 16, 4, 0, .2, .8, "insufficient_class_groups"],
        [20, 5, 15, 0, .2, .8, "available"], [20, 5, 15, 1, None, None, "undefined_draw"],
        [20, 20, 20, 0, 1, 1, "degenerate_bootstrap"]])
    return result


def check_audits(payloads):
    for name in ("valid", "holdout-leak", "cv-leak"):
        rows = list(csv.DictReader(io.StringIO(payloads["split-" + name + ".csv"].decode())))
        try:
            audit_split(rows)
        except ValueError as error:
            if name == "valid":
                raise AssertionError("valid split refused") from error
        else:
            assert name == "valid", name + " was not refused"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="regenerate this new-feature reference set only")
    mode.add_argument("--check", action="store_true", help="check artifact bytes, provenance, oracles and split guards")
    mode.add_argument("--audit", type=Path, help="audit row_id/group/partition/fold CSV; fail on leakage")
    args = parser.parse_args()
    if args.audit:
        with args.audit.open(newline="", encoding="utf-8") as stream:
            audit_split(list(csv.DictReader(stream)))
        print("PASS: group-disjoint train/test and CV split")
        return
    payloads = fixtures()
    check_audits(payloads)
    provenance = ROOT / "provenance.json"
    if args.write:
        for name, data in payloads.items():
            (ROOT / name).write_bytes(data)
        files = {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()} for name, data in payloads.items()}
        for name in ("reference.py", "verify.R", "README.md"):
            data = (ROOT / name).read_bytes()
            files[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        metadata = {"format_version": 1, "reason": REASON, "generator": "reference.py", "python": platform.python_version(),
                    "dependencies": "Python standard library only", "objective": "mean(log(1+exp(eta))-y*eta)+lambda/2*sum(beta^2); intercept unpenalized",
                    "lambda_grid": "10^seq(4,-4,length.out=41)", "scaling": "train-only mean and RMS; drop constant columns",
                    "auc": "P(positive>negative)+0.5*P(tie)", "accuracy": "score>=0.5 predicts positive",
                    "bootstrap": {"production_draws": 2000, "representative_fixture_draws": 8, "unit": "whole group, with replacement", "quantile_type": 7, "undefined_policy": "withhold if any undefined draw; never redraw", "degenerate_policy": "withhold", "percentile_fixture": "raw arithmetic; product display guards tested separately", "minimum_groups": 20, "minimum_groups_containing_each_class": 5},
                    "numeric_serialization": "12 significant decimal digits; LF; UTF-8; no native float bit-exact claim", "files": files}
        provenance.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    else:
        metadata = json.loads(provenance.read_text(encoding="utf-8"))
        assert metadata["reason"] == REASON
        assert set(metadata["files"]) == set(payloads) | {"reference.py", "verify.R", "README.md"}
        for name, pin in metadata["files"].items():
            data = (ROOT / name).read_bytes()
            assert len(data) == pin["bytes"] and hashlib.sha256(data).hexdigest() == pin["sha256"], "byte/hash drift: " + name
        for name, expected in payloads.items():
            assert (ROOT / name).read_bytes() == expected, "reference recomputation drift: " + name
    print(f"PASS: {len(payloads)} fixture files, 82 ridge roots, metrics, bootstrap and split audits")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, ValueError, KeyError, OSError) as error:
        sys.exit("FAIL: " + str(error))
