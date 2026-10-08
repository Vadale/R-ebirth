"""Model-free controls for failure retention; never execute the reference producer."""
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
spec = importlib.util.spec_from_file_location('retained', Path(__file__).with_name('check_reference_retained.py'))
retained = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retained)


class RetentionControls(unittest.TestCase):
    def test_failure_stays_failed_and_retains_exact_bytes(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); goldens=root/'frozen'; goldens.mkdir()
            (goldens/'manifest.json').write_bytes(b'expected\n')
            producer=root/'reference.py'; producer.write_text('# synthetic collector input\n')
            output=root/'out'; actual=b'actual\x00bytes\n'
            def fake_run(path):
                self.assertEqual(Path(path),producer)
                def generate(tmp):
                    (tmp/'manifest.json').write_bytes(actual)
                    raise AssertionError('synthetic producer refusal')
                return {'generate':generate}
            fake_numpy=types.SimpleNamespace(show_config=lambda:print('synthetic config'),show_runtime=lambda:print('synthetic runtime'))
            with patch.object(retained,'PRODUCER',producer), patch.object(retained,'PRODUCER_SHA',retained.sha(producer)), patch.object(retained,'GOLDENS',goldens), patch.object(retained.runpy,'run_path',side_effect=fake_run) as runner, patch.dict(sys.modules,{'numpy':fake_numpy}), patch.object(sys,'argv',['collector','--output',str(output)]), contextlib.redirect_stderr(io.StringIO()):
                original=tempfile.TemporaryDirectory
                with self.assertRaisesRegex(AssertionError,'synthetic producer refusal'):
                    retained.main()
                self.assertIs(tempfile.TemporaryDirectory,original)
                self.assertEqual(runner.call_count,1)
            self.assertEqual((output/'failed-generated/manifest.json').read_bytes(),actual)
            self.assertEqual((goldens/'manifest.json').read_bytes(),b'expected\n')
            report=json.loads((output/'difference-report.json').read_text())
            self.assertEqual(report['status'],'failed')
            self.assertEqual(len(report['differences']),1)

    def test_inventory_reports_missing_files_and_exact_equality(self):
        with tempfile.TemporaryDirectory() as root:
            a=Path(root)/'a';e=Path(root)/'e';a.mkdir();e.mkdir()
            (a/'same').write_bytes(b'unchanged');(e/'same').write_bytes(b'unchanged')
            self.assertEqual(retained.compare_files(a,e),[])
            (a/'same').write_bytes(b'changed')
            (e/'missing').write_text('expected')
            diffs=retained.compare_files(a,e)
            self.assertEqual(len(diffs),2)
            self.assertTrue(diffs[0]['missing_actual'])
            self.assertNotEqual(diffs[1]['actual_sha256'],diffs[1]['expected_sha256'])


if __name__=='__main__':
    unittest.main()
