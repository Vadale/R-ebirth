#!/usr/bin/env python3
"""D1 protocol regressions; Rust CI golden job, no model or R installation."""
import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("d1_evaluation", ROOT / "evaluate-model.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class EvaluationTests(unittest.TestCase):
    def test_spark_cannot_promote_the_consumed_holdout_as_fresh(self):
        base = ["evaluate-model.py", "--model", "unused", "--model-alias", "spark-x2.5-4b-q8_0",
                "--backend", "cpu", "--prompt-template", "unused", "--output", "unused"]
        for extra in (["--split", "held_out", "--candidate", "unused"],
                      ["--freeze-only", "--development-report", "unused"]):
            stderr = io.StringIO()
            with mock.patch.object(driver.sys, "argv", base + extra), contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as raised:
                    driver.main()
            self.assertEqual(raised.exception.code, 2)
            self.assertIn("consumed D1 pilot", stderr.getvalue())

    def test_consumed_pilot_regression_keeps_original_cases(self):
        cases = driver.verify.loads((ROOT / "cases.json").read_text())
        selected = [case["id"] for case in cases if case["split"] == driver.selected_split("regression")]
        self.assertEqual(selected, [case["id"] for case in cases if case["split"] == "held_out"])
        self.assertEqual(len(selected), 10)
        self.assertEqual(driver.selected_split("development"), "development")

    @classmethod
    def setUpClass(cls):
        cls.cases = [case for case in driver.verify.loads((ROOT / "cases.json").read_text())
                     if case["split"] == "development"][:3]

    def test_template_is_single_pass_and_rejects_unknown_missing_or_malformed(self):
        template = "Target: {{target}} Text: {{text}} Schema: {{schema}}"
        self.assertEqual(driver.render_prompt(template, "scope", "literal {{schema}}", "{}"),
                         "Target: scope Text: literal {{schema}} Schema: {}")
        self.assertIn('{"evidence":{}}', driver.render_prompt(template + ' {"evidence":{}}', "scope", "text", "{}"))
        for malformed in ("{{target}}{{text}}", template + "{{expected}}", template + "{{oops"):
            with self.assertRaises(ValueError):
                driver.render_prompt(malformed, "scope", "text", "{}")

    def test_candidate_rejects_drift_and_missing_provenance(self):
        identity = {"model_sha256": "model", "file_sha256": {"driver": "a"}, "sampling": {"seed": 101}}
        candidate = {"version": 1, "identity": identity,
                     "identity_sha256": driver.digest_bytes(driver.canonical(identity)),
                     "development_report_sha256": "1" * 64}
        driver.verify_candidate(candidate, identity)
        changed = copy.deepcopy(identity)
        changed["file_sha256"]["driver"] = "b"
        with self.assertRaises(ValueError):
            driver.verify_candidate(candidate, changed)
        with self.assertRaises(ValueError):
            driver.verify_candidate({**candidate, "identity_sha256": "0" * 64}, identity)
        with self.assertRaises(ValueError):
            driver.verify_candidate({**candidate, "development_report_sha256": ""}, identity)

    def test_runtime_drift_rejects_candidate_and_worker(self):
        runtime = dict(zip(driver.RUNTIME_KEYS, ("a" * 64, "0.2.0.9000", "R version 4.5.1", "aarch64")))
        identity = {"runtime": runtime}
        candidate = {"version": 1, "identity": identity,
                     "identity_sha256": driver.digest_bytes(driver.canonical(identity)),
                     "development_report_sha256": "1" * 64}
        driver.verify_runtime(runtime, runtime)
        for key in driver.RUNTIME_KEYS:
            changed = {**runtime, key: "changed"}
            with self.assertRaises(ValueError):
                driver.verify_candidate(candidate, {"runtime": changed})
            with self.assertRaises(ValueError):
                driver.verify_runtime(changed, runtime)

    def test_failures_stay_in_all_case_and_known_amount_denominators(self):
        rows = [{"id": case["id"], "status": "failure"} for case in self.cases]
        result = driver.score(self.cases, rows)
        self.assertEqual(result["metrics"]["failed_or_invalid"], 3)
        self.assertEqual(result["denominators"]["records"], 3)
        self.assertEqual(result["denominators"]["known_amount_records"], 1)
        self.assertEqual(result["metrics"]["known_amount_accuracy"], 0)
        self.assertFalse(all(driver.quality_gate(result).values()))
        self.assertTrue(all(value == 3 for value in result["denominators"]["per_field"].values()))

    def test_schema_and_task_validity_remain_separate(self):
        case = self.cases[0]
        output = copy.deepcopy(case["expected"])
        output["evidence"]["amount_usd"] = "Invented evidence"
        row = {"id": case["id"], "status": "success", "output": json.dumps(output)}
        result = driver.score([case], [row])
        self.assertEqual(result["schema_valid_records"], 1)
        self.assertEqual(result["metrics"]["valid_records"], 0)
        self.assertEqual(result["denominators"]["predicted_nonmissing_fields_in_task_valid_records"], 0)
        field = result["case_details"][0]["fields"]["amount_usd"]
        self.assertTrue(field["value_match"])
        self.assertFalse(field["scored_grounded_correct"])
        self.assertEqual(field["expected_evidence_anchor"], "$100 million")

    def test_nonfinite_invalid_output_keeps_a_serializable_diagnostic(self):
        case = self.cases[0]
        output = json.dumps(case["expected"]).replace("100000000", "1e999")
        result = driver.score([case], [{"id": case["id"], "status": "success", "output": output}])
        json.dumps(result, allow_nan=False)
        self.assertEqual(result["case_details"][0]["fields"]["amount_usd"]["observed"],
                         {"nonfinite_number": "inf"})

    def test_partial_worker_run_preserves_outputs_and_all_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            cases = [{"index": i, "id": case["id"], "seed": 101 + i} for i, case in enumerate(self.cases)]
            text = json.dumps(self.cases[0]["expected"])
            (directory / "output-0.json").write_bytes(text.encode())
            (directory / "output-1.partial.bin").write_bytes(b'{"amount')
            (directory / "records.tsv").write_text(
                "index\tid\tseed\tstatus\telapsed_seconds\terror_class\terror_message\n"
                f"0\t{cases[0]['id']}\t101\tsuccess\t0.1\t\t\n"
                f"1\t{cases[1]['id']}\t102\tfailure\t0.2\trelm_error_structured_output\ttoken budget\n")
            result, rows = driver.collect_results(directory, cases, {"returncode": -15, "timed_out": True})
            self.assertFalse(result["execution_complete"])
            self.assertEqual([row["id"] for row in rows], [case["id"] for case in cases])
            self.assertEqual(rows[0]["output"], text)
            self.assertEqual(rows[1]["status"], "failure")
            self.assertEqual(result["diagnostics"][1]["partial_sha256"], driver.digest_bytes(b'{"amount'))
            self.assertIsNone(result["diagnostics"][2]["elapsed_seconds"])
            self.assertEqual(len((directory / "predictions.jsonl").read_text().splitlines()), 3)

    def test_incomplete_or_unreadable_metadata_preserves_all_failure_ids(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            cases = [{"index": i, "id": case["id"], "seed": 101 + i} for i, case in enumerate(self.cases)]
            (directory / "records.tsv").write_text(
                "index\tid\tseed\tstatus\telapsed_seconds\terror_class\terror_message\n" +
                "".join(f"{case['index']}\t{case['id']}\t{case['seed']}\tfailure\t0.1\trelm_error_structured_output\tincomplete\n" for case in cases))
            runtime = dict(zip(driver.RUNTIME_KEYS, ("a" * 64, "0.2.0.9000", "R version 4.5.1", "aarch64")))
            runtime.update(package_path="/library/relm", native_library="/library/relm.so", backend="metal", context_length="4096")
            complete = "key\tvalue\n" + "".join(f"{key}\t{value}\n" for key, value in runtime.items())
            for name, raw in (("header-only", b"key\tvalue\n"),
                              ("duplicate", (complete + "backend\tmetal\n").encode()),
                              ("bad-shape", b"key\tvalue\nbackend\tmetal\textra\n"),
                              ("bad-utf8", b"key\tvalue\nbackend\t\xff\n"),
                              ("native-unreadable", complete.encode())):
                with self.subTest(name=name), mock.patch.object(driver.profile, "sha256", side_effect=PermissionError("native library is unreadable")):
                    (directory / "metadata.tsv").write_bytes(raw)
                    result, rows = driver.collect_results(directory, cases, {"returncode": 0, "timed_out": False})
                    self.assertFalse(result["execution_complete"])
                    self.assertTrue(any(error.startswith("Worker metadata:") for error in result["protocol_errors"]))
                    self.assertEqual([row["id"] for row in rows], [case["id"] for case in cases])
                    self.assertTrue(all(row["status"] == "failure" for row in rows))
                    self.assertEqual(len((directory / "predictions.jsonl").read_text().splitlines()), len(cases))


if __name__ == "__main__":
    unittest.main()
