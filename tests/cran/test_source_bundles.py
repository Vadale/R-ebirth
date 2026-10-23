"""Run with python3 tests/cran/test_source_bundles.py; no build/model/network."""
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
SPEC = importlib.util.spec_from_file_location("prepare_sources", ROOT / "tools/prepare-cran-sources.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SourceBundleTests(unittest.TestCase):
    def test_source_bytes_modes_and_reproducibility(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "LICENSE").write_text("Original license\n")
            (source / "configure").write_text("#!/bin/sh\nexit 0\n")
            (source / "configure").chmod(0o755)
            files = [source / "configure", source / "LICENSE"]
            first, second = root / "first.tar.xz", root / "second.tar.xz"
            MODULE.write_archive(first, source, "engine", files)
            (source / "LICENSE").touch()
            MODULE.write_archive(second, source, "engine", list(reversed(files)))
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first) as archive:
                self.assertEqual(archive.extractfile("engine/LICENSE").read(), b"Original license\n")
                self.assertEqual(archive.getmember("engine/configure").mode, 0o755)
                self.assertTrue(all(x.uid == 0 and x.mtime == 0 for x in archive))

    def test_symlink_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "outside").write_text("must not be bundled")
            (root / "link").symlink_to(root / "outside")
            with self.assertRaises(ValueError):
                MODULE.write_archive(root / "bad.tar.xz", root, "engine", [root / "link"])

    def test_compiled_artifact_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "hidden-source"
            binary.write_bytes(b"\x00asm\x01\x00\x00\x00")
            with self.assertRaises(ValueError):
                MODULE.write_archive(root / "bad.tar.xz", root, "engine", [binary])

    def test_cargo_checksum_corruption_refused(self):
        import hashlib
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Cargo.toml").write_text('[package]\nname="sample"\nversion="1.0.0"\n')
            content = b"source"
            (root / "lib.rs").write_bytes(content)
            checksums = {"package": "pinned", "files": {"lib.rs": hashlib.sha256(content).hexdigest()}}
            (root / ".cargo-checksum.json").write_text(json.dumps(checksums))
            MODULE.verify_crate(root, "pinned")
            (root / "lib.rs").write_bytes(b"changed")
            with self.assertRaises(ValueError):
                MODULE.verify_crate(root, "pinned")


if __name__ == "__main__":
    unittest.main()
