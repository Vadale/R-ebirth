"""Exercise the actual CI source transformation without root, network or APT."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("configure-ubuntu-apt.py")
MIRROR = b"mirror+file:/etc/apt/apt-mirrors.txt"
ARCHIVE = b"https://archive.ubuntu.com/ubuntu/"
SOURCE = (
    b"# Hosted Ubuntu sources\nTypes: deb\nURIs: " + MIRROR + b"\n"
    b"Suites: noble noble-updates noble-backports\nComponents: main restricted universe multiverse\n"
    b"Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n\n"
    b"Types: deb\nURIs: " + MIRROR + b"\nSuites: noble-security\n"
    b"Components: main restricted universe multiverse\n"
    b"Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"
)


class UbuntuArchiveTest(unittest.TestCase):
    def run_case(self, content, expected=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ubuntu.sources"
            if content is not None:
                path.write_bytes(content)
            result = subprocess.run([sys.executable, str(SCRIPT), str(path)],
                                    capture_output=True, text=True)
            if expected is None:
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(path.read_bytes() if path.exists() else None, content)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(path.read_bytes(), expected)

    def test_exact_transformation(self):
        self.run_case(SOURCE, SOURCE.replace(MIRROR, ARCHIVE))

    def test_crlf_preserved(self):
        source = SOURCE.replace(b"\n", b"\r\n")
        self.run_case(source, source.replace(MIRROR, ARCHIVE))

    def test_already_direct_is_unchanged(self):
        source = SOURCE.replace(MIRROR, ARCHIVE)
        self.run_case(source, source)

    def test_security_archive_is_preserved(self):
        source = SOURCE.replace(b"URIs: " + MIRROR + b"\nSuites: noble-security",
                                b"URIs: https://security.ubuntu.com/ubuntu/\nSuites: noble-security")
        self.run_case(source, source.replace(MIRROR, ARCHIVE))

    def test_unexpected_layouts_refused_without_writes(self):
        for source in (None, b"", SOURCE.replace(b"URIs:", b"# URIs:"),
                       SOURCE.replace(MIRROR, b"http://archive.ubuntu.com/ubuntu/"),
                       SOURCE.replace(MIRROR, b"https://example.org/ubuntu/", 1),
                       SOURCE.replace(MIRROR, MIRROR + b" " + ARCHIVE),
                       SOURCE.replace(MIRROR, b"https://security.ubuntu.com/ubuntu/")):
            with self.subTest(source=source):
                self.run_case(source)


if __name__ == "__main__":
    unittest.main()
