#!/usr/bin/env python3
"""New model-free command regression for the retained Valgrind path failure."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("projection_memory", Path(__file__).with_name("instrumented.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PathControls(unittest.TestCase):
    def test_retained_worker_name_is_literal(self):
        label = module.BASE.test_log_label(module.CASES["rebirth_llm"]["id"])
        args = module.ProjectionRun.valgrind_args(SimpleNamespace(evidence=Path("/out")), Path("/binary"), label, ["--exact", "test"])
        self.assertIn("--xml-file=/out/test-async_job%%3A%%3Atests%%3A%%3Aprojection_static_live_restore_cancel_and_poison.xml", args)
        self.assertEqual(args[-3:], [Path("/binary"), "--exact", "test"])
        self.assertIn("--error-exitcode=1", args)
        self.assertIn("--errors-for-leak-kinds=definite,indirect", args)

    def test_directory_and_pid_environment_sequences_are_literal(self):
        args = module.ProjectionRun.valgrind_args(SimpleNamespace(evidence=Path("/out%q{HOME}")), Path("/binary"), "safe-%3A-%p", [])
        self.assertIn("--xml-file=/out%%q{HOME}/safe-%%3A-%%p.xml", args)

    def test_plain_path_stays_exact(self):
        args = module.ProjectionRun.valgrind_args(SimpleNamespace(evidence=Path("/out")), Path("/binary"), "plain", [])
        self.assertIn("--xml-file=/out/plain.xml", args)


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PathControls))
    if not result.wasSuccessful() or result.testsRun != 3:
        raise SystemExit(1)
    print('F6E_INSTRUMENTED_PATH_CONTROLS {"status":"passed","cases":3,"models":0}')
