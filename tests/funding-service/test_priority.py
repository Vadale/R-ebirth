#!/usr/bin/env python3
"""Linux native preflight: real offline boundary and observer priority, no model."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from offline import ensure_offline


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', required=True)
    args = parser.parse_args()
    assert sys.platform == 'linux' and os.getuid() == os.geteuid() != 0
    # Re-exec through the actual sudo/unshare/setpriv path before reading the
    # requested priority. Losing the environment or inherited limit must fail.
    boundary = ensure_offline()
    directory = Path(args.work_dir).resolve()
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    report = dict(status='running', scope='Offline observer preflight; no G1-G8 acceptance.', boundary=boundary)
    try:
        assert os.environ.get('RELM_SAMPLER_NICE') == '-10', 'Offline boundary lost the priority request'
        assert os.getuid() == os.geteuid() != 0
        assert os.getpriority(os.PRIO_PROCESS, 0) == 0, 'Harness must remain at normal priority'
        launcher = str(Path(__file__).with_name('sampler_launcher.py'))
        payload = 'import json,os; print(json.dumps([os.getpid(),os.getuid(),os.geteuid(),os.getpriority(os.PRIO_PROCESS,0)]))'
        result = subprocess.run([sys.executable, launcher, str(directory / 'sampler-process.json'),
                                 sys.executable, '-c', payload], capture_output=True, text=True, timeout=10, check=True)
        metadata = json.loads((directory / 'sampler-process.json').read_text())
        assert json.loads(result.stdout) == [metadata['pid'], os.getuid(), os.geteuid(), -10]
        assert metadata['actual_nice'] == metadata['requested_nice'] == -10
        assert os.getpriority(os.PRIO_PROCESS, 0) == 0
        report['sampler'] = metadata
        # A child that loses permission must refuse to exec the observer.
        deny = ('import resource,runpy,sys; resource.setrlimit(resource.RLIMIT_NICE,(0,0)); '
                'sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name="__main__")')
        refused = subprocess.run([sys.executable, '-c', deny, launcher, str(directory / 'must-not-exist.json'),
                                  sys.executable, '-c', 'print("MUST_NOT_EXECUTE")'],
                                 capture_output=True, text=True, timeout=10)
        assert refused.returncode != 0 and 'PermissionError' in refused.stderr
        assert 'MUST_NOT_EXECUTE' not in refused.stdout and not (directory / 'must-not-exist.json').exists()
        report['permission_denied'] = dict(returncode=refused.returncode, stderr=refused.stderr)
        report['status'] = 'passed'
    except Exception as error:
        report['status'] = 'failed'; report['error'] = str(error)
    (directory / 'acceptance.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
