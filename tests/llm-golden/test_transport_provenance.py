"""D056 corruption/trust controls; no reference computation or model execution.

Runs in the existing harness B CI job with the approved tooling environment.
"""
import csv
import hashlib
import importlib.util
import json
import shutil
import ssl
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import transport_provenance as transport

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/projection"))
import compare_reference as projection
spec = importlib.util.spec_from_file_location("directions_check", ROOT / "tests/directions/check_reference.py")
directions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(directions)


def stamp(directory):
    with (directory / "manifest.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["file", "bytes", "sha256"])
        for path in sorted(directory.iterdir()):
            if path.name != "manifest.csv":
                writer.writerow([path.name, path.stat().st_size, hashlib.sha256(path.read_bytes()).hexdigest()])


class TransportControls(unittest.TestCase):
    def test_only_approved_transition(self):
        transport.check_transition(transport.CURRENT_SHA, transport.HISTORICAL_SHA)
        for actual, expected in [
            (transport.HISTORICAL_SHA, transport.HISTORICAL_SHA),
            (transport.CURRENT_SHA, transport.CURRENT_SHA),
            ("0" * 64, transport.HISTORICAL_SHA),
            (transport.CURRENT_SHA, "0" * 64),
        ]:
            with self.subTest(actual=actual, expected=expected), self.assertRaises(AssertionError):
                transport.check_transition(actual, expected)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "requirements.txt"
            path.write_bytes(transport.REQUIREMENTS.read_bytes() + b"# unexpected edit\n")
            with patch.object(transport, "REQUIREMENTS", path), self.assertRaises(AssertionError):
                transport.check_transition(transport.CURRENT_SHA, transport.HISTORICAL_SHA)

    def test_installed_certifi_version_and_trust(self):
        import certifi
        transport.check_runtime()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.load_verify_locations(cafile=certifi.where())
        roots = {hashlib.sha256(der).hexdigest() for der in ctx.get_ca_certs(binary_form=True)}
        # SHA256 of emSign ECC Root CA - G3 named by GHSA-6q48-6c7w-9gw2.
        self.assertNotIn("86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b", roots)
        # The three unaffected emSign roots restored by upstream 2026.10.19.
        self.assertTrue({
            "40f6af0346a99aa1cd1d555a4e9cce62c7f9634603ee406615833dc8c8d00367",
            "125609aa301da0a249b97a8239cb6a34216f44dcac9f3954b14292f2e8c8608f",
            "bc4d809b15189d78db3e1d8cf4f9726a795da1643ca5f1358e1ddb0edc0d7eb3",
        } <= roots)
        with patch.object(transport.importlib.metadata, "version", return_value="2026.6.17"), self.assertRaises(AssertionError):
            transport.check_runtime()

    def test_old_urllib3_is_refused(self):
        version = transport.importlib.metadata.version
        with patch.object(transport.importlib.metadata, "version", side_effect=lambda name:
                          "2.7.0" if name == "urllib3" else version(name)):
            with self.assertRaisesRegex(AssertionError, "urllib3"):
                transport.check_runtime()

    def test_actual_frozen_artifacts_and_corruption_refusals(self):
        for kind, comparator, changed in (
            ("directions", directions.compare, ("provenance.csv",)),
            ("projection", projection.compare_reference, ("sources.csv", "manifest.json")),
        ):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                expected = ROOT / "tests/llm-golden" / kind / "goldens"
                before = {p.name: p.read_bytes() for p in expected.iterdir()}
                actual = Path(tmp) / "actual"
                shutil.copytree(expected, actual)
                for name in changed:
                    path = actual / name
                    self.assertIn(transport.HISTORICAL_SHA.encode(), path.read_bytes())
                    path.write_bytes(path.read_bytes().replace(transport.HISTORICAL_SHA.encode(), transport.CURRENT_SHA.encode()))
                stamp(actual)
                comparator(actual, expected)
                good = {p.name: p.read_bytes() for p in actual.iterdir()}
                # Valid file hashes must not hide unknown provenance or changed values.
                bad = [(changed[0], transport.CURRENT_SHA, "0" * 64)]
                if kind == "directions":
                    bad.append(("provenance.csv", "2.5.1", "9.9.9"))
                else:
                    bad.append(("manifest.json", '"producer_version":', '"unexpected_version":'))
                    bad.append(("sources.csv", "reference_directions.py", "another_producer.py"))
                for name, old, new in bad:
                    with self.subTest(file=name, old=old):
                        for item, raw in good.items():
                            (actual / item).write_bytes(raw)
                        path = actual / name
                        self.assertIn(old, path.read_text())
                        path.write_text(path.read_text().replace(old, new))
                        stamp(actual)
                        with self.assertRaises(AssertionError):
                            comparator(actual, expected)
                for item, raw in good.items():
                    (actual / item).write_bytes(raw)
                csv_name = changed[0]
                (actual / csv_name).write_bytes(good[csv_name].replace(b"\r\n", b"\n") if b"\r\n" in good[csv_name] else good[csv_name].replace(b"\n", b"\r\n"))
                stamp(actual)
                with self.assertRaises(AssertionError):
                    comparator(actual, expected)
                for item, raw in good.items():
                    (actual / item).write_bytes(raw)
                name = next(n for n in good if n.endswith(".bin"))
                (actual / name).write_bytes(good[name] + b"corrupt")
                stamp(actual)
                with self.assertRaises(AssertionError):
                    comparator(actual, expected)
                self.assertEqual(before, {p.name: p.read_bytes() for p in expected.iterdir()})


if __name__ == "__main__":
    unittest.main()
