#!/usr/bin/env python3
"""Model-free rejection controls for the F6e memory receipt collector."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("f6e_instrumented", Path(__file__).with_name("instrumented.py"))
RUN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUN)


def events(binary="projection_production"):
    case = RUN.CASES[binary]
    return [{"type": "suite", "event": "started", "test_count": 1},
            {"type": "test", "event": "started", "name": case["id"]},
            {"type": "test", "event": "ok", "name": case["id"],
             "stdout": RUN.MARKER + json.dumps(RUN.expected_marker(case)) + "\n"},
            {"type": "suite", "event": "ok", "passed": 1, "failed": 0, "ignored": 0}]


def output(rows):
    return "\n".join(json.dumps(row) for row in rows)


def cargo():
    rows = []
    for name, kind, test, exe in (("rebirth_llm", "lib", False, None),
                                 ("rebirth_llm", "lib", True, "/fresh/x86_64-unknown-linux-gnu/debug/deps/rebirth_llm-a"),
                                 ("projection_production", "test", True, "/fresh/x86_64-unknown-linux-gnu/debug/deps/projection_production-b")):
        rows.append({"reason": "compiler-artifact", "target": {"name": name, "kind": [kind]},
                     "profile": {"test": test}, "features": ["default", "spill"], "executable": exe,
                     "filenames": [exe] if exe else ["/fresh/x86_64-unknown-linux-gnu/debug/deps/librebirth_llm-a.rlib"]})
    return rows + [{"reason": "build-finished", "success": True}]


def memcheck(error="", count="", suppress=""):
    return ('<valgrindoutput><protocolversion>4</protocolversion><protocoltool>memcheck</protocoltool>'
            '<args><argv><exe>/binary</exe></argv></args><status><state>RUNNING</state></status>'
            + error + '<status><state>FINISHED</state></status><errorcounts>' + count
            + '</errorcounts><suppcounts>' + suppress + '</suppcounts></valgrindoutput>')


class Controls(unittest.TestCase):
    def reject(self, rows):
        with self.assertRaises((RuntimeError, ValueError)):
            RUN.collect_test(output(rows), "", "projection_production")

    def changed_marker(self, key, value):
        rows = events()
        marker = RUN.expected_marker(RUN.CASES["projection_production"])
        marker[key] = value
        rows[2]["stdout"] = RUN.MARKER + json.dumps(marker)
        return rows

    def test_01_exact_integration_positive(self):
        self.assertEqual(RUN.collect_test(output(events()), "", "projection_production")["compared_values"], 288)

    def test_02_exact_worker_positive(self):
        rows = events("rebirth_llm")
        rows[2]["stdout"] = 'F6E_PROJECTION_BUFFER {"kind":1}\n' + rows[2]["stdout"]
        self.assertEqual(RUN.collect_test(output(rows), "", "rebirth_llm")["compared_values"], 3)

    def test_03_zero_tests(self):
        rows = events(); rows[0]["test_count"] = 0; self.reject(rows)

    def test_04_ignored(self):
        rows = events(); rows[2]["event"] = "ignored"; self.reject(rows)

    def test_05_failed(self):
        rows = events(); rows[2]["event"] = "failed"; self.reject(rows)

    def test_06_wrong_test(self):
        rows = events(); rows[2]["name"] = "other"; self.reject(rows)

    def test_07_duplicate_success(self):
        rows = events(); rows.insert(3, copy.deepcopy(rows[2])); self.reject(rows)

    def test_08_missing_capture(self):
        rows = events(); del rows[2]["stdout"]; self.reject(rows)

    def test_09_missing_marker(self):
        rows = events(); rows[2]["stdout"] = "completed"; self.reject(rows)

    def test_10_duplicate_marker(self):
        rows = events(); rows[2]["stdout"] *= 2; self.reject(rows)

    def test_11_wrong_cases(self):
        self.reject(self.changed_marker("executed_cases", 12))

    def test_12_wrong_refusals(self):
        self.reject(self.changed_marker("rejected_cases", 8))

    def test_13_wrong_values(self):
        self.reject(self.changed_marker("compared_values", 287))

    def test_14_false_expected_count(self):
        self.reject(self.changed_marker("expected_values", 287))

    def test_15_private_feature(self):
        self.reject(self.changed_marker("private_feature", True))

    def test_16_cfg_test_library(self):
        self.reject(self.changed_marker("library_cfg_test", True))

    def test_17_bool_as_integer(self):
        self.reject(self.changed_marker("model_loads", True))

    def test_18_float_as_integer(self):
        self.reject(self.changed_marker("constructor_calls", 2.0))

    def test_19_extra_marker_field(self):
        self.reject(self.changed_marker("invented", 1))

    def test_20_nan_marker(self):
        self.reject(self.changed_marker("compared_values", float("nan")))

    def test_21_duplicate_json_field(self):
        rows = events(); rows[2]["stdout"] = rows[2]["stdout"].replace('"status": "passed"', '"status": "failed", "status": "passed"'); self.reject(rows)

    def test_22_sanitizer_stderr(self):
        with self.assertRaises(RuntimeError):
            RUN.collect_test(output(events()), "ERROR: AddressSanitizer: heap-use-after-free", "projection_production")

    def test_23_sanitizer_captured(self):
        rows = events(); rows[2]["stdout"] += "runtime error: bad pointer"; self.reject(rows)

    def test_24_positive_artifacts(self):
        binaries, library = RUN.collect_artifacts(output(cargo()), Path("/fresh"))
        self.assertEqual(set(binaries), set(RUN.CASES)); self.assertEqual(library.name, "librebirth_llm-a.rlib")

    def test_25_no_production_rlib(self):
        with self.assertRaises(RuntimeError):
            RUN.collect_artifacts(output(cargo()[1:]), Path("/fresh"))

    def test_26_private_artifact(self):
        rows = cargo(); rows[0]["features"].append("projection-private")
        with self.assertRaises(RuntimeError): RUN.collect_artifacts(output(rows), Path("/fresh"))

    def test_27_no_spill_artifact(self):
        rows = cargo(); rows[0]["features"] = []
        with self.assertRaises(RuntimeError): RUN.collect_artifacts(output(rows), Path("/fresh"))

    def test_28_duplicate_binary(self):
        rows = cargo(); rows.insert(2, copy.deepcopy(rows[1]))
        with self.assertRaises(RuntimeError): RUN.collect_artifacts(output(rows), Path("/fresh"))

    def test_29_artifact_outside_target(self):
        rows = cargo(); rows[1]["executable"] = "/old/rebirth_llm"
        with self.assertRaises(RuntimeError): RUN.collect_artifacts(output(rows), Path("/fresh"))

    def test_30_build_failed(self):
        rows = cargo(); rows[-1]["success"] = False
        with self.assertRaises(RuntimeError): RUN.collect_artifacts(output(rows), Path("/fresh"))

    def test_31_memcheck_positive(self):
        self.assertEqual(RUN.collect_valgrind(memcheck(), Path("/binary"))["error_kinds"], [])

    def test_32_memcheck_fault_positive(self):
        text = memcheck('<error><kind>InvalidWrite</kind></error>')
        self.assertEqual(RUN.collect_valgrind(text, Path("/binary"), "InvalidWrite")["error_kinds"], ["InvalidWrite"])

    def test_33_memcheck_finding(self):
        with self.assertRaises(RuntimeError): RUN.collect_valgrind(memcheck('<error><kind>InvalidWrite</kind></error>'), Path("/binary"))

    def test_34_memcheck_unfinished(self):
        with self.assertRaises(RuntimeError): RUN.collect_valgrind(memcheck().replace('FINISHED', 'RUNNING'), Path("/binary"))

    def test_35_memcheck_wrong_tool(self):
        with self.assertRaises(RuntimeError): RUN.collect_valgrind(memcheck().replace('memcheck', 'none'), Path("/binary"))

    def test_36_memcheck_wrong_binary(self):
        with self.assertRaises(RuntimeError): RUN.collect_valgrind(memcheck(), Path("/other"))

    def test_37_memcheck_missing_fault(self):
        with self.assertRaises(RuntimeError): RUN.collect_valgrind(memcheck(), Path("/binary"), "Leak_DefinitelyLost")

    def test_38_memcheck_error_count(self):
        with self.assertRaises(RuntimeError): RUN.collect_valgrind(memcheck(count='<pair><count>1</count></pair>'), Path("/binary"))

    def test_39_memcheck_suppression(self):
        with self.assertRaises(RuntimeError): RUN.collect_valgrind(memcheck(suppress='<pair><count>1</count></pair>'), Path("/binary"))

    def test_40_exact_build_scope(self):
        for mode in ("sanitizers", "valgrind"):
            args = RUN.build_command(mode)
            self.assertEqual(args.count("--test"), 1)
            self.assertEqual(args[args.index("--test") + 1], "projection_production")
            self.assertIn("--no-run", args); self.assertIn("--lib", args)
            self.assertNotIn("--features", args); self.assertNotIn("--no-default-features", args)
            self.assertEqual("-Zbuild-std" in args, mode == "sanitizers")


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Controls))
    if not result.wasSuccessful() or result.testsRun != 40:
        raise SystemExit(1)
    print('F6E_PROJECTION_INSTRUMENTED_CONTROLS {"status":"passed","executed_tests":40}')
