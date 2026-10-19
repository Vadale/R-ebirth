"""Focused exact-text and provenance controls; no builds, downloads or models."""
import importlib.util
import json
from pathlib import Path
import tempfile
import shutil
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('notices', ROOT / 'tools/cran-notices.py')
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class Notices(unittest.TestCase):
    def test_installed_text_and_all_locked_crates(self):
        data, rows = notices.render()
        self.assertEqual(len(rows), 81)
        self.assertEqual(data, (ROOT / 'rebirth/inst/RUST-NOTICES').read_bytes())
        self.assertTrue(all(row['notices'] for row in rows))
        for source in notices.SUPPLEMENTS.glob('*-LICENSE'):
            self.assertIn(source.read_bytes(), data)

    def test_rejects_corrupt_supplement(self):
        with tempfile.TemporaryDirectory() as temp:
            copy = Path(temp) / 'supplements'
            shutil.copytree(notices.SUPPLEMENTS, copy)
            next(copy.glob('*-LICENSE')).write_text('incorrect replacement')
            with patch.object(notices, 'SUPPLEMENTS', copy), self.assertRaises(AssertionError):
                notices.render()

    def test_rejects_unbound_revision(self):
        with tempfile.TemporaryDirectory() as temp:
            copy = Path(temp) / 'supplements'
            shutil.copytree(notices.SUPPLEMENTS, copy)
            index = copy / 'sources.json'
            data = json.loads(index.read_text())
            for entry in data.values():
                entry['url'] = entry['url'].replace('/LICENSE', '/other-revision/LICENSE').replace('564d0de80ba6cff3f8c04e3b3e336d1346590ec6', 'main')
            index.write_text(json.dumps(data))
            with patch.object(notices, 'SUPPLEMENTS', copy), self.assertRaises(AssertionError):
                notices.render()


if __name__ == '__main__':
    unittest.main()
