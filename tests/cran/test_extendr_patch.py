"""Source-only patch corruption controls; R CI source-bundle stage, zero models."""
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import extendr_patch as subject


class ExtendrPatchTests(unittest.TestCase):
    def test_owned_source_corruption_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            owned = Path(tmp) / "extendr"
            shutil.copytree(subject.OWNED, owned)
            source = owned / "extendr-ffi-0.9.0/src/backports.rs"
            source.write_bytes(source.read_bytes() + b"\n// corrupt\n")
            with patch.object(subject, "OWNED", owned), self.assertRaises(AssertionError):
                subject.verify()

    def test_developer_route_corruption_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / ".cargo").mkdir()
            (root / ".cargo/config.toml").write_text("paths = []\n")
            with patch.object(subject, "ROOT", root), self.assertRaises(AssertionError):
                subject.verify()

    def test_offline_source_corruption_refused(self):
        with tarfile.open(ROOT / "rebirth/src/rust/vendor.tar.xz") as archive:
            original = archive.extractfile
            def altered(name):
                value = original(name)
                if name.endswith("extendr-ffi-0.9.0/src/backports.rs"):
                    return io.BytesIO(value.read() + b"\n// corrupt\n")
                return value
            with patch.object(archive, "extractfile", altered), self.assertRaises(AssertionError):
                subject.check_bundle(archive)


if __name__ == "__main__":
    unittest.main()
