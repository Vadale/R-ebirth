import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import traceback

ROOT = Path('/private/tmp/relm-f6b')
REPO = Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
WORK = REPO / 'rebirth/src/rust'
lock = (ROOT / 'queue-wakeup.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
run = ROOT / ('queue-wakeup-' + time.strftime('%Y%m%d-%H%M%S'))
run.mkdir()
state = dict(status='running', pid=os.getpid(), directory=str(run), stages=[], started_at=time.time())
env = os.environ.copy()
env['RUST_TEST_THREADS'] = '1'
for key in list(env):
    if key.startswith(('RELM_TEST_MODEL_', 'RELM_TEST_MMPROJ_')) or key == 'RELM_NATIVE_SANITIZERS':
        env.pop(key)

def save():
    data = json.dumps(state, indent=2) + '\n'
    (run / 'status.json').write_text(data)
    tmp = ROOT / 'queue-status.tmp'
    tmp.write_text(data)
    tmp.replace(ROOT / 'queue-status.json')

def stage(name, command, count=None):
    item = dict(name=name, command=command, status='running', started_at=time.time())
    state['stages'].append(item)
    state['stage'] = name
    save()
    with (run / (name + '.log')).open('w') as output:
        child = subprocess.Popen(command, cwd=WORK, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        item['pid'] = child.pid
        save()
        try:
            rc = child.wait(timeout=1200)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait(timeout=10)
            raise
    item.update(exit_code=rc, finished_at=time.time(), status='passed' if rc == 0 else 'failed')
    save()
    assert rc == 0, name + ' failed'
    if count is not None:
        log = (run / (name + '.log')).read_text()
        results = re.findall(r'test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored;', log)
        assert results == [(str(count), '0', '0')], (name, results)
        assert 'stream_full_queue_cancel_discard_and_drain_wake_producer ... ok' in log
        assert 'stream_full_queue_drain_observes_nonblocking_contention ... ok' in log
        item['verified_positive_test_count'] = count
        save()

save()
try:
    sources = [REPO / 'rebirth/src/rust/rebirth-llm/src' / name for name in ['async_job.rs', 'live_steering_tests.rs']]
    frozen = {source: source.read_bytes() for source in sources}
    for source, data in frozen.items():
        (run / source.name).write_bytes(data)
    (run / 'candidate.patch').write_bytes(subprocess.check_output(['git', 'diff', 'HEAD', '--'] + [str(source) for source in sources], cwd=REPO))
    state['source_sha256'] = {str(source.relative_to(REPO)): hashlib.sha256(data).hexdigest() for source, data in frozen.items()}
    state['parent_failed_run'] = 'queue-wakeup-20261004-101938'
    (run / 'verify-queue-wakeup.py').write_bytes(Path(__file__).read_bytes())
    stage('format', ['cargo', 'fmt', '--all', '--check'])
    stage('clippy', ['cargo', 'clippy', '--locked', '--offline', '-p', 'rebirth-llm', '--all-targets', '--', '-D', 'warnings'])
    stage('clippy-no-spill', ['cargo', 'clippy', '--locked', '--offline', '-p', 'rebirth-llm', '--no-default-features', '--all-targets', '--', '-D', 'warnings'])
    base = ['cargo', 'test', '--locked', '--offline', '-p', 'rebirth-llm', '--lib']
    stage('default-debug', base + ['stream_full_queue'], 2)
    stage('no-spill-debug', base + ['--no-default-features', 'stream_full_queue'], 2)
    stage('default-release', base + ['--release', 'stream_full_queue'], 2)
    assert all(source.read_bytes() == data for source, data in frozen.items()), 'source drift during targeted verification'
    state.update(status='passed', source_drift=False, verified_outcomes=6)
except Exception as error:
    state.update(status='failed', error=str(error), traceback=traceback.format_exc())
finally:
    state['finished_at'] = time.time()
    save()
