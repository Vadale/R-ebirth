import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import time
import traceback

REPO = Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
ROOT = Path('/private/tmp/relm-f6b')
WORK = REPO / 'rebirth/src/rust'
MODEL = Path('/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf')
lock = (ROOT / 'verify.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
run = ROOT / ('native-' + time.strftime('%Y%m%d-%H%M%S'))
run.mkdir()
state = dict(status='running', pid=os.getpid(), directory=str(run), started_at=time.time(), stages=[])
env = os.environ.copy()
env['R_HOME'] = subprocess.check_output(['R', 'RHOME'], text=True).strip()
env['RUST_TEST_THREADS'] = '1'
for key in list(env):
    if key.startswith(('RELM_TEST_MODEL_', 'RELM_TEST_MMPROJ_')) or key == 'RELM_NATIVE_SANITIZERS':
        env.pop(key)

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def save():
    data = json.dumps(state, indent=2) + '\n'
    (run / 'status.json').write_text(data)
    temporary = ROOT / 'active-status.tmp'
    temporary.write_text(data)
    temporary.replace(ROOT / 'active-status.json')

def stage(name, command, timeout=1800, overrides=None, allow_failure=False):
    item = dict(name=name, command=command, status='running', started_at=time.time())
    state['stages'].append(item)
    state['stage'] = name
    save()
    local_env = env.copy()
    local_env.update(overrides or {})
    with (run / (name + '.log')).open('w') as output:
        child = subprocess.Popen(command, cwd=WORK, env=local_env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        item['pid'] = child.pid
        save()
        try:
            rc = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            item.update(status='failed', reason='stage timeout', finished_at=time.time())
            save()
            raise
    item.update(status='passed' if rc == 0 else 'failed', exit_code=rc, finished_at=time.time())
    save()
    if rc and not allow_failure:
        raise RuntimeError(name + ' failed')
    return rc

save()
try:
    paths = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard',
        'rebirth/R', 'rebirth/src/rust', 'rebirth/src/llama.cpp', 'rebirth/tests/testthat',
        'tests/llm-golden/live-state', 'tests/llm-golden/synthetic'], cwd=REPO, text=True).splitlines()
    paths = sorted(set(p for p in paths if (REPO / p).is_file()))
    manifest = {p: digest(REPO / p) for p in paths}
    (run / 'candidate.patch').write_bytes(subprocess.check_output(['git', 'diff', '--binary', 'HEAD'], cwd=REPO))
    changed = set(subprocess.check_output(['git', 'diff', '--name-only', 'HEAD'], cwd=REPO, text=True).splitlines())
    changed.update(subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard'], cwd=REPO, text=True).splitlines())
    import tarfile
    with tarfile.open(run / 'changed-source.tar.gz', 'w:gz') as archive:
        for path in sorted(changed.intersection(paths)):
            archive.add(REPO / path, arcname=path)

    encoded = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
    (run / 'source-manifest.json').write_bytes(encoded)
    (run / 'verify-native.py').write_bytes(Path(__file__).read_bytes())
    state['source_manifest_sha256'] = hashlib.sha256(encoded).hexdigest()
    save()
    stage('format', ['cargo', 'fmt', '--all', '--check'])
    stage('clippy', ['cargo', 'clippy', '--locked', '--offline', '-p', 'rebirth-llm', '-p', 'rebirth-ffi', '--all-targets', '--', '-D', 'warnings'])
    stage('no-spill-check', ['cargo', 'check', '--locked', '--offline', '-p', 'rebirth-llm', '--no-default-features', '--lib'])
    selection = json.loads((ROOT / 'native-selection.json').read_text())
    assert selection and all(item['count'] > 0 for item in selection)
    (run / 'native-selection.json').write_text(json.dumps(selection, indent=2) + '\n')
    for item in selection:
        stage(item['name'], item['command'], timeout=item.get('timeout', 1200))
        log = (run / (item['name'] + '.log')).read_text()
        outcomes = re.findall(r'test result: ok\. (\d+) passed; (\d+) failed;', log)
        assert outcomes and sum(int(passed) for passed, _ in outcomes) == item['count'] and all(int(failed) == 0 for _, failed in outcomes), item['name'] + ': expected positive exact test count'
        for marker in item.get('markers', []):
            assert marker in log, item['name'] + ': missing execution marker ' + marker
    drift = [p for p, sha in manifest.items() if not (REPO / p).is_file() or digest(REPO / p) != sha]
    state['source_drift'] = drift
    assert not drift, 'source changed during transport verification'
    state['status'] = 'passed'
except Exception as error:
    state.update(status='failed', error=str(error), traceback=traceback.format_exc())
finally:
    state['finished_at'] = time.time()
    save()
