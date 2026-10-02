"""Fast fail-closed controls; runs locally and before the nightly native build."""
import json
from pathlib import Path
import unittest

from run import CASES, build_artifacts, check_fault, check_runtime_symbols, check_test_events, check_unconditional_source


def events(name="actual_test", outcome="ok", passed=1, ignored=0):
    return "\n".join(map(json.dumps, [
        {"type": "suite", "event": "started", "test_count": 1},
        {"type": "test", "event": "started", "name": name},
        {"type": "test", "event": outcome, "name": name},
        {"type": "suite", "event": "ok", "passed": passed, "failed": 0, "ignored": ignored},
    ]))


class HarnessControls(unittest.TestCase):
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
        bad = [events(outcome="ignored", passed=0, ignored=1), events(outcome="failed", passed=0),
               events(name="unrelated_test"), events() + "\n" + events()]
        for output in bad:
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                check_test_events(output, "actual_test")

    def test_unexpected_stdout_is_rejected(self):
        with self.assertRaises(ValueError):
            check_test_events("silently ignored noise\n" + events(), "actual_test")

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

    def test_all_selected_real_sources_are_unconditional(self):
        root = Path(__file__).resolve().parents[2] / "rebirth/src/rust/rebirth-llm"
        for binary, names in CASES.items():
            relative = "src/async_job.rs" if binary == "rebirth_llm" else f"tests/{binary}.rs"
            for name in names:
                with self.subTest(test=name):
                    check_unconditional_source((root / relative).read_text(), name)


if __name__ == "__main__":
    unittest.main()
