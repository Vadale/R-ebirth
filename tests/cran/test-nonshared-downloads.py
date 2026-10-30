"""Exercise the actual pinned downloader without network, R builds or models."""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "nonshared", Path(__file__).with_name("nonshared-r.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PAYLOAD = b"fixed archive bytes\x00\xff"
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()


class DownloadTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.out = Path(self.directory.name)
        self.calls = []
        self.attempts = []

    def fetch(self, responses, name="nanoarrow_0.9.0.tar.gz"):
        def request(command, **kwargs):
            self.calls.append(command[-1])
            self.assertLessEqual(len(self.calls), 4)
            self.assertEqual(command[:2], ["curl", "--disable"])
            for option in ("--proto", "--proto-redir"):
                self.assertEqual(command[command.index(option) + 1], "=https")
            self.assertEqual(command[command.index("--retry") + 1], "0")
            self.assertLessEqual(int(command[command.index("--max-time") + 1]), 45)
            self.assertLessEqual(kwargs["timeout"], 50)
            target = Path(command[command.index("--output") + 1])
            self.assertFalse(target.exists(), "Previous partial response was not removed")
            answer = responses.pop(0)
            if isinstance(answer, Exception):
                raise answer
            code, status, body = answer
            target.write_bytes(body)
            return subprocess.CompletedProcess(command, code, status, "fixture diagnostic")

        with patch.object(MODULE.subprocess, "run", side_effect=request):
            MODULE.download_input(name, "https://cran.r-project.org/src/contrib/",
                                  DIGEST, self.out, self.attempts)

    def assert_clean_failure(self, count):
        self.assertEqual(len(self.calls), count)
        self.assertFalse(list(self.out.glob("*.tar.gz")))
        self.assertFalse(list(self.out.glob("*.part")))
        records = json.loads((self.out / "download-attempts.json").read_text())
        self.assertEqual(len(records), count)

    def test_verified_first_response(self):
        self.fetch([(0, "200", PAYLOAD)])
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((self.out / "nanoarrow_0.9.0.tar.gz").read_bytes(), PAYLOAD)
        self.assertEqual(self.attempts[0]["outcome"], "verified")

    def test_timeout_uses_other_host(self):
        self.fetch([(28, "000", b"partial"), (0, "200", PAYLOAD)])
        self.assertEqual(self.calls, [
            "https://cloud.r-project.org/src/contrib/nanoarrow_0.9.0.tar.gz",
            "https://cran.r-project.org/src/contrib/nanoarrow_0.9.0.tar.gz"])

    def test_transport_failures_are_bounded(self):
        with self.assertRaisesRegex(RuntimeError, "Both CRAN endpoints failed"):
            self.fetch([(28, "000", b"partial"), (7, "000", b"")])
        self.assert_clean_failure(2)

    def test_partial_transfer_is_discarded_before_mirror(self):
        self.fetch([(18, "200", b"partial"), (0, "200", PAYLOAD)])
        self.assertEqual((self.out / "nanoarrow_0.9.0.tar.gz").read_bytes(), PAYLOAD)

    def test_http_server_error_uses_other_host_not_archive(self):
        self.fetch([(22, "503", b"service error"), (0, "200", PAYLOAD)])
        self.assertEqual(len(self.calls), 2)
        self.assertNotIn("Archive", self.calls[1])

    def test_404_uses_archive_on_same_host(self):
        self.fetch([(22, "404", b""), (0, "200", PAYLOAD)])
        self.assertEqual(self.calls[1],
                         "https://cloud.r-project.org/src/contrib/Archive/nanoarrow/nanoarrow_0.9.0.tar.gz")

    def test_mirror_archive_can_supply_same_pinned_bytes(self):
        self.fetch([(22, "404", b"")] * 3 + [(0, "200", PAYLOAD)])
        self.assertEqual(len(self.calls), 4)
        self.assertEqual(self.calls[-1],
                         "https://cran.r-project.org/src/contrib/Archive/nanoarrow/nanoarrow_0.9.0.tar.gz")

    def test_all_missing_archives_stop_after_four_requests(self):
        with self.assertRaisesRegex(RuntimeError, "Both CRAN endpoints failed"):
            self.fetch([(22, "404", b"")] * 4)
        self.assert_clean_failure(4)

    def test_r_source_does_not_try_package_archive(self):
        with self.assertRaisesRegex(RuntimeError, "Both CRAN endpoints failed"):
            self.fetch([(22, "404", b"")] * 2, name="R-4.6.1.tar.gz")
        self.assert_clean_failure(2)
        self.assertFalse(any("Archive" in url for url in self.calls))

    def test_corrupt_success_is_refused_without_mirror(self):
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.fetch([(0, "200", b"corrupt")])
        self.assert_clean_failure(1)
        self.assertEqual(self.attempts[0]["outcome"], "hash_mismatch")

    def test_certificate_failure_is_not_bypassed(self):
        with self.assertRaisesRegex(RuntimeError, "Non-recoverable"):
            self.fetch([(60, "000", b"")])
        self.assert_clean_failure(1)

    def test_forbidden_is_not_treated_as_transient(self):
        with self.assertRaisesRegex(RuntimeError, "Non-recoverable"):
            self.fetch([(22, "403", b"forbidden")])
        self.assert_clean_failure(1)

    def test_process_deadline_is_bounded_and_recorded(self):
        self.fetch([subprocess.TimeoutExpired("curl", 50), (0, "200", PAYLOAD)])
        self.assertEqual(self.attempts[0]["returncode"], 28)
        self.assertIn("deadline", self.attempts[0]["diagnostic"])

    def test_existing_input_is_preserved(self):
        target = self.out / "nanoarrow_0.9.0.tar.gz"
        target.write_bytes(b"original")
        with self.assertRaises(FileExistsError):
            self.fetch([])
        self.assertEqual(target.read_bytes(), b"original")
        self.assertEqual(self.calls, [])

    def test_unexpected_origin_refused_before_network(self):
        with patch.object(MODULE.subprocess, "run") as runner:
            for base in ("/src/contrib/", "http://example.org/", "https://cran.r-project.org.evil/src/contrib/",
                         "https://cran.r-project.org/unexpected/"):
                with self.subTest(base=base), self.assertRaises(ValueError):
                    MODULE.download_input("input.tar.gz", base, DIGEST, self.out, self.attempts)
            runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
