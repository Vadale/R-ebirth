#!/usr/bin/env python3
"""Affected F6e review closure, without replaying accepted parent test scopes.

Build both default engine artifacts to retain the production-rlib audit. Execute
only the new zero/live test under ASan/UBSan, and the previously unexecuted worker
plus the new zero/live test under separate baseline Memcheck. No R/SEXP claim.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re

SPEC = importlib.util.spec_from_file_location("projection_memory", Path(__file__).with_name("instrumented.py"))
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)
BASE, require, digest = P.BASE, P.require, P.digest
ZERO_ID = "projection::review_tests::projection_zero_live_capture_preserves_identity_without_row_work"
ZERO_SOURCE = "rebirth/src/rust/rebirth-llm/src/projection_review_tests.rs"
MARKER = "F6E_PROJECTION_REVIEW_TEST "


def selected(mode):
    require(mode in ("sanitizers", "valgrind"), "unknown mode")
    return ([P.CASES["rebirth_llm"]["id"]] if mode == "valgrind" else []) + [ZERO_ID]


def expected_zero(source):
    return {"test": ZERO_ID.split("::")[-1], "status": "passed",
            "expected_cases": 8, "executed_cases": 8,
            "expected_rejections": 2, "rejected_cases": 2,
            "expected_values": 224, "compared_values": 224, "max_abs_error": 0.0,
            "model_loads": 1, "constructor_calls": 1, "probe_decodes": 2,
            "live_states": 2, "zero_rows": 0, "zero_read_bytes": 0,
            "zero_write_bytes": 0, "zero_barriers": 0, "audit_rows": 4,
            "refused_deliveries": 0, "source": source}


def collect_zero(output, errors, source):
    BASE.check_test_events(output, ZERO_ID)
    events = [P.strict_json(line) for line in output.splitlines() if line.strip()]
    captured = events[2].get("stdout")
    require(isinstance(captured, str), "missing zero/live captured stdout")
    require(not BASE.FINDING.search(output + errors + captured), "sanitizer finding")
    lines = [line for line in captured.splitlines() if line.startswith(MARKER)]
    require(len(lines) == 1 and captured.count(MARKER) == 1, "missing/duplicate/misplaced review marker")
    record = P.strict_json(lines[0][len(MARKER):])
    expected = expected_zero(source)
    require(isinstance(record, dict) and set(record) == set(expected), "review field set differs")
    for key, value in expected.items():
        require(type(record[key]) is type(value) and record[key] == value,
                f"review marker mismatch: {key}")
    return record


class ReviewRun(P.ProjectionRun):
    def __init__(self, evidence, target, mode, manifest_path):
        super().__init__(evidence, target, mode, manifest_path)
        self.selection = "projection-review-fixes"
        self.cases = {"rebirth_llm": selected(mode)}
        self.env["F6E_SOURCE"] = self.manifest_sha256

    def preflight(self):
        required = {ZERO_SOURCE, "tests/projection/instrumented_review.py",
                    "tests/projection/instrumented_review_controls.py",
                    "tests/projection/instrumented_path_controls.py",
                    ".github/workflows/nightly-memory-safety.yaml"}
        require(required <= set(self.manifest["source_hashes"]), "incomplete review scope")
        require(self.manifest.get("selection") == self.selection, "wrong review manifest")
        require(self.manifest.get("selected_tests") == {
            "sanitizers": selected("sanitizers"), "valgrind": selected("valgrind")}, "wrong selected tests")
        BASE.check_unconditional_source((self.root / ZERO_SOURCE).read_text(), ZERO_ID)
        super().preflight()

    def execute(self, artifacts):
        binary = artifacts["rebirth_llm"]
        _, symbols, _ = self.command(["llvm-nm-19", "--defined-only", binary], "binary-rebirth_llm-symbols")
        self.command(["ldd", binary], "binary-rebirth_llm-linkage")
        for function in P.FUNCTIONS:
            require(re.search(r"\b[TtWw] " + function + r"$", symbols, re.M),
                    f"projection access function absent: {function}")
        if self.mode == "sanitizers":
            BASE.check_runtime_symbols(symbols)
        else:
            require(not re.search(r"\b[TtWw] __(?:asan|ubsan)_", symbols), "Memcheck sanitizer binary")
        receipts = []
        for exact in selected(self.mode):
            label = BASE.test_log_label(exact)
            argv = ["--exact", exact, "--test-threads=1", "--format=json", "-Zunstable-options", "--show-output"]
            command = [binary, *argv] if self.mode == "sanitizers" else self.valgrind_args(binary, label, argv)
            _, out, err = self.command(command, label, timeout=600 if self.mode == "valgrind" else 180)
            marker = (collect_zero(out, err, self.manifest_sha256) if exact == ZERO_ID
                      else P.collect_test(out, err, "rebirth_llm"))
            memory = (P.collect_valgrind((self.evidence / (label + ".xml")).read_text(), binary)
                      if self.mode == "valgrind" else None)
            source = ZERO_SOURCE if exact == ZERO_ID else P.CASES["rebirth_llm"]["source"]
            receipts.append({"selection": self.selection, "mode": self.mode,
                             "binary": "rebirth_llm", "binary_sha256": digest(binary),
                             "test": exact, "source_file": source, "source_sha256": digest(self.root / source),
                             "marker": marker, "memcheck": memory,
                             "stdout_file": label + ".out", "stderr_file": label + ".err",
                             "stdout_sha256": digest(self.evidence / (label + ".out")),
                             "stderr_sha256": digest(self.evidence / (label + ".err")), "status": "executed_ok"})
            self.save("executed-tests.json", receipts)
        require([r["test"] for r in receipts] == selected(self.mode), "incomplete affected selection")
        P.verify_sources(self.root, self.manifest)
        require(digest(self.manifest_path) == self.manifest_sha256, "manifest changed")
        totals = {key: sum(r["marker"][key] for r in receipts)
                  for key in ("executed_cases", "rejected_cases", "compared_values", "model_loads", "constructor_calls")}
        expected = ((8, 2, 224, 1, 1) if self.mode == "sanitizers" else (18, 4, 227, 2, 2))
        require(tuple(totals.values()) == expected, "affected totals differ")
        summary = {"status": "passed", "mode": self.mode, "selection": self.selection,
                   "executed_tests": len(receipts), **totals, "default_features": P.FEATURES,
                   "source_manifest_sha256": self.manifest_sha256,
                   "production_integration_built_not_executed": True,
                   "registry_r_gc_or_ffi_acceptance": False}
        self.save("projection-review-summary.json", summary)
        self.save("artifact-sha256.json", {str(p.relative_to(self.evidence)): digest(p)
                  for p in sorted(self.evidence.rglob("*")) if p.is_file()})
        (self.evidence / "SUCCESS.txt").write_text(
            "Affected F6e CPU memory cases passed. Parent accepted cases were not replayed.\n"
            "No R/SEXP, GPU, ThreadSanitizer, new numerical accuracy or performance claim.\n")
        print("F6E_PROJECTION_REVIEW_INSTRUMENTED " + json.dumps(summary, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("sanitizers", "valgrind"), required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--source-manifest", type=Path,
                        default=Path(__file__).with_name("instrumented-review-scope.json"))
    args = parser.parse_args()
    require(not args.evidence.exists(), "evidence must be new")
    args.evidence.mkdir(parents=True)
    runner = ReviewRun(args.evidence.resolve(), args.target.resolve(), args.mode, args.source_manifest.resolve())
    try:
        runner.preflight()
        runner.execute(runner.build())
    except Exception as error:
        (runner.evidence / "FAILURE.txt").write_text(f"{type(error).__name__}: {error}\n")
        raise


if __name__ == "__main__":
    main()
