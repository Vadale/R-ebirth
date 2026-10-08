"""CI-only fixture binding controls; no product, model or reference execution."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("mirror", Path(__file__).with_name("check-fixture-mirror.py"))
MIRROR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MIRROR)


class FixtureMirror(unittest.TestCase):
    def test_frozen_package_bytes(self):
        self.assertEqual(MIRROR.check(ROOT), 14)

    def test_corruption_missing_and_extra_are_refused(self):
        for mutation in ("changed", "missing", "extra"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for path in ("tests/llm-golden/projection/goldens", "rebirth/tests/testthat/fixtures/projection"):
                    shutil.copytree(ROOT / path, root / path)
                dest = root / "rebirth/tests/testthat/fixtures/projection"
                if mutation == "changed":
                    (dest / "target.bin").write_bytes(b"corrupted")
                elif mutation == "missing":
                    (dest / "values.bin").unlink()
                else:
                    (dest / "unexpected.bin").write_bytes(b"extra")
                with self.assertRaises(ValueError):
                    MIRROR.check(root)

    def test_mutating_both_copies_still_fails_reference_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in ("tests/llm-golden/projection/goldens", "rebirth/tests/testthat/fixtures/projection"):
                shutil.copytree(ROOT / path, root / path)
                target = root / path / "target.bin"
                data = bytearray(target.read_bytes())
                data[-1] ^= 1
                target.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "reference encoding digest"):
                MIRROR.check(root)


if __name__ == "__main__":
    unittest.main()
