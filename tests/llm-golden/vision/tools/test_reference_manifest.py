#!/usr/bin/env python3
"""Model-free provenance corruption controls, run by the ordinary Rust PR job."""

import contextlib
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import reference_manifest as ref


class ReferenceManifestTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="relm-reference-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.reference = self.root / "reference.txt"
        self.manifest_path = self.root / "reference.manifest.json"
        self.snapshot = b"2 2\n1.00000000e+00\n2.00000000e+00\n3.00000000e+00\n4.00000000e+00\n"
        self.reference.write_bytes(self.snapshot)
        self.context = {
            "source_sha": "a" * 40, "repository": "example/repo", "run_id": "100",
            "run_attempt": "2", "job": "vision-golden", "job_nonce": "c" * 64,
            "runner_name": "same-label-fresh-runner", "platform": {"machine": "arm64"},
        }
        self.paths = {}
        for name in ("model", "projector", "image", "upstream_archive", "producer_source",
                     "producer_binary", "cmake_cache", "library"):
            path = self.root / name
            path.write_bytes(f"fixture-{name}".encode())
            self.paths[name] = path
        self.pins = {name: ref.file_identity(self.paths[name])["sha256"]
                     for name in ("model", "projector", "image", "upstream_archive")}
        self.artifacts = ref.identities(self.paths, self.pins)
        self.build = {"upstream_tag": "b10828", "configure": ["cmake", "-DGGML_METAL=OFF"]}
        self.manifest = ref.make_manifest(self.snapshot, self.context, self.artifacts, [2, 2], self.build)
        self.write_manifest()

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def verified(self):
        return ref.load_verified(self.reference, self.manifest_path, self.context,
                                 ref.identities(self.paths, self.pins), [2, 2], self.build)

    def command(self):
        # Independent child hashes the actual stdin bytes before its marker;
        # touching the sentinel proves whether a rejected handoff ran anything.
        code = """
import hashlib, os, pathlib, sys
pathlib.Path(sys.argv[1]).touch()
data = sys.stdin.buffer.read()
assert hashlib.sha256(data).hexdigest() == os.environ['RELM_VISION_REFERENCE_SHA256']
assert len(data) == int(os.environ['RELM_VISION_REFERENCE_BYTES'])
print('embd-ATOL leg: fixture numerical assertion passed')
print('VISION_REFERENCE_CONSUMED sha256=' + hashlib.sha256(data).hexdigest() +
      ' bytes=' + str(len(data)) + ' tokens=2 embedding=2')
"""
        return [sys.executable, "-c", code, str(self.root / "comparator-started")]

    def assert_rejected_before_comparison(self):
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            with self.assertRaises((ref.EvidenceError, OSError, ValueError)):
                ref.run_comparator(self.verified(), self.command())
        self.assertFalse((self.root / "comparator-started").exists())
        self.assertNotIn(ref.SUCCESS_MARKER, captured.getvalue())
        self.assertNotIn("embd-ATOL leg:", captured.getvalue())

    def test_matching_manifest_sends_verified_bytes_and_binds_final_receipt(self):
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            ref.run_comparator(self.verified(), self.command())
        output = captured.getvalue()
        self.assertIn(f"{ref.SUCCESS_MARKER} sha256={ref.sha256(self.snapshot)}", output)
        self.assertIn("attempt=2", output)
        self.assertIn("nonce=" + "c" * 64, output)
        self.assertTrue((self.root / "comparator-started").exists())

    def test_same_path_changed_bytes_are_rejected(self):
        self.reference.write_bytes(self.snapshot.replace(b"4.000", b"5.000"))
        self.assert_rejected_before_comparison()

    def test_missing_manifest_is_rejected(self):
        self.manifest_path.unlink()
        self.assert_rejected_before_comparison()

    def test_stale_dimensions_are_rejected(self):
        self.manifest["reference"]["dimensions"] = [1, 4]
        self.write_manifest()
        self.assert_rejected_before_comparison()

    def test_changed_header_even_with_updated_hash_is_rejected(self):
        snapshot = self.snapshot.replace(b"2 2\n", b"1 4\n")
        self.reference.write_bytes(snapshot)
        self.manifest["reference"].update(sha256=ref.sha256(snapshot), bytes=len(snapshot), dimensions=[1, 4])
        self.write_manifest()
        self.assert_rejected_before_comparison()

    def test_stale_input_and_build_identities_are_rejected(self):
        for name in self.paths:
            with self.subTest(artifact=name):
                original = self.paths[name].read_bytes()
                self.paths[name].write_bytes(original + b" changed")
                self.assert_rejected_before_comparison()
                self.paths[name].write_bytes(original)

    def test_wrong_run_nonce_source_runner_and_prior_attempt_are_rejected(self):
        for key, wrong in (("run_id", "99"), ("job_nonce", "d" * 64),
                           ("source_sha", "b" * 40), ("job", "other-job"),
                           ("runner_name", "another-machine"), ("run_attempt", "1")):
            with self.subTest(field=key):
                # Same source/platform/run in the prior-attempt case is
                # deliberate: those fields alone cannot establish freshness.
                original = self.manifest["context"][key]
                self.manifest["context"][key] = wrong
                self.write_manifest()
                self.manifest["context"][key] = original
                self.assert_rejected_before_comparison()
        self.write_manifest()

    def test_path_replacement_after_verification_cannot_change_consumed_snapshot(self):
        verified = self.verified()
        self.reference.write_bytes(b"corrupt replacement after verification")
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            ref.run_comparator(verified, self.command())
        self.assertIn(verified.marker(), captured.getvalue())
        self.assertIn(ref.sha256(self.snapshot), captured.getvalue())

    def test_substituted_snapshot_is_rejected_before_child_start(self):
        verified = replace(self.verified(), snapshot=self.snapshot.replace(b"4.000", b"5.000"))
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            with self.assertRaisesRegex(ref.EvidenceError, "substituted verified snapshot"):
                ref.run_comparator(verified, self.command())
        self.assertFalse((self.root / "comparator-started").exists())
        self.assertNotIn(ref.SUCCESS_MARKER, captured.getvalue())

    def test_skip_or_wrong_digest_marker_cannot_be_numerical_success(self):
        for output in ("SKIP encoder_output_matches", "VISION_REFERENCE_CONSUMED sha256=wrong"):
            with self.subTest(output=output):
                captured = io.StringIO()
                with contextlib.redirect_stdout(captured):
                    with self.assertRaisesRegex(ref.EvidenceError, "numerical-success marker"):
                        ref.run_comparator(self.verified(), [sys.executable, "-c", f"print({output!r})"])
                self.assertNotIn(ref.SUCCESS_MARKER, captured.getvalue())

    def test_child_failure_cannot_be_success_even_with_a_marker(self):
        verified = self.verified()
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            with self.assertRaisesRegex(ref.EvidenceError, "exited 1"):
                ref.run_comparator(verified, [sys.executable, "-c",
                    f"print({verified.marker()!r}); raise SystemExit(1)"])
        self.assertNotIn(ref.SUCCESS_MARKER, captured.getvalue())

    def test_malformed_nonfinite_and_wrong_count_dumps_are_rejected(self):
        for snapshot in (b"", b"2 2 extra\n", b"0 2\n", b"2 2\n1\n",
                         b"1 1\nnan\n", b"1 1\ninf\n", b"1 1\n1e39\n"):
            with self.subTest(snapshot=snapshot):
                with self.assertRaises((ref.EvidenceError, ValueError)):
                    ref.dimensions(snapshot)

    def test_exact_test_binary_selection_rejects_missing_and_ambiguous_artifacts(self):
        path = self.root / "artifacts.jsonl"
        binary = self.root / "vlm_golden"
        binary.touch()
        item = {"reason": "compiler-artifact", "target": {"name": "vlm_golden"},
                "profile": {"test": True}, "executable": str(binary)}
        path.write_text(json.dumps(item) + "\n", encoding="utf-8")
        self.assertEqual(ref.exact_test_binary(path), str(binary))
        for text in ("", (json.dumps(item) + "\n") * 2):
            path.write_text(text, encoding="utf-8")
            with self.assertRaises(ref.EvidenceError):
                ref.exact_test_binary(path)

    def test_full_cli_uses_independent_environment_and_exact_stdin_handoff(self):
        # Exercise the actual CLI/configuration path with tiny fake input/build
        # artifacts. The child independently hashes stdin; no model is loaded.
        binary = self.root / "fake-comparator"
        binary.write_text(f"#!{sys.executable}\n" + """
import hashlib, os, sys
data = sys.stdin.buffer.read()
digest = hashlib.sha256(data).hexdigest()
assert digest == os.environ['RELM_VISION_REFERENCE_SHA256']
assert len(data) == int(os.environ['RELM_VISION_REFERENCE_BYTES'])
print('embd-ATOL leg: model-free CLI fixture')
print('VISION_REFERENCE_CONSUMED sha256=' + digest + ' bytes=' + str(len(data)) +
      ' tokens=' + os.environ['RELM_VISION_REFERENCE_TOKENS'] +
      ' embedding=' + os.environ['RELM_VISION_REFERENCE_EMBEDDING'])
""", encoding="utf-8")
        binary.chmod(0o700)
        build_dir = self.root / "build"
        (build_dir / "bin").mkdir(parents=True)
        (build_dir / "bin/libfixture.so").write_bytes(b"fixture-shared-library")
        (build_dir / "CMakeCache.txt").write_bytes(b"fixture-cmake-cache")
        build_info = self.root / "build.json"
        build_info.write_text(json.dumps({
            "upstream_tag": "b10828", "configure": ["cmake"], "producer_compile": ["cc"],
            "cc": "fixture compiler", "cxx": "fixture compiler", "cmake": "fixture cmake",
        }), encoding="utf-8")
        self.reference.write_bytes(b"64 1536\n" + b"1.00000000e+00\n" * (64 * 1536))
        self.manifest_path.unlink()
        artifacts = self.root / "artifacts.jsonl"
        artifacts.write_text(json.dumps({
            "reason": "compiler-artifact", "target": {"name": "vlm_golden"},
            "profile": {"test": True}, "executable": str(binary),
        }) + "\n", encoding="utf-8")
        env = os.environ.copy()
        env.update({
            "GITHUB_SHA": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ref.ROOT, text=True).strip(),
            "GITHUB_REPOSITORY": "example/repo", "GITHUB_RUN_ID": "100", "GITHUB_RUN_ATTEMPT": "2",
            "GITHUB_JOB": "vision-golden", "GITHUB_WORKFLOW_REF": "example/repo/workflow@main",
            "GITHUB_WORKFLOW_SHA": "f" * 40, "RUNNER_NAME": "fixture-host",
            "RUNNER_OS": "fixture-os", "RUNNER_ARCH": "fixture-arch", "RELM_VISION_JOB_NONCE": "c" * 64,
            "RELM_VISION_UPSTREAM_TAG": "b10828", "RELM_VISION_BUILD_DIR": str(build_dir),
            "RELM_VISION_UPSTREAM_ARCHIVE": str(self.paths["upstream_archive"]),
            "RELM_TEST_MODEL_VLM": str(self.paths["model"]), "RELM_TEST_MMPROJ_VLM": str(self.paths["projector"]),
            "RELM_VISION_PRODUCER_BINARY": str(binary), "RELM_VISION_BUILD_INFO": str(build_info),
            "TARBALL_SHA256": self.pins["upstream_archive"], "MODEL_SHA256": self.pins["model"],
            "MMPROJ_SHA256": self.pins["projector"], "RELM_VISION_ENCODER_REFERENCE": str(self.reference),
            "RELM_VISION_REFERENCE_MANIFEST": str(self.manifest_path),
        })
        command = [sys.executable, str(Path(ref.__file__))]
        created = subprocess.run(command + ["create"], env=env, capture_output=True, text=True)
        self.assertEqual(created.returncode, 0, created.stderr)
        compare = command + ["compare", "--cargo-artifacts", str(artifacts)]
        result = subprocess.run(compare, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(ref.SUCCESS_MARKER, result.stdout)
        env["GITHUB_RUN_ATTEMPT"] = "3"
        result = subprocess.run(compare, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("embd-ATOL leg:", result.stdout)
        self.assertNotIn(ref.SUCCESS_MARKER, result.stdout)
        del env["RELM_VISION_JOB_NONCE"]
        result = subprocess.run(compare, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("job", result.stderr.lower())
        self.assertNotIn(ref.SUCCESS_MARKER, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
