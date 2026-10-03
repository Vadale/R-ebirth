"""Fast fail-closed controls; runs locally and before the nightly native build."""
from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
import tempfile
import unittest
from urllib.parse import unquote

from run import (CASES, CAPTURED_WORK_MARKERS, LEGACY_CASES, LIVE_CASES, Run,
                 build_artifacts, build_command, check_fault, check_runtime_symbols,
                 check_test_events, check_unconditional_source, selected_cases,
                 test_command, test_log_label, test_source)


def events(name="actual_test", outcome="ok", passed=1, ignored=0):
    return "\n".join(map(json.dumps, [
        {"type": "suite", "event": "started", "test_count": 1},
        {"type": "test", "event": "started", "name": name},
        {"type": "test", "event": outcome, "name": name},
        {"type": "suite", "event": "ok", "passed": passed, "failed": 0, "ignored": ignored},
    ]))


class HarnessControls(unittest.TestCase):
    def test_full_default_preserves_legacy_and_adds_only_live_cases(self):
        flatten = lambda cases: {(binary, name) for binary, names in cases.items() for name in names}
        legacy, live = flatten(LEGACY_CASES), flatten(LIVE_CASES)
        self.assertEqual(len(legacy), 15)
        self.assertEqual(len(live), 15)
        self.assertFalse(legacy & live)
        self.assertEqual(flatten(selected_cases()), legacy | live)
        self.assertEqual(flatten(selected_cases("live-only")), live)
        with self.assertRaisesRegex(RuntimeError, "unknown sanitizer selection"):
            selected_cases("typo")

    def test_live_build_omits_old_integration_targets_without_dropping_instrumentation(self):
        command = build_command(selected_cases("live-only"))
        self.assertNotIn("--test", command)
        for flag in ("--locked", "--lib", "-Zbuild-std", "--no-run", "--message-format=json", "-vv"):
            self.assertIn(flag, command)
        full = build_command(selected_cases())
        self.assertEqual([full[i + 1] for i, arg in enumerate(full) if arg == "--test"],
                         [name for name in LEGACY_CASES if name != "rebirth_llm"])

    def test_source_paths_follow_the_selected_unit_module(self):
        for module in ("async_job", "live_capture", "live_spill"):
            name = next(name for name in LIVE_CASES["rebirth_llm"] if name.startswith(module + "::"))
            self.assertEqual(test_source("rebirth_llm", name), f"src/{module}.rs")
        self.assertEqual(test_source("synthetic_trace", LEGACY_CASES["synthetic_trace"][0]),
                         "tests/synthetic_trace.rs")
        with self.assertRaises(RuntimeError):
            test_source("rebirth_llm", "unknown::tests::fake")

    def test_selected_log_paths_are_portable_and_preserve_test_ids(self):
        names = [name for cases in CASES.values() for name in cases]
        labels = [test_log_label(name) for name in names]
        self.assertEqual(len(labels), len(set(labels)))
        for name, label in zip(names, labels):
            with self.subTest(name=name):
                self.assertNotRegex(label + ".out", r'["<>:|*?\\/\r\n]')
                self.assertEqual(unquote(label.removeprefix("test-")), name)
        original = "async_job::tests::async_cancel_busy_and_shutdown_return_ownership"
        self.assertIn(original, names)
        self.assertNotIn(":", test_log_label(original))

    def test_log_encoding_does_not_merge_escaped_or_flat_names(self):
        names = ["a::b", "a__b", "a%3A%3Ab", "a/b", "a\\b", "a\nb", "a?b"]
        labels = [test_log_label(name) for name in names]
        self.assertEqual(len(labels), len(set(labels)))
        self.assertEqual([unquote(label[5:]) for label in labels], names)

    @staticmethod
    def build_events():
        return [json.dumps({"reason": "compiler-artifact", "target": {"name": name},
                            "profile": {"test": True}, "executable": "/tmp/" + name})
                for name in CASES] + [json.dumps({"reason": "build-finished", "success": True})]

    def test_verbose_build_script_lines_are_not_artifacts(self):
        rows = self.build_events()
        rows.insert(0, '[compiler_builtins 0.1.143] cargo::rerun-if-changed=build.rs')
        rows.insert(2, '[rebirth-llm 0.0.0] ' + rows[-1])
        self.assertEqual(set(build_artifacts("\n".join(rows))), set(CASES))

    def test_build_log_cannot_hide_missing_or_bad_events(self):
        rows = self.build_events()
        corruptions = [rows[:-1], rows + [rows[-1]], rows + [rows[0]],
                       rows[1:], rows[:-1] + ['{"reason":"build-finished","success":false}'],
                       rows + ['{malformed'], rows + ['unrecognized output'],
                       rows[:-1] + ['[rebirth-llm 0.0.0] ' + rows[-1]]]
        for bad in corruptions:
            with self.subTest(output=bad), self.assertRaises((RuntimeError, ValueError)):
                build_artifacts("\n".join(bad))

    def test_live_artifacts_require_exact_selection(self):
        selected = selected_cases("live-only")
        rows = self.build_events()
        live = [row for row in rows if json.loads(row).get("target", {}).get("name") == "rebirth_llm"]
        live.append(rows[-1])
        self.assertEqual(set(build_artifacts("\n".join(live), selected)), {"rebirth_llm"})
        for bad in (rows, live[1:], live + [live[0]]):
            with self.subTest(output=bad), self.assertRaises(RuntimeError):
                build_artifacts("\n".join(bad), selected)

    def test_expected_fault_requires_failure_and_matching_diagnostic(self):
        check_fault(1, "ERROR: AddressSanitizer: stack-buffer-overflow", "stack-buffer-overflow")
        for status, output in [(0, "stack-buffer-overflow"), (1, "ordinary crash"),
                               (124, "stack-buffer-overflow"), (137, "stack-buffer-overflow")]:
            with self.subTest(status=status, output=output), self.assertRaises(RuntimeError):
                check_fault(status, output, "stack-buffer-overflow")

    def test_plain_binary_and_unresolved_runtime_are_rejected(self):
        check_runtime_symbols("000000 T __asan_init\n000000 T __ubsan_handle_add_overflow_abort\n")
        for symbols in ("000000 T main", "U __asan_init\nU __ubsan_handle_add_overflow_abort"):
            with self.subTest(symbols=symbols), self.assertRaises(RuntimeError):
                check_runtime_symbols(symbols)

    def test_named_executed_case_is_accepted(self):
        check_test_events(events(), "actual_test")

    def test_empty_filter_is_rejected(self):
        with self.assertRaises(RuntimeError):
            check_test_events('{"type":"suite","event":"ok","passed":0}', "actual_test")

    def test_ignored_failed_wrong_and_duplicate_tests_are_rejected(self):
        rows = events().splitlines()
        bad = [events(outcome="ignored", passed=0, ignored=1), events(outcome="failed", passed=0),
               events(name="unrelated_test"), events() + "\n" + events(),
               "\n".join([rows[0], rows[3], rows[1], rows[2]])]
        for output in bad:
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                check_test_events(output, "actual_test")

    def test_unexpected_stdout_is_rejected(self):
        with self.assertRaises(ValueError):
            check_test_events("silently ignored noise\n" + events(), "actual_test")

    def test_golden_stdout_must_be_captured_in_the_named_success(self):
        name, marker = next(iter(CAPTURED_WORK_MARKERS.items()))
        rows = [json.loads(line) for line in events(name).splitlines()]
        rows[2]["stdout"] = marker + "max_activation_delta=0.0 max_logit_delta=0.0\n"
        check_test_events("\n".join(map(json.dumps, rows)), name)
        command = test_command("/tmp/binary", name)
        self.assertIn("--exact", command)
        self.assertIn("--show-output", command)
        self.assertNotIn("--nocapture", command)
        self.assertIn("--nocapture", test_command("/tmp/binary", "actual_test"))

    def test_golden_marker_cannot_be_missing_malformed_or_spoofed(self):
        name, marker = next(iter(CAPTURED_WORK_MARKERS.items()))
        plain = events(name)
        suite_spoof = [json.loads(line) for line in plain.splitlines()]
        suite_spoof[3]["stdout"] = marker
        wrong_field = [json.loads(line) for line in plain.splitlines()]
        wrong_field[2]["message"] = marker
        malformed = [json.loads(line) for line in plain.splitlines()]
        malformed[2]["stdout"] = [marker]
        for output in (plain, marker + "\n" + plain, '"' + marker + '"\n' + plain,
                       plain + '\n' + json.dumps({"type": "fake", "stdout": marker}),
                       "\n".join(map(json.dumps, suite_spoof)),
                       "\n".join(map(json.dumps, wrong_field)),
                       "\n".join(map(json.dumps, malformed))):
            with self.subTest(output=output), self.assertRaises((RuntimeError, ValueError)):
                check_test_events(output, name)

    def test_source_skip_guards_reject_early_success(self):
        for body in ("if missing { return; }", 'let x = std::env::var("MODEL");', 'skip!("no model");'):
            with self.subTest(body=body), self.assertRaises(RuntimeError):
                check_unconditional_source("#[test]\nfn actual_test() { " + body + " }", "actual_test")

    def test_source_guard_accepts_iterator_skip(self):
        check_unconditional_source("#[test]\nfn actual_test() { rows.skip(1); assert!(true); }", "actual_test")

    def test_missing_or_cfg_guarded_test_is_rejected(self):
        for source in ("#[test]\nfn unrelated() {}", "#[test]\n#[cfg(feature=\"skip\")]\nfn actual_test() {}"):
            with self.subTest(source=source), self.assertRaises(RuntimeError):
                check_unconditional_source(source, "actual_test")

    def test_source_guard_isolates_function_before_following_helpers(self):
        source = ('    #[test]\n    fn actual_test() {\n'
                  '        assert!(true);\n    }\n'
                  '    fn helper() {\n        return;\n    }\n')
        check_unconditional_source(source, "module::tests::actual_test")
        with self.assertRaises(RuntimeError):
            check_unconditional_source(source.replace("assert!(true);", "return;"), "actual_test")
        with self.assertRaises(RuntimeError):
            check_unconditional_source(source + source, "actual_test")
        with self.assertRaises(RuntimeError):
            check_unconditional_source("#[test]\nfn actual_test() {\n", "actual_test")
        with self.assertRaises(RuntimeError):
            check_unconditional_source("#[test]\nfn actual_test() { if true {}\n return;\n}",
                                       "actual_test")

    def test_all_selected_real_sources_are_unconditional(self):
        root = Path(__file__).resolve().parents[2] / "rebirth/src/rust/rebirth-llm"
        for binary, names in CASES.items():
            for name in names:
                with self.subTest(test=name):
                    check_unconditional_source((root / test_source(binary, name)).read_text(), name)

    def test_live_execution_receipts_retain_exact_ids_and_hashes(self):
        # A fake command transport exercises receipt writing only: no native
        # executable, compiler, model, probe or object audit is invoked here.
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            binary = evidence / "fake-libtest"
            binary.write_bytes(b"receipt control; not executable")
            run = Run(root, evidence, evidence / "unused-target", "live-only")
            executed = []

            def fake_command(argv, label, **kwargs):
                if label.endswith("-symbols"):
                    output = "000000 T __asan_init\n000000 T __ubsan_handle_add_overflow_abort\n"
                elif label.endswith("-linkage"):
                    output = ""
                else:
                    name = argv[argv.index("--exact") + 1]
                    executed.append(name)
                    rows = [json.loads(line) for line in events(name).splitlines()]
                    if name in CAPTURED_WORK_MARKERS:
                        rows[2]["stdout"] = CAPTURED_WORK_MARKERS[name]
                    output = "\n".join(map(json.dumps, rows))
                (evidence / f"{label}.out").write_text(output)
                (evidence / f"{label}.err").write_text("")
                return 0, output, ""

            run.command = fake_command
            with redirect_stdout(StringIO()):
                run.execute({"rebirth_llm": binary})
            self.assertEqual(executed, LIVE_CASES["rebirth_llm"])
            receipts = json.loads((evidence / "executed-tests.json").read_text())
            self.assertEqual([receipt["test"] for receipt in receipts], executed)
            for receipt in receipts:
                self.assertEqual(receipt["selection"], "live-only")
                self.assertEqual(receipt["status"], "executed_ok")
                self.assertEqual(receipt["source_file"], test_source("rebirth_llm", receipt["test"]))
                for key in ("source_sha256", "binary_sha256", "stdout_sha256", "stderr_sha256"):
                    self.assertRegex(receipt[key], r"^[0-9a-f]{64}$")
            self.assertIn("Selection: live-only. 15 required", (evidence / "SUCCESS.txt").read_text())
            with self.assertRaisesRegex(RuntimeError, "unselected or missing execution binary"):
                run.execute({"synthetic_trace": binary})


if __name__ == "__main__":
    unittest.main()
