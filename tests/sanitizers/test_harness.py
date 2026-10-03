"""Fast fail-closed controls; runs locally and before the nightly native build."""
from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
import tempfile
import unittest
from urllib.parse import unquote

from run import (CASES, CAPTURED_WORK_MARKERS, LEGACY_CASES, LIVE_CASES, STEERING_CASES, Run,
                 build_artifacts, build_command, check_fault, check_runtime_symbols,
                 check_test_events, check_unconditional_source, selected_cases,
                 test_command, test_log_label, test_source, library_artifact,
                 library_build_command, rust_archive_artifacts)


def events(name="actual_test", outcome="ok", passed=1, ignored=0):
    return "\n".join(map(json.dumps, [
        {"type": "suite", "event": "started", "test_count": 1},
        {"type": "test", "event": "started", "name": name},
        {"type": "test", "event": outcome, "name": name},
        {"type": "suite", "event": "ok", "passed": passed, "failed": 0, "ignored": ignored},
    ]))


class HarnessControls(unittest.TestCase):
    def test_full_default_preserves_legacy_live_and_steering_selections(self):
        flatten = lambda cases: {(binary, name) for binary, names in cases.items() for name in names}
        legacy, live, steering = flatten(LEGACY_CASES), flatten(LIVE_CASES), flatten(STEERING_CASES)
        self.assertEqual(len(legacy), 15)
        self.assertEqual(len(live), 15)
        self.assertFalse(legacy & live)
        self.assertEqual(len(steering), 10)
        self.assertFalse((legacy | live) & steering)
        self.assertEqual(flatten(selected_cases()), legacy | live | steering)
        self.assertEqual(flatten(selected_cases("live-only")), live)
        self.assertEqual(flatten(selected_cases("steering-only")), steering)
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

    def test_steering_source_guard_uses_included_file_and_rejects_wrong_module_body(self):
        root = Path(__file__).resolve().parents[2] / "rebirth/src/rust/rebirth-llm"
        for name in STEERING_CASES["rebirth_llm"]:
            with self.subTest(test=name):
                module = name.split("::")[0]
                expected = "src/live_steering_tests.rs" if module == "async_job" else f"src/{module}.rs"
                self.assertEqual(test_source("rebirth_llm", name), expected)
                source = (root / test_source("rebirth_llm", name)).read_text()
                check_unconditional_source(source, name)
                with self.assertRaisesRegex(RuntimeError, "missing unconditional"):
                    check_unconditional_source((root / "src/async_job.rs").read_text(), name)
                short = name.split("::")[-1]
                changed = source.replace(f"fn {short}() {{", f"fn {short}() {{\n    return;")
                self.assertNotEqual(changed, source)
                with self.assertRaisesRegex(RuntimeError, "possible early-return"):
                    check_unconditional_source(changed, name)

    def test_both_scoped_routes_build_production_archive_before_object_audit(self):
        class ReachedAudit(Exception):
            pass

        root = Path(__file__).resolve().parents[2]
        for selection in ("full", "live-only", "steering-only"):
            with self.subTest(selection=selection), tempfile.TemporaryDirectory() as directory:
                evidence = Path(directory)
                library = evidence / "librebirth_llm.rlib"
                library.write_bytes(b"not a real archive; routing control only")
                run = Run(root, evidence, evidence / "unused-target", selection)
                calls = []

                def command(argv, label, **kwargs):
                    calls.append((label, argv))
                    if label == "build":
                        rows = [{"reason": "compiler-artifact", "target": {"name": name},
                                 "profile": {"test": True}, "executable": "/tmp/" + name}
                                for name in run.cases]
                        rows.append({"reason": "build-finished", "success": True})
                    else:
                        self.assertEqual(label, "build-library")
                        rows = self.library_events()
                        rows[0]["filenames"] = [str(library)]
                    return 0, "\n".join(map(json.dumps, rows)), ""

                def audit():
                    raise ReachedAudit()

                run.command, run.audit_objects = command, audit
                with self.assertRaises(ReachedAudit):
                    run.build()
                labels = [label for label, _ in calls]
                self.assertEqual(labels, ["build"] if selection == "full" else ["build", "build-library"])
                if selection != "full":
                    self.assertNotIn("--test", calls[0][1])
                    self.assertEqual(calls[1][1], library_build_command())
                    receipt = json.loads((evidence / "library-artifact.json").read_text())
                    self.assertEqual(receipt["archive"], str(library))
                    self.assertRegex(receipt["sha256"], r"^[0-9a-f]{64}$")

    def test_steering_golden_requires_its_own_captured_work_marker(self):
        name = STEERING_CASES["rebirth_llm"][0]
        marker = "F6B_GOLDEN compared_values=3360 "
        self.assertEqual(CAPTURED_WORK_MARKERS[name], marker)
        self.assertIn("--show-output", test_command("/tmp/binary", name))
        rows = [json.loads(line) for line in events(name).splitlines()]
        rows[2]["stdout"] = marker + "max_activation_delta=0 max_logit_delta=0\n"
        check_test_events("\n".join(map(json.dumps, rows)), name)
        for wrong in ("F6_GOLDEN activation_values=3840 ", "F6B_GOLDEN compared_values=0 ", ""):
            rows[2]["stdout"] = wrong
            with self.subTest(marker=wrong), self.assertRaisesRegex(RuntimeError, "missing captured"):
                check_test_events("\n".join(map(json.dumps, rows)), name)

    def test_production_library_build_keeps_target_std_and_no_extra_tests(self):
        command = library_build_command()
        self.assertEqual(command[:2], ["cargo", "build"])
        for flag in ("--locked", "--lib", "-Zbuild-std", "--message-format=json", "-vv"):
            self.assertIn(flag, command)
        self.assertEqual(command[command.index("--target") + 1], "x86_64-unknown-linux-gnu")
        self.assertNotIn("--test", command)

    @staticmethod
    def library_events():
        return [{"reason": "compiler-artifact", "target": {"name": "rebirth_llm", "kind": ["lib"]},
                 "profile": {"test": False}, "executable": None,
                 "filenames": ["/tmp/librebirth_llm.rlib"]},
                {"reason": "build-finished", "success": True}]

    def test_production_library_requires_actual_archive_and_success(self):
        rows = self.library_events()
        self.assertEqual(library_artifact("\n".join(map(json.dumps, rows))),
                         Path("/tmp/librebirth_llm.rlib"))
        for bad in (rows[:-1], rows[1:], rows + [rows[0]], rows + [rows[1]],
                    [rows[0], {"reason": "build-finished", "success": False}]):
            with self.subTest(events=bad), self.assertRaises(RuntimeError):
                library_artifact("\n".join(map(json.dumps, bad)))

    def test_libtest_event_cannot_substitute_for_production_archive(self):
        for change in ({"profile": {"test": True}}, {"executable": "/tmp/libtest"},
                       {"filenames": []}, {"filenames": ["/tmp/librebirth_llm.rmeta"]},
                       {"filenames": ["/tmp/librebirth_llm-a.rlib", "/tmp/librebirth_llm-b.rlib"]},
                       {"target": {"name": "rebirth_llm", "kind": ["bin"]}}):
            rows = self.library_events()
            rows[0].update(change)
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                library_artifact("\n".join(map(json.dumps, rows)))

    def test_library_receipt_rejects_spoofed_or_malformed_output(self):
        output = "\n".join(map(json.dumps, self.library_events()))
        for bad in ("junk\n" + output, '{malformed\n' + output,
                    '[rebirth-llm 0.0.0] ' + output):
            with self.subTest(output=bad), self.assertRaises((RuntimeError, ValueError)):
                library_artifact(bad)

    @staticmethod
    def archive_events(arrow="aa", include_library=True):
        crates = ["std", "arrow_array"] + (["rebirth_llm"] if include_library else [])
        rows = [{"reason": "compiler-artifact", "target": {"name": crate, "kind": ["rlib"] if crate == "std" else ["lib"]},
                 "profile": {"test": False}, "executable": None,
                 "filenames": [f"/tmp/lib{crate}-{arrow if crate == 'arrow_array' else 'bb'}.rlib"]}
                for crate in crates]
        return rows + [{"reason": "build-finished", "success": True}]

    def test_both_actual_build_variants_are_audited_without_arbitrary_selection(self):
        outputs = {"build": self.archive_events(include_library=False),
                   "build-library": self.archive_events(arrow="cc")}
        archives = rust_archive_artifacts({s: "\n".join(map(json.dumps, rows))
                                          for s, rows in outputs.items()})
        self.assertEqual(set(archives), {"std", "arrow_array", "rebirth_llm"})
        self.assertEqual(archives["arrow_array"], {Path("/tmp/libarrow_array-aa.rlib"): ["build"],
                                                  Path("/tmp/libarrow_array-cc.rlib"): ["build-library"]})
        self.assertEqual(archives["std"], {Path("/tmp/libstd-bb.rlib"): ["build", "build-library"]})
        self.assertEqual(sum(map(len, archives.values())), 4)

    def test_duplicate_or_missing_archive_within_a_build_is_rejected(self):
        rows = self.archive_events()
        for bad in (rows + [rows[0]], rows[1:], rows[:-1], rows + [rows[-1]]):
            with self.subTest(events=bad), self.assertRaises(RuntimeError):
                rust_archive_artifacts({"build": "\n".join(map(json.dumps, bad))})

    def test_archive_identity_requires_declared_absolute_rlib(self):
        for change in ({"filenames": ["/tmp/notstd.rlib"]}, {"filenames": ["libstd-aa.rlib"]},
                       {"filenames": ["/tmp/libstd-aa.rlib", "/tmp/libstd-bb.rlib"]},
                       {"filenames": ["/tmp/libstd-aa.rmeta"]}, {"executable": "/tmp/a"},
                       {"profile": {"test": True}}, {"profile": {}},
                       {"target": {"name": "std", "kind": ["bin"]}}):
            rows = self.archive_events()
            rows[0].update(change)
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                rust_archive_artifacts({"build": "\n".join(map(json.dumps, rows))})

    def test_retained_real_cargo_shapes_cover_full_and_live_builds(self):
        fixture = Path(__file__).parent / "fixtures/cargo-archives"
        full = rust_archive_artifacts({"build": (fixture / "full-build.jsonl").read_text()})
        self.assertEqual(sum(map(len, full.values())), 3)
        live_test = (fixture / "live-test-build.jsonl").read_text()
        live_library = (fixture / "live-library-build.jsonl").read_text()
        live = rust_archive_artifacts({"build": live_test, "build-library": live_library})
        self.assertEqual(sum(map(len, live.values())), 4)
        self.assertEqual(len(live["arrow_array"]), 2)
        self.assertEqual(library_artifact(live_library), next(iter(live["rebirth_llm"])))
        with self.assertRaisesRegex(RuntimeError, "missing required declared Rust archive"):
            rust_archive_artifacts({"build": live_test})

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
