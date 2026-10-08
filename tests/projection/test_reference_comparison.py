"""Model-free corruption controls for the approved field-aware comparison."""
import csv
import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import compare_reference as comparator


def stamp(directory):
    with (directory / "manifest.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["file", "bytes", "sha256"])
        for path in sorted(directory.iterdir()):
            if path.name != "manifest.csv":
                raw = path.read_bytes()
                writer.writerow([path.name, len(raw), hashlib.sha256(raw).hexdigest()])


class ComparisonControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.expected = Path(self.tmp.name) / "expected"
        self.expected.mkdir()
        self.write(self.expected, "forward-logits.csv", "case,source_pos,token_id_native,logit\na,1,0,2.0\n")
        self.write(self.expected, "controls.csv", "control,outcome,detail\nscalar,passed,2.0\n")
        self.write(self.expected, "forward-row-witnesses.csv", "case,before_norm,after_norm,dot,write\na,2.0,1.0,3.0,1\n")
        self.write(self.expected, "manifest.json", json.dumps({"cases": {"a": {"final_logits": [2.0], "missing_max_logit_delta": 2.0, "coef": 1.0}}, "count": 1}))
        (self.expected / "encoding.bin").write_bytes(b"canonical\x00\x80")
        stamp(self.expected)
        self.actual = Path(self.tmp.name) / "actual"
        shutil.copytree(self.expected, self.actual)
        self.pin = patch.object(comparator, "FROZEN_MANIFEST_SHA", hashlib.sha256((self.expected / "manifest.csv").read_bytes()).hexdigest())
        self.pin.start()
        self.addCleanup(self.pin.stop)

    @staticmethod
    def write(directory, name, text):
        (directory / name).write_text(text)

    def check(self):
        return comparator.compare_reference(self.actual, self.expected)

    def test_exact_and_f64_observations_pass(self):
        self.assertEqual(self.check()["files"], 6)
        for name in ["forward-logits.csv", "controls.csv", "forward-row-witnesses.csv", "manifest.json"]:
            path = self.actual / name
            path.write_text(path.read_text().replace("2.0", "2.000000000001"))
        stamp(self.actual)
        self.assertEqual(self.check()["f64_abs"], 1e-12)

    def test_numeric_and_discrete_corruptions_refuse(self):
        mutations = [
            ("forward-logits.csv", "2.0", "2.00000001"),
            ("forward-logits.csv", "2.0", "nan"),
            ("forward-logits.csv", "a,1,0", "a,1,1"),
            ("controls.csv", "passed", "failed"),
            ("controls.csv", "scalar", "another"),
            ("controls.csv", "2.0", "false"),
            ("forward-row-witnesses.csv", "3.0,1", "3.000000000001,1"),
            ("forward-row-witnesses.csv", "3.0,1", "3.0,0"),
            ("manifest.json", '"coef": 1.0', '"coef": 1.000000000001'),
            ("manifest.json", '"count": 1', '"count": 2'),
            ("manifest.json", "[2.0]", "[2.0, 2.0]"),
            ("manifest.json", "[2.0]", '["2.0"]'),
        ]
        for name, old, new in mutations:
            with self.subTest(name=name, replacement=new):
                shutil.rmtree(self.actual)
                shutil.copytree(self.expected, self.actual)
                path = self.actual / name
                self.assertIn(old, path.read_text())
                path.write_text(path.read_text().replace(old, new))
                stamp(self.actual)  # Valid hashes must not conceal wrong semantics.
                with self.assertRaises((AssertionError, ValueError)):
                    self.check()

    def test_encoding_manifest_and_inventory_remain_exact(self):
        path = self.actual / "encoding.bin"
        path.write_bytes(b"different\x00\x80")
        with self.assertRaises(AssertionError):
            self.check()
        stamp(self.actual)
        with self.assertRaises(AssertionError):
            self.check()
        shutil.rmtree(self.actual)
        shutil.copytree(self.expected, self.actual)
        (self.actual / "extra").write_text("new")
        stamp(self.actual)
        with self.assertRaises(AssertionError):
            self.check()
        (self.expected / "encoding.bin").write_bytes(b"changed frozen input")
        stamp(self.expected)
        with self.assertRaises(AssertionError):
            self.check()

    def test_f64_bound_zero_sign_and_shape_are_checked(self):
        comparator.f64_equal(2.0 + 1e-12, 2.0)
        for a, e in [(2.0 + 4e-12, 2.0), (-0.0, 0.0), (float("inf"), 1.0), (True, 1.0)]:
            with self.subTest(a=a), self.assertRaises(AssertionError):
                comparator.f64_equal(a, e)
        with self.assertRaises(AssertionError):
            comparator.numeric_detail("[1.0]", "[1.0, 2.0]")


if __name__ == "__main__":
    unittest.main()
