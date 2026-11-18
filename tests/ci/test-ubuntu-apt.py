"""Exercise the actual CI source transformation without root, network or APT."""

from pathlib import Path
import subprocess
import importlib.util
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

    def test_stock_azure_and_cloud_init_uris(self):
        expected = SOURCE.replace(MIRROR, ARCHIVE)
        for uri in (b"http://azure.archive.ubuntu.com/ubuntu/",
                    b"http://archive.ubuntu.com/ubuntu",
                    b"https://archive.ubuntu.com/ubuntu",
                    b"https://azure.archive.ubuntu.com/ubuntu"):
            with self.subTest(uri=uri):
                source = SOURCE.replace(MIRROR, uri)
                self.run_case(source, expected)

    def test_stock_security_uri_upgrades_to_https(self):
        security = b"https://security.ubuntu.com/ubuntu/"
        source = SOURCE.replace(MIRROR, b"http://archive.ubuntu.com/ubuntu/", 1)
        source = source.replace(MIRROR, b"http://security.ubuntu.com/ubuntu")
        expected = SOURCE.replace(MIRROR, ARCHIVE, 1).replace(MIRROR, security)
        self.run_case(source, expected)

    def test_unexpected_layouts_refused_without_writes(self):
        for source in (None, b"", SOURCE.replace(b"URIs:", b"# URIs:"),
                       SOURCE.replace(MIRROR, b"https://archive.ubuntu.com/other/"),
                       SOURCE.replace(MIRROR, b"https://example.org/ubuntu/", 1),
                       SOURCE.replace(MIRROR, MIRROR + b" " + ARCHIVE),
                       SOURCE.replace(MIRROR, b"https://security.ubuntu.com/ubuntu/")):
            with self.subTest(source=source):
                self.run_case(source)



class UbuntuNobleRepairTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("ubuntu_sources", SCRIPT)
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.path = self.root / "ubuntu.sources"
        self.sibling = self.root / "microsoft-prod.list"
        self.sibling.write_bytes(b"deb https://packages.microsoft.com/ubuntu/24.04/prod noble main\n")
        self.keyring = self.root / "ubuntu-archive-keyring.gpg"
        self.keyring.write_bytes(b"keyring fixture")
        self.source = SOURCE.replace(
            b"/usr/share/keyrings/ubuntu-archive-keyring.gpg",
            str(self.keyring).encode(),
        )
        self.release = {"ID": "ubuntu", "VERSION_ID": "24.04", "VERSION_CODENAME": "noble"}

    def repair(self, source, *, release=None, architecture="amd64", keyring=None):
        if source is not None:
            self.path.write_bytes(source)
        self.helper.restore_noble(
            self.path, self.release if release is None else release,
            architecture, self.keyring if keyring is None else keyring,
        )
        self.assertEqual(
            self.sibling.read_bytes(),
            b"deb https://packages.microsoft.com/ubuntu/24.04/prod noble main\n",
        )
        result = self.path.read_bytes()
        self.assertIn(b"URIs: https://archive.ubuntu.com/ubuntu/", result)
        self.assertIn(b"URIs: https://security.ubuntu.com/ubuntu/", result)
        self.assertIn(b"Suites: noble noble-updates noble-backports", result)
        self.assertIn(b"Suites: noble-security", result)
        self.assertEqual(result.count(b"Components: main restricted universe multiverse"), 2)
        self.assertEqual(result.count(b"Signed-By: " + str(self.keyring).encode()), 2)
        return result

    def test_missing_and_empty_ubuntu_sources_are_restored(self):
        for source in (None, b"", b"  \n# no active Ubuntu indices\n"):
            with self.subTest(source=source):
                self.path.unlink(missing_ok=True)
                self.repair(source)

    def test_disabled_and_incomplete_official_sources_are_restored(self):
        for source in (
            self.source.replace(b"Types: deb", b"Enabled: no\nTypes: deb"),
            self.source.replace(b"main restricted universe multiverse", b"main"),
        ):
            with self.subTest(source=source):
                self.repair(source)

    def test_repaired_sources_are_idempotent(self):
        result = self.repair(self.source)
        self.assertEqual(self.repair(result), result)

    def test_invalid_origin_signing_or_trust_is_refused_without_writes(self):
        foreign_sources = (
            self.source.replace(MIRROR, b"https://example.org/ubuntu/", 1),
            self.source.replace(str(self.keyring).encode(), b"/tmp/foreign.gpg", 1),
            self.source + b"\nTrusted: yes\n",
            self.source.replace(b"Types: deb", b"Allow-Insecure: yes\nTypes: deb", 1),
            self.source.replace(b"Suites: noble-security", b"Suites: jammy-security"),
            self.source.replace(b"URIs: " + MIRROR, b"URIs: " + MIRROR + b"\nURIs: " + MIRROR, 1),
        )
        for source in foreign_sources:
            with self.subTest(source=source):
                self.path.write_bytes(source)
                with self.assertRaises(ValueError):
                    self.helper.restore_noble(self.path, self.release, "amd64", self.keyring)
                self.assertEqual(self.path.read_bytes(), source)

    def test_wrong_host_or_missing_keyring_is_refused_before_writes(self):
        for release, architecture, keyring in (
            ({"ID": "debian", "VERSION_ID": "24.04", "VERSION_CODENAME": "noble"}, "amd64", self.keyring),
            (dict(self.release, VERSION_CODENAME="jammy"), "amd64", self.keyring),
            (dict(self.release, VERSION_ID="26.04"), "amd64", self.keyring),
            (self.release, "arm64", self.keyring),
            (self.release, "amd64", self.root / "missing.gpg"),
        ):
            with self.subTest(release=release, architecture=architecture, keyring=keyring):
                self.path.unlink(missing_ok=True)
                with self.assertRaises(ValueError):
                    self.helper.restore_noble(self.path, release, architecture, keyring)
                self.assertFalse(self.path.exists())

    def test_symbolic_link_is_refused_without_target_changes(self):
        target = self.root / "unrelated.sources"
        target.write_bytes(self.source)
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            self.helper.restore_noble(self.path, self.release, "amd64", self.keyring)
        self.assertEqual(target.read_bytes(), self.source)


if __name__ == "__main__":
    unittest.main()
