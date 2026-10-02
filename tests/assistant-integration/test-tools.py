#!/usr/bin/env python3
"""Local/CI packaging boundary tests; no assistant, model or network needed.

Run: python3 tests/assistant-integration/test-tools.py
The separately labelled R recovery test runs only when Rscript is installed.
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[2]
TOOL_PATH = ROOT / "integrations" / "assistant-tools.py"
spec = importlib.util.spec_from_file_location("assistant_tools", TOOL_PATH)
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)
EXPECTED_FILES = {
    "LICENSE-APACHE", "LICENSE-MIT", "SKILL.md", "agents/openai.yaml",
    "references/method-routing.md", "references/output-contract.md",
    "references/statistical-checks.md", "scripts/inspect-environment.R",
    "scripts/run-analysis.R",
}


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="assistant tools ")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.source = self.work / "source skill"
        shutil.copytree(tools.SKILL_SOURCE, self.source)
        self.manifest = self.work / "plugin.json"
        shutil.copyfile(tools.PLUGIN_MANIFEST, self.manifest)
        self.destination = self.work / "installed skill"
        source_patch = mock.patch.object(tools, "SKILL_SOURCE", self.source)
        manifest_patch = mock.patch.object(tools, "PLUGIN_MANIFEST", self.manifest)
        source_patch.start()
        manifest_patch.start()
        self.addCleanup(source_patch.stop)
        self.addCleanup(manifest_patch.stop)

    def test_install_spaced_path_and_content_receipt(self):
        receipt = tools.install(self.destination)
        actual = {p.relative_to(self.destination).as_posix()
                  for p in self.destination.rglob("*") if p.is_file()}
        self.assertEqual(actual, EXPECTED_FILES | {tools.RECEIPT_NAME})
        hashes = {}
        for name in EXPECTED_FILES:
            source_bytes = (self.source / name).read_bytes()
            self.assertEqual((self.destination / name).read_bytes(), source_bytes)
            hashes[name] = hashlib.sha256(source_bytes).hexdigest()
        self.assertEqual(receipt["files"], hashes)
        canonical = json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual(receipt["content_sha256"], hashlib.sha256(canonical).hexdigest())
        self.assertTrue(tools.verify(self.destination)["verified"])
        saved = json.loads((self.destination / tools.RECEIPT_NAME).read_bytes())
        self.assertNotIn("destination", saved)
        self.assertNotIn(str(self.work), json.dumps(saved))

    def test_existing_destinations_are_never_overwritten(self):
        for kind in ("file", "directory", "dangling_symlink"):
            with self.subTest(kind=kind):
                destination = self.work / kind
                if kind == "file":
                    destination.write_text("existing user data")
                elif kind == "directory":
                    destination.mkdir()
                    (destination / "user.txt").write_text("existing user data")
                else:
                    destination.symlink_to(self.work / "absent target")
                for action in (tools.install, tools.bundle):
                    with self.assertRaisesRegex(tools.ToolError, "already exists"):
                        action(destination)
                self.assertTrue(os.path.lexists(destination))
                if kind == "file":
                    self.assertEqual(destination.read_text(), "existing user data")
                elif kind == "directory":
                    self.assertEqual((destination / "user.txt").read_text(), "existing user data")
                else:
                    self.assertTrue(destination.is_symlink())
                    self.assertFalse((self.work / "absent target").exists())

    def test_parent_must_exist_and_source_cannot_be_destination(self):
        for destination in (self.work / "absent parent" / "skill",
                            self.source / "accidental install"):
            with self.subTest(destination=destination):
                with self.assertRaises(tools.ToolError):
                    tools.install(destination)
                self.assertFalse(destination.exists())

    def test_source_symlinks_are_rejected_before_writing(self):
        for kind in ("root", "file", "directory", "dangling"):
            with self.subTest(kind=kind):
                link = self.work / "source link"
                if kind == "root":
                    link.symlink_to(self.source, target_is_directory=True)
                    with mock.patch.object(tools, "SKILL_SOURCE", link):
                        with self.assertRaisesRegex(tools.ToolError, "Symlinks"):
                            tools.install(self.destination)
                    link.unlink()
                else:
                    link = self.source / "unwanted link"
                    target = {"file": self.source / "SKILL.md",
                              "directory": self.source / "scripts",
                              "dangling": self.work / "absent"}[kind]
                    link.symlink_to(target, target_is_directory=kind == "directory")
                    for action in (tools.install, tools.bundle):
                        with self.assertRaisesRegex(tools.ToolError, "Symlinks"):
                            action(self.destination)
                    link.unlink()
                self.assertFalse(self.destination.exists())

    def test_unexpected_source_content_cannot_enter_bundle(self):
        (self.source / "scratch.txt").write_text("private scratch")
        for action in (tools.install, tools.bundle):
            with self.assertRaisesRegex(tools.ToolError, "release allowlist"):
                action(self.destination)
        self.assertFalse(self.destination.exists())

    def test_failed_install_cleans_only_its_created_content(self):
        original_write = tools.write_new

        def fail_after_write(path, data, created):
            original_write(path, data, created)
            raise OSError("injected write failure")

        with mock.patch.object(tools, "write_new", side_effect=fail_after_write):
            with self.assertRaisesRegex(OSError, "injected write failure"):
                tools.install(self.destination)
        self.assertFalse(self.destination.exists())

    def test_failed_install_preserves_foreign_file(self):
        original_write = tools.write_new

        def foreign_file_then_fail(path, data, created):
            original_write(path, data, created)
            (self.destination / "user.txt").write_text("external data")
            raise OSError("injected failure")

        with mock.patch.object(tools, "write_new", side_effect=foreign_file_then_fail):
            with self.assertRaises(OSError):
                tools.install(self.destination)
        self.assertEqual([p.name for p in self.destination.iterdir()], ["user.txt"])
        self.assertEqual((self.destination / "user.txt").read_text(), "external data")

    def test_failed_install_preserves_replaced_file(self):
        original_write = tools.write_new

        def replace_file_then_fail(path, data, created):
            original_write(path, data, created)
            replacement = self.work / "replacement"
            replacement.write_text("external replacement")
            replacement.replace(path)
            raise OSError("injected failure")

        with mock.patch.object(tools, "write_new", side_effect=replace_file_then_fail):
            with self.assertRaises(OSError):
                tools.install(self.destination)
        self.assertEqual((self.destination / "LICENSE-APACHE").read_text(),
                         "external replacement")

    def test_verify_detects_changed_missing_extra_files_and_receipt(self):
        for kind in ("changed", "missing", "extra", "receipt", "missing receipt", "symlink"):
            with self.subTest(kind=kind):
                destination = self.work / kind
                tools.install(destination)
                target = destination / "SKILL.md"
                if kind == "changed":
                    target.write_text("changed instructions")
                elif kind == "missing":
                    target.unlink()
                elif kind == "extra":
                    (destination / "user.csv").write_text("id,value\n1,2\n")
                elif kind == "receipt":
                    (destination / tools.RECEIPT_NAME).write_text("{}")
                elif kind == "missing receipt":
                    (destination / tools.RECEIPT_NAME).unlink()
                else:
                    target.unlink()
                    target.symlink_to(self.source / "SKILL.md")
                with self.assertRaises(tools.ToolError):
                    tools.verify(destination)

    def test_zip_is_byte_reproducible_with_exact_payload_and_metadata(self):
        first = self.work / "first bundle.zip"
        second = self.work / "second bundle.zip"
        (self.work / "private user data.csv").write_text("never package me")
        tools.bundle(first)
        for name in EXPECTED_FILES:
            os.utime(self.source / name, (1700000000, 1700000000))
            (self.source / name).chmod(0o600)
        tools.bundle(second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        expected = {"plugin.json"} | {f"skills/r-statistical-analysis/{name}"
                                      for name in EXPECTED_FILES}
        with zipfile.ZipFile(first) as archive:
            self.assertEqual(archive.namelist(), sorted(expected))
            self.assertIsNone(archive.testzip())
            self.assertEqual(archive.read("plugin.json"), self.manifest.read_bytes())
            for entry in archive.infolist():
                self.assertEqual(entry.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertEqual(entry.create_system, 3)
                self.assertEqual(entry.external_attr >> 16, stat.S_IFREG | 0o644)
                self.assertEqual(entry.compress_type, zipfile.ZIP_STORED)
                self.assertEqual(entry.extra, b"")
                self.assertEqual(entry.comment, b"")
                if entry.filename != "plugin.json":
                    name = entry.filename.removeprefix("skills/r-statistical-analysis/")
                    self.assertEqual(archive.read(entry), (self.source / name).read_bytes())

    def test_bundle_rejects_symlink_manifest_and_removes_failed_archive(self):
        self.manifest.unlink()
        self.manifest.symlink_to(self.source / "SKILL.md")
        with self.assertRaisesRegex(tools.ToolError, "regular file"):
            tools.bundle(self.destination)
        self.manifest.unlink()
        self.manifest.write_text('{"name":"r-statistical-analysis"}\n')
        original_write = tools.write_new

        def fail_after_write(path, data, created):
            original_write(path, data, created)
            raise OSError("injected failure")

        with mock.patch.object(tools, "write_new", side_effect=fail_after_write):
            with self.assertRaises(OSError):
                tools.bundle(self.destination)
        self.assertFalse(self.destination.exists())


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(TOOL_PATH), *map(str, args)],
                              capture_output=True, text=True, timeout=10)

    def test_destination_is_mandatory(self):
        for command in ("install", "verify", "bundle"):
            with self.subTest(command=command):
                result = self.run_cli(command)
                self.assertEqual(result.returncode, 2)
                self.assertIn("destination", result.stderr)

    def test_cli_install_verify_and_existing_destination_error(self):
        with tempfile.TemporaryDirectory(prefix="assistant CLI ") as work:
            destination = Path(work) / "installed skill"
            self.assertEqual(self.run_cli("install", destination).returncode, 0)
            verified = self.run_cli("verify", destination)
            self.assertEqual(verified.returncode, 0, verified.stderr)
            self.assertTrue(json.loads(verified.stdout)["verified"])
            rejected = self.run_cli("install", destination)
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("Destination already exists", rejected.stderr)
            self.assertNotIn("Traceback", rejected.stderr)

    def test_missing_runtime_is_actionable_without_any_install(self):
        result = self.run_cli("doctor", "--rscript", "/absent/assistant-test/Rscript")
        self.assertEqual(result.returncode, 1)
        self.assertIn("--rscript PATH", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_doctor_rejects_non_package_arguments_before_execution(self):
        with mock.patch.object(tools.subprocess, "run") as run:
            with self.assertRaisesRegex(tools.ToolError, "package names"):
                tools.doctor("Rscript", ["stats; stop('injected')"])
            run.assert_not_called()

    def test_doctor_is_bounded_and_passes_arguments_without_shell(self):
        with mock.patch.object(tools.shutil, "which", return_value="/path with spaces/Rscript"):
            with mock.patch.object(tools.subprocess, "run", side_effect=
                                   subprocess.TimeoutExpired("Rscript", 30)) as run:
                with self.assertRaisesRegex(tools.ToolError, "exceeded 30 seconds"):
                    tools.doctor("Rscript", ["stats", "nlme"])
                args, kwargs = run.call_args
                self.assertEqual(args[0], ["/path with spaces/Rscript", "--vanilla",
                    str(tools.SKILL_SOURCE / "scripts/inspect-environment.R"), "stats", "nlme"])
                self.assertEqual(kwargs["timeout"], 30)
                self.assertNotIn("shell", kwargs)

    def test_doctor_reports_missing_packages_and_runtime_failure(self):
        for result in (subprocess.CompletedProcess([], 0, "unknown\tNA\tNA\tmissing\n", ""),
                       subprocess.CompletedProcess([], 7, "", "R startup failed\n")):
            with self.subTest(returncode=result.returncode):
                with mock.patch.object(tools.shutil, "which", return_value="Rscript"), \
                        mock.patch.object(tools.subprocess, "run", return_value=result), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(tools.ToolError):
                        tools.doctor("Rscript", ["stats"])

    @unittest.skipUnless(shutil.which("Rscript"), "[RUNTIME] Rscript is not installed")
    def test_runtime_recovery_with_explicit_existing_rscript(self):
        """[RUNTIME] Local/CI with R installed; inspect stats without installing."""
        result = self.run_cli("doctor", "--rscript", shutil.which("Rscript"),
                              "--package", "stats")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("R_version\t", result.stdout)
        self.assertRegex(result.stdout, r"stats\t[^\t]+\t[^\n]+\tavailable")


if __name__ == "__main__":
    unittest.main(verbosity=2)
