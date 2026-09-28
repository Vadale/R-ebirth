#!/usr/bin/env python3
"""Actual HTTP/process acceptance for D-034. No offline or fake-native fallback."""
import argparse
import concurrent.futures
import contextlib
import csv
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
import tempfile
from offline import ensure_offline

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
ROUTE = '/v1/extractions'
GATES = dict(http='G1', admission='G2', recovery='G3', persistence='G4', isolation='G5', native='G6', stress='G7', supervisor='G8')
NULL_OUTPUT = dict(amount_usd=None, amount_qualifier='not_stated', duration_years=None,
                   conditional_on_funds=None, evidence=dict(amount_usd=None, amount_qualifier=None,
                   duration_years=None, conditional_on_funds=None))


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')


def read_json(path):
    return json.loads(Path(path).read_bytes())


def write_json(path, value):
    Path(path).write_bytes(encoded(value) + b'\n')


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def record_ok(path):
    value = read_json(path)
    pin = value.pop('record_sha256')
    assert pin == digest(value), f'record digest mismatch: {path}'
    value['record_sha256'] = pin
    return value


def record_path(store, kind, ident):
    # Public IDs are case-sensitive even on case-insensitive host filesystems.
    return Path(store) / kind / (ident.encode('ascii').hex() + '.json')


def until(predicate, timeout, label, interval=.1):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError(f'timed out: {label} ({timeout}s)')


def request_body(ident, **changes):
    value = dict(id=ident, target='Funding award', text='No funding amount is stated.', seed=101)
    value.update(changes)
    return value


def p95(values):
    assert values, 'missing latency observations'
    return sorted(values)[math.ceil(.95 * len(values)) - 1]


class Harness:
    def __init__(self, args):
        self.args = args
        self.contract = read_json(args.contract)
        assert self.contract['status'] == 'approved' and self.contract['decision'] == 'D-034'
        self.limits = self.contract['limits']
        self.work = Path(args.work_dir).resolve()
        if self.work.exists() and any(self.work.iterdir()):
            raise ValueError('work directory must be empty; previous evidence is never overwritten')
        self.work.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.library = Path(args.source_library or (Path(args.environment) / 'library' if args.environment else '')).resolve()
        assert self.library.is_dir(), 'provide the prepared --source-library or --environment'
        self.requests = []
        self.checks = []
        self.services = []
        self.report = dict(contract_sha256=hashlib.sha256(Path(args.contract).read_bytes()).hexdigest(),
            os=platform.platform(), python=platform.python_version(), suite=args.suite, profile=args.profile,
            started_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), status='running', gates={}, checks=self.checks,
            environment=str(Path(args.environment).resolve()) if args.environment else None,
            source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in (ROOT / 'examples/funding-service').glob('*.R')})
        if args.environment:
            self.report['prepared_environment'] = read_json(Path(args.environment) / 'environment.json')

    def check(self, condition, label):
        self.checks.append(dict(check=label, passed=bool(condition)))
        assert condition, label

    def inspect(self, identities):
        ids = [str(x['pid']) for x in identities if x]
        if not ids:
            return []
        result = subprocess.run(['Rscript', '--vanilla', str(HERE / 'processes.R'), str(self.library), 'inspect', *ids],
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, 'identity-aware process inspection failed: ' + result.stderr
        return json.loads(result.stdout)

    def same_alive(self, identity):
        value = self.inspect([identity])[0]
        return value.get('alive', False) and abs(float(value['birth']) - float(identity['birth'])) < .001

    def dead(self, identity, timeout=None):
        if identity:
            until(lambda: not self.same_alive(identity), timeout or self.limits['worker_death_seconds'], 'confirmed process death', .1)

    def service(self, name, **kwargs):
        service = Service(self, name, **kwargs)
        self.services.append(service)
        return service

    def latencies(self, rows, kind):
        times = [r['elapsed_ms'] for r in rows]
        self.check(p95(times) <= self.limits[kind + '_p95_ms'], kind + ' p95 within frozen bound')
        self.check(max(times) <= self.limits[kind + '_max_ms'], kind + ' maximum within frozen bound')

    def finish(self):
        for service in reversed(self.services):
            try:
                service.close()
            except Exception as error:
                self.report.setdefault('cleanup_errors', []).append(str(error))
                self.report['status'] = 'failed'
        with (self.work / 'requests.csv').open('w', newline='') as stream:
            fields = ['instance', 'method', 'path', 'status', 'elapsed_ms']
            writer = csv.DictWriter(stream, fields)
            writer.writeheader()
            writer.writerows({k: r[k] for k in fields} for r in self.requests)
        self.report['finished_at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        write_json(self.work / 'acceptance.json', self.report)


class Service:
    def __init__(self, harness, name, config=None, native=False, store=None, env=None, port=None, start=True):
        self.h = harness; self.name = name; self.native = native
        self.directory = harness.work / name
        self.directory.mkdir(mode=0o700)
        self.store = Path(store) if store else self.directory / 'store'
        self.config = config if config is not None else (dict(worker=dict(mode='native')) if native else
            dict(worker=dict(mode='success', raw=json.dumps(NULL_OUTPUT))))
        self.control = self.directory / 'control.json'; write_json(self.control, self.config)
        self.environment = str(Path(env or harness.args.environment).resolve()) if (env or harness.args.environment) else ''
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); self.port = port or sock.getsockname()[1]
        self.process = None; self.sampler = None; self.sample_log = None; self.workers = []
        self.sampler_stop = self.directory / 'sampler.stop'
        self.samples = self.directory / 'rss.csv'
        self.sample_error = self.directory / 'rss.error'
        self.log = (self.directory / 'frontend.log').open('wb')
        self.started = time.monotonic()
        if start:
            self.start()

    def command(self, action='start'):
        if self.native and (action == 'stop' or self.config == dict(worker=dict(mode='native'))):
            result = ['Rscript', '--vanilla', str(ROOT / 'examples/funding-service' / (action + '.R')),
                      '--environment', self.environment, '--store', str(self.store)]
            return result + (['--port', str(self.port)] if action == 'start' else [])
        return ['Rscript', '--vanilla', str(HERE / 'fixture.R'), str(ROOT), str(self.h.library),
                str(self.store), str(self.port), self.environment if self.native else '', str(self.control), action]

    def start(self):
        environment = os.environ.copy()
        shared = self.directory / 'inherited-shared-temp'; shared.mkdir(exist_ok=True, mode=0o700)
        for name in ('CALLR_TMPDIR', 'TMPDIR', 'TMP', 'TEMP'):
            environment[name] = str(shared)
        environment.update(HTTP_PROXY='http://127.0.0.1:9', HTTPS_PROXY='http://127.0.0.1:9', NO_PROXY='127.0.0.1,localhost')
        self.process = subprocess.Popen(self.command(), stdout=self.log, stderr=subprocess.STDOUT,
                                        env=environment, start_new_session=True)
        self.sample_log = (self.directory / 'sampler.log').open('wb')
        self.sampler = subprocess.Popen(['Rscript', '--vanilla', str(HERE / 'processes.R'), str(self.h.library),
            'sample', str(self.process.pid), str(self.samples), str(self.sampler_stop), str(self.sample_error)],
            stdout=self.sample_log, stderr=subprocess.STDOUT)
        return self

    def status(self):
        path = self.store / 'status.json'
        try:
            value = read_json(path)
        except (FileNotFoundError, json.JSONDecodeError):
            return {}
        worker = value.get('worker')
        if worker and worker.get('pid') and not any(w['pid'] == worker['pid'] and w['birth'] == worker['birth'] for w in self.workers):
            self.workers.append(worker)
        return value

    def ready(self, timeout=None):
        def check():
            if self.process and self.process.poll() is not None:
                raise AssertionError('frontend exited before readiness: ' + (self.directory / 'frontend.log').read_text(errors='replace')[-3000:])
            try:
                return self.http('GET', '/health/ready')['status'] == 200
            except (OSError, http.client.HTTPException):
                return False
        until(check, timeout or self.h.limits['worker_start_seconds'], 'service readiness', 1)
        self.status()
        return self

    def http(self, method, path, value=None, headers=None, timeout=2):
        body = encoded(value) if isinstance(value, (dict, list)) else value
        headers = dict(headers or {})
        if body is not None and method == 'POST': headers.setdefault('Content-Type', 'application/json')
        start = time.monotonic()
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=timeout)
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse(); payload = response.read(self.h.limits['terminal_record_bytes'] + 1)
            row = dict(instance=self.name, method=method, path=path, status=response.status,
                       elapsed_ms=1000 * (time.monotonic()-start), headers=dict(response.getheaders()), body=payload)
            self.h.requests.append(row)
            return row
        except (OSError, http.client.HTTPException) as error:
            self.h.requests.append(dict(instance=self.name, method=method, path=path, status=None,
                elapsed_ms=1000*(time.monotonic()-start), error=type(error).__name__))
            raise
        finally:
            connection.close()

    def post(self, value):
        return self.http('POST', ROUTE, value)

    def terminal(self, ident, timeout=None):
        def check():
            response = self.http('GET', ROUTE + '/' + ident)
            assert response['status'] in (200, 202), response
            return json.loads(response['body']) if response['status'] == 200 else None
        value = until(check, timeout or self.h.limits['request_deadline_seconds'] + self.h.limits['recovery_seconds'],
                      'terminal record ' + ident, self.h.limits['client_poll_seconds'])
        committed = record_ok(record_path(self.store, 'results', ident))
        self.h.check(value == committed, 'terminal visible only as committed record: ' + ident)
        self.h.check(value['state'] in self.h.contract['accepted_terminal_states'], 'terminal accounting: ' + ident)
        record_ok(record_path(self.store, 'admissions', ident))
        self.status()
        return value

    def run_job(self, value):
        response = self.post(value)
        self.h.check(response['status'] == 202, 'new job durably accepted: ' + value['id'])
        self.h.check(record_path(self.store, 'admissions', value['id']).is_file(), 'admission exists before 202')
        return self.terminal(value['id'])

    def kill_worker(self):
        worker = self.status().get('worker')
        assert worker and self.h.same_alive(worker), 'missing live owned worker identity'
        start = time.monotonic(); os.kill(worker['pid'], signal.SIGKILL)
        self.h.dead(worker)
        return worker, start

    def kill_frontend(self):
        self.status()
        assert self.process and self.process.poll() is None
        self.process.kill(); self.process.wait(timeout=5)
        for worker in self.workers:
            self.h.dead(worker)

    def close(self):
        failures = []
        if self.process and self.process.poll() is None:
            start = time.monotonic()
            try:
                result = subprocess.run(self.command('stop'), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        timeout=self.h.limits['stop_seconds'] + 2)
                if result.returncode: failures.append('operator stop failed: ' + result.stderr.decode(errors='replace'))
            except subprocess.TimeoutExpired:
                failures.append('operator stop command exceeded bound')
            if failures and self.process.poll() is None:
                self.process.terminate()
            try:
                self.process.wait(timeout=self.h.limits['stop_seconds'])
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=5)
                failures.append('ordinary frontend stop exceeded frozen bound')
            if time.monotonic()-start > self.h.limits['stop_seconds']: failures.append('ordinary stop exceeded15s')
        for worker in self.workers:
            try:
                self.h.dead(worker)
            except Exception as error:
                failures.append(str(error))
        if self.sampler and self.sampler.poll() is None:
            self.sampler_stop.touch(); self.sampler.wait(timeout=5)
        if self.sampler and self.sampler.returncode != 0:
            failures.append('identity-aware RSS sampler failed: ' + (self.directory / 'sampler.log').read_text(errors='replace'))
        if self.sample_log and not self.sample_log.closed: self.sample_log.close()
        if not self.log.closed: self.log.close()
        if failures: raise AssertionError('; '.join(failures))

    def raw(self, headers, body=b'', method='POST', close_write=False):
        head = f'{method} {ROUTE if method == "POST" else "/health/live"} HTTP/1.1\r\n'.encode()
        payload = head + b''.join(k.encode() + b': ' + v.encode() + b'\r\n' for k, v in headers) + b'\r\n' + body
        start = time.monotonic(); received = b''; state = 'closed'
        with socket.create_connection(('127.0.0.1', self.port), timeout=2) as sock:
            sock.settimeout(2); sock.sendall(payload)
            if close_write: sock.shutdown(socket.SHUT_WR)
            try:
                while b'\r\n\r\n' not in received:
                    part = sock.recv(65536)
                    if not part: break
                    received += part
            except socket.timeout:
                state = 'timeout'
            except ConnectionResetError:
                state = 'closed'
        match = re.match(rb'HTTP/1\.[01] ([0-9]{3})', received)
        status = int(match[1]) if match else None
        self.h.requests.append(dict(instance=self.name, method=method, path=ROUTE, status=status,
                                    elapsed_ms=1000*(time.monotonic()-start)))
        return status, state


def fixture_config(**worker):
    return dict(worker=dict(mode='success', raw=json.dumps(NULL_OUTPUT), **worker))


def check_private(h, service):
    status = service.status(); worker = status['worker']
    ipc = Path(worker['ipc_dir']).resolve()
    h.check(ipc.is_relative_to((service.store / 'runtime').resolve()), 'worker IPC stays inside owned runtime root')
    h.check(ipc.name == worker['epoch'], 'worker IPC directory bound to epoch')
    for path in [service.store, ipc, *service.store.rglob('*')]:
        if path.is_symlink():
            raise AssertionError('unexpected symlink inside private service store')
        h.check(path.stat().st_mode & 0o077 == 0, 'private mode: ' + str(path.relative_to(service.store)))
    shared = service.directory / 'inherited-shared-temp'
    h.check(not any(p.is_file() for p in shared.rglob('*')), 'no callr IPC in inherited shared temp location')


def http_suite(h):
    service = h.service('http', config=fixture_config()).ready()
    h.check(service.http('GET', '/health/live')['status'] == 200, 'live frontend')
    h.check(service.http('GET', ROUTE + '/unknown')['status'] == 404, 'unknown ticket')
    for path in ('/__docs__/', '/__swagger__/', '/openapi.json', '/swagger.json', '/eval', '/stop', '/restart'):
        h.check(service.http('GET', path)['status'] in (404, 405), 'no unsupported route: ' + path)
    before = service.status()['dispatch_count']
    base = encoded(request_body('rejected'))
    malformed = [base[:-1], b'{"id":"a","\\u0069d":"b"}',
        base.replace(b'101', b'101.0'), base.replace(b'101', b'1e2'),
        base.replace(b'No funding', b'\xff funding'), base.replace(b'No funding', b'\\u0000 funding'),
        base.replace(b'No funding', b'\\ud800 funding'), base.replace(b'No funding', b'\\udc00 funding')]
    for body in malformed:
        h.check(service.http('POST', ROUTE, body)['status'] == 400, 'malformed literal JSON rejected before dispatch')
    h.check(service.http('POST', ROUTE, b'[]')['status'] == 422, 'request must be an object')
    for changes in [dict(id='../bad'), dict(id=''), dict(seed=-1),
                    dict(seed=2147483648), dict(seed=True), dict(text=''), dict(target=''), dict(extra='forbidden')]:
        h.check(service.post(request_body('bad-fields', **changes))['status'] == 422, 'invalid request fields rejected')
    for changes in [dict(text='x' * 8193), dict(target='x' * 257), dict(id='a' * 65)]:
        h.check(service.post(request_body('field-overflow', **changes))['status'] == 413, 'field byte overflow rejected')
    for headers, code in [({'Content-Type': 'text/plain'}, 415), ({'Content-Encoding': 'gzip'}, 415),
                          ({'Origin': 'null'}, 403), ({'Origin': 'http://localhost'}, 403),
                          ({'Host': 'example.com'}, 403), ({'Host': '127.0.0.1.evil'}, 403)]:
        h.check(service.http('POST', ROUTE, base, headers)['status'] == code, 'forbidden headers rejected')
    host = [('Host', f'127.0.0.1:{service.port}'), ('Content-Type', 'application/json'), ('Connection', 'close')]
    framing = [([], b'', (411,)), ([('Content-Length', '-1')], b'', (400,)),
        ([('Content-Length', '1.0')], b'', (400,)), ([('Content-Length', '1e2')], b'', (400,)),
        ([('Content-Length', '999999999999999999999999')], b'', (400, 413)),
        ([('Content-Length', str(len(base))), ('Content-Length', str(len(base)))], base, (400,)),
        ([('Content-Length', str(len(base))), ('Content-Length', '1')], base, (400,)),
        ([('Transfer-Encoding', 'chunked')], b'0\r\n\r\n', (400,)),
        ([('Transfer-Encoding', 'chunked'), ('Content-Length', str(len(base)))], base, (400,)),
        ([('Content-Length', '16385')], b'', (413,)),
        ([('Content-Length', str(len(base)+20))], base[:20], (400,))]
    for headers, body, codes in framing:
        status, state = service.raw(host + headers, body, close_write=True)
        h.check(status in codes or (status is None and state == 'closed'), 'framing rejected by HTTP parser or application')
    status, state = service.raw(host + [('Content-Length', '2')], b'{}', method='GET', close_write=True)
    h.check(status == 400 or (status is None and state == 'closed'), 'GET body rejected')
    h.check(service.status()['dispatch_count'] == before, 'all rejected requests caused zero dispatches')
    h.check(not list((service.store / 'admissions').glob('*.json')), 'rejections left no admissions')
    limit = request_body('L' * 64, target='é' * 128, text='é' * 4096, seed=2147483647)
    body = encoded(limit); body += b' ' * (16384-len(body))
    h.check(len(body) == 16384, 'exact total body fixture size')
    h.check(service.http('POST', ROUTE, body)['status'] == 202, 'exact byte limits admitted')
    service.terminal(limit['id'])
    admission = record_ok(record_path(service.store, 'admissions', limit['id']))
    h.check(admission['input'] == limit and admission['input_sha256'] == digest(limit), 'canonical Unicode input preserved independently')
    h.check(service.http('POST', ROUTE, body + b' ')['status'] == 413, 'body limit plus one rejected')
    service.ready()
    unicode = request_body('unicode', text='Literal \\u0000, café, 😀; no hidden NUL.')
    service.run_job(unicode)
    h.check(record_ok(record_path(service.store, 'admissions', 'unicode'))['input'] == unicode, 'escaped backslash and supplementary Unicode preserved')
    for ident in ('abc', 'ABC'):
        service.run_job(request_body(ident))
    h.check(record_path(service.store, 'results', 'abc').read_bytes() != record_path(service.store, 'results', 'ABC').read_bytes(),
            'case-distinct public IDs have independent immutable files')
    for ident in ('abc', 'ABC'):
        h.check(json.loads(service.post(request_body(ident))['body'])['id'] == ident, 'case-distinct replay retains exact ID')
    check_private(h, service)


def admission_suite(h):
    release = h.work / 'admission.release'
    config = dict(worker=dict(mode='pause', release_file=str(release), raw=json.dumps(NULL_OUTPUT)))
    service = h.service('admission', config=config).ready()
    request = request_body('active', text='PRIVATE_SOURCE_SENTINEL')
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
        same = list(pool.map(lambda _: service.post(request), range(20)))
    h.check(all(r['status'] == 202 for r in same), 'simultaneous same-ID clients share one durable active admission')
    until(lambda: service.status().get('active_id') == 'active', 5, 'active worker slot')
    health = []; health_errors = []; stop = threading.Event()
    def poll():
        try:
            while not stop.is_set():
                for path in ('/health/live', '/health/ready'):
                    health.append(service.http('GET', path))
                stop.wait(1)
        except Exception as error:
            health_errors.append(error)
            stop.set()
    thread = threading.Thread(target=poll, daemon=True); thread.start()
    start = len(h.requests)
    with concurrent.futures.ThreadPoolExecutor(max_workers=h.limits['overload_clients']) as pool:
        burst = list(pool.map(lambda i: service.post(request_body('burst-' + str(i))), range(h.limits['overload_clients'])))
    h.check(all(r['status'] == 429 for r in burst), 'all 20 extra distinct clients rejected; zero queue')
    h.check(all(r['headers'].get('Retry-After') == '1' for r in burst), 'overload Retry-After is frozen one second')
    h.latencies(burst, 'admission')
    h.check(service.post(dict(reversed(list(request.items()))))['status'] == 202, 'canonical active replay has same receipt')
    h.check(service.post(dict(request, seed=102))['status'] == 409, 'changed active replay conflicts')
    until(lambda: len(health) >= 20 or health_errors, 15, 'health samples while actual worker blocks', .2)
    stop.set(); thread.join(timeout=3)
    h.check(not thread.is_alive(), 'health monitor completed')
    h.check(not health_errors, 'health polling had no exceptions or timed-out attempts')
    h.check(all(r['status'] == (200 if r['path'].endswith('/live') else 503) for r in health), 'health/live stays responsive while busy')
    h.latencies(health, 'health')
    h.check(service.status()['dispatch_count'] == 1, 'no duplicate or queued dispatch')
    h.check(len(list((service.store / 'admissions').glob('*.json'))) == 1, 'only one durable admission')
    release.touch(); terminal = service.terminal('active')
    original = record_path(service.store, 'results', 'active').read_bytes()
    h.check(service.post(request)['status'] == 200, 'terminal replay returns cached record')
    h.check(service.post(dict(request, text='changed'))['status'] == 409, 'changed terminal replay conflicts')
    h.check(record_path(service.store, 'results', 'active').read_bytes() == original, 'terminal bytes immutable across replay')
    h.check(service.status()['dispatch_count'] == 1, 'terminal replay not executed')
    check_private(h, service)
    h.check('PRIVATE_SOURCE_SENTINEL' not in (service.directory / 'frontend.log').read_text(errors='replace'), 'source excluded from frontend diagnostics')


def recovery_suite(h):
    # Short private deadlines exercise mechanics; the unchanged 120s default is
    # a separate required case, never silently represented by this short test.
    for name, worker, limit in [('deadline', dict(mode='pause', delay_seconds=600), 2),
                                ('diagnostic', dict(mode='flood'), 120),
                                ('ipc-flood', dict(mode='ipc_flood'), 120),
                                ('wrong-epoch', dict(mode='wrong_epoch'), 120)]:
        service = h.service(name, config=dict(worker=worker, limits=dict(request_deadline_seconds=limit))).ready()
        previous = service.status()['worker']
        start = time.monotonic()
        terminal = service.run_job(request_body(name))
        h.check(terminal['state'] in ('interrupted', 'error'), name + ' cannot publish success')
        h.dead(previous)
        service.ready(h.limits['recovery_seconds'])
        h.check(service.status()['worker']['epoch'] != previous['epoch'], name + ' creates a fresh epoch only after death')
        h.check(time.monotonic()-start <= limit + h.limits['recovery_seconds'], name + ' bounded recovery')
        service.close()
    service = h.service('worker-kill', config=dict(worker=dict(mode='pause', delay_seconds=600))).ready()
    h.check(service.post(request_body('killed'))['status'] == 202, 'kill fixture admitted')
    old, killed_at = service.kill_worker()
    terminal = service.terminal('killed')
    h.check(terminal['state'] == 'interrupted', 'SIGKILL accepted job accounted')
    service.ready(h.limits['recovery_seconds'])
    h.check(time.monotonic()-killed_at <= h.limits['recovery_seconds'], 'worker SIGKILL recovery bound')
    h.check(service.status()['worker']['epoch'] != old['epoch'], 'worker epoch changes after SIGKILL')
    service.close()

    late_file = h.work / 'late-completion.json'; release = h.work / 'new-epoch.release'
    config = dict(**fixture_config(), late_completion_file=str(late_file), request_modes=dict(
        old=dict(mode='pause', delay_seconds=600), current=dict(mode='pause', release_file=str(release), raw=json.dumps(NULL_OUTPUT))))
    late = h.service('late-epoch', config=config).ready()
    late.post(request_body('old')); previous, _ = late.kill_worker()
    h.check(late.terminal('old')['state'] == 'interrupted', 'retired request receives one interrupted terminal')
    late.ready(); current = late.status()['worker']; late.post(request_body('current'))
    write_json(late_file, dict(epoch=previous['epoch'], id='current', raw=json.dumps(NULL_OUTPUT)))
    until(lambda: not late_file.exists(), 5, 'late old-epoch event consumed by runtime guard')
    h.check(late.status()['worker']['epoch'] == current['epoch'] and late.status()['active_id'] == 'current',
            'old-epoch completion does not retire or clear the new active slot')
    h.check(not record_path(late.store, 'results', 'current').exists(), 'old-epoch output cannot publish for the new request')
    release.touch(); h.check(late.terminal('current')['state'] == 'success', 'current epoch still completes normally')
    late.close()

    crash = h.service('frontend-kill', config=dict(**fixture_config(), request_modes=dict(
        pending=dict(mode='pause', delay_seconds=600)))).ready()
    crash.run_job(request_body('earlier')); original = record_path(crash.store, 'results', 'earlier').read_bytes()
    crash.post(request_body('pending')); old_worker = crash.status()['worker']; crash.kill_frontend()
    h.dead(old_worker)
    restarted = h.service('frontend-restarted', store=crash.store, config=fixture_config()).ready()
    h.check(restarted.terminal('pending')['state'] == 'interrupted', 'frontend SIGKILL leaves a recoverable durable admission')
    h.check(record_path(crash.store, 'results', 'earlier').read_bytes() == original, 'earlier terminal survives frontend SIGKILL unchanged')
    h.check(restarted.status()['dispatch_count'] == 0, 'frontend restart never silently repeats accepted work')
    restarted.close(); crash.close()

    startup = h.service('startup-flood', config=dict(worker=dict(mode='success', init_flood=True)))
    until(lambda: startup.status().get('state') == 'faulted', 30, 'startup diagnostic flood latches fault')
    h.check(startup.http('GET', '/health/live')['status'] == 200, 'startup flood keeps frontend alive')
    h.check(startup.http('GET', '/health/ready')['status'] == 503, 'startup flood never ready')
    h.check(startup.status()['restart_attempts'] == 3, 'three automatic failures latch fault without hidden retries')
    for identity in startup.workers: h.dead(identity)
    startup.close()
    failure = h.service('initialization-failure', config=dict(worker=dict(mode='success', init_fail=True)))
    until(lambda: failure.status().get('state') == 'faulted', 30, 'initialization failures latch fault')
    h.check(failure.status()['restart_attempts'] == 3, 'initialization failures obey restart window')
    failure.close()

    temp = h.service('temp-override', config=dict(worker=dict(mode='temp_echo'))).ready()
    terminal = temp.run_job(request_body('temp'))
    echo = json.loads(terminal['raw_output']); values = dict(echo['environment'], tempdir=echo['tempdir'])
    owned = Path(temp.status()['worker']['ipc_dir']).resolve()
    for name in ('CALLR_TMPDIR', 'TMPDIR', 'TMP', 'TEMP', 'tempdir'):
        h.check(Path(values[name]).resolve().is_relative_to(owned), 'child private temp override: ' + name)
    check_private(h, temp)
    temp.close()

    unreapable = h.service('unreapable', config=dict(worker=dict(mode='pause', delay_seconds=600),
        limits=dict(request_deadline_seconds=2), unreapable=True)).ready()
    old = unreapable.status()['worker']; unreapable.post(request_body('unreapable'))
    until(lambda: unreapable.status().get('state') == 'faulted', 15, 'unconfirmed death remains faulted')
    h.check(unreapable.status().get('worker', {}).get('epoch') == old['epoch'], 'no replacement under unknown death')
    if h.same_alive(old): os.kill(old['pid'], signal.SIGKILL)
    h.dead(old); unreapable.close()

    if h.args.default_deadline:
        default = h.service('default-120-second-deadline', config=dict(worker=dict(mode='pause', delay_seconds=600))).ready()
        start = time.monotonic(); result = default.run_job(request_body('default-deadline'))
        elapsed = time.monotonic()-start
        h.check(result['state'] == 'interrupted', 'unchanged default deadline interrupts actual child')
        h.check(119 <= elapsed <= 125, 'default120s deadline plus confirmed death within125s')
        default.ready(h.limits['recovery_seconds']); default.close()
    else:
        h.report.setdefault('unexecuted', []).append('G3 default 120-second real-process deadline; rerun --default-deadline')


def persistence_suite(h):
    for stage in ('before_admission_rename', 'after_admission_rename', 'before_terminal_rename', 'after_terminal_rename'):
        marker = h.work / (stage + '.marker')
        config = fixture_config()
        config['checkpoint'] = dict(stage=stage, id='crash', marker=str(marker), release=str(marker) + '.release')
        service = h.service(stage, config=config).ready()
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        future = pool.submit(service.post, request_body('crash'))
        until(marker.exists, 10, 'actual frontend rename checkpoint ' + stage)
        admission = record_path(service.store, 'admissions', 'crash'); result = record_path(service.store, 'results', 'crash')
        before = result.read_bytes() if result.exists() else None
        h.check(admission.exists() == (stage != 'before_admission_rename'), stage + ' publication boundary')
        service.kill_frontend()
        with contextlib.suppress(OSError, http.client.HTTPException, TimeoutError): future.result(timeout=3)
        pool.shutdown(wait=True)
        recovered = h.service(stage + '-recovered', config=fixture_config(), store=service.store).ready()
        if stage == 'before_admission_rename':
            h.check(recovered.http('GET', ROUTE + '/crash')['status'] == 404, 'unpublished admission never invented')
            recovered.run_job(request_body('crash'))
        else:
            terminal = recovered.terminal('crash')
            expected = 'success' if stage == 'after_terminal_rename' else 'interrupted'
            h.check(terminal['state'] == expected, 'crash boundary terminal state: ' + stage)
            h.check(recovered.status()['dispatch_count'] == 0, 'no automatic retry of unresolved admission')
        if before is not None: h.check(result.read_bytes() == before, 'committed result preserved byte-for-byte after lost response')
        h.check(recovered.post(request_body('crash'))['status'] == 200, 'same-ID reconnect reads existing terminal')
        recovered.close(); service.close()

    service = h.service('immutable', config=fixture_config()).ready()
    service.run_job(request_body('receipt'))
    store = service.store
    second_writer = h.service('second-writer', config=fixture_config(), store=store)
    until(lambda: second_writer.process.poll() is not None, 10, 'second writer refusal')
    h.check(service.http('GET', '/health/ready')['status'] == 200, 'second writer does not disturb first owner')
    service.close(); second_writer.close()
    for kind in ('result', 'admission', 'service-identity'):
        copy = h.work / ('corrupt-' + kind + '-store'); shutil.copytree(store, copy)
        if kind == 'service-identity':
            path = copy / 'service.json'
        else:
            path = record_path(copy, 'results' if kind == 'result' else 'admissions', 'receipt')
        path.write_bytes(path.read_bytes()[:-3] + b'BAD')
        corrupt = h.service('corrupt-' + kind, config=fixture_config(), store=copy)
        until(lambda: corrupt.process.poll() is not None, 10, 'corrupt ' + kind + ' refuses startup')
        h.check(path.read_bytes().endswith(b'BAD'), 'corruption preserved for inspection, never repaired silently')
        corrupt.close()
    changed = h.service('changed-identity', config=dict(**fixture_config(), identity_override='different-build'), store=store)
    until(lambda: changed.process.poll() is not None, 10, 'changed configuration/build identity refuses reuse')
    changed.close()

    for label, raw in [('escaped-overflow', '\x01' * 65536), ('unicode-overflow', 'a' * 4095 + '😀' * 16000)]:
        overflow = h.service(label, config=dict(worker=dict(mode='overflow', raw=raw))).ready()
        terminal = overflow.run_job(request_body(label))
        h.check(terminal['state'] == 'error' and terminal['error']['reason'] == 'output_limit', 'serialized overflow never becomes success')
        h.check(terminal['raw_truncated'] is True and terminal['raw_bytes'] == len(raw.encode()), 'overflow raw size explicit')
        h.check(terminal['raw_sha256'] == hashlib.sha256(raw.encode()).hexdigest(), 'overflow digest independently checked')
        prefix = terminal.get('raw_prefix', '')
        h.check(len(prefix.encode()) <= 4096 and raw.startswith(prefix), 'overflow prefix bounded at Unicode boundary')
        h.check(record_path(overflow.store, 'results', label).stat().st_size <= 131072, 'fallback terminal serialization bounded')
        overflow.close()

    failed = h.service('publication-failure', config=dict(**fixture_config(), fail_publication=dict(stage='before_terminal_rename', id='storage'))).ready()
    h.check(failed.post(request_body('storage'))['status'] == 202, 'storage-failure fixture durably admitted')
    until(lambda: failed.status().get('state') == 'faulted', 10, 'failed publication closes admission')
    h.check(not record_path(failed.store, 'results', 'storage').exists(), 'failed rename is never false terminal success')
    failed.close()
    repaired = h.service('publication-repaired', config=fixture_config(), store=failed.store).ready()
    h.check(repaired.terminal('storage')['state'] == 'interrupted', 'explicit repair recovers admitted job without retry')
    repaired.close()

    failed_admission = h.service('admission-publication-failure', config=dict(**fixture_config(),
        fail_publication=dict(stage='before_admission_rename', id='no-receipt'))).ready()
    response = failed_admission.post(request_body('no-receipt'))
    h.check(response['status'] == 503, 'unpublished admission cannot receive an accepted response')
    h.check(failed_admission.status()['dispatch_count'] == 0 and not record_path(failed_admission.store, 'admissions', 'no-receipt').exists(),
            'failed admission publication never dispatches or invents a receipt')
    failed_admission.close()

    foreign_store = h.work / 'foreign-ipc-store'; shutil.copytree(store, foreign_store)
    foreign = foreign_store / 'runtime' / ('f' * 32); foreign.mkdir(parents=True, mode=0o700)
    write_json(foreign / 'owner.json', dict(epoch='f'*32, service_identity='unowned', frontend={}, worker={}))
    marker = foreign / 'must-remain'; marker.write_text('unowned bytes')
    refused = h.service('foreign-ipc', config=fixture_config(), store=foreign_store)
    until(lambda: refused.process.poll() is not None, 10, 'unknown IPC ownership fails closed')
    h.check(marker.read_text() == 'unowned bytes', 'unowned epoch bytes never cleaned by another service')
    refused.close()

    # A stopped store is the only point where the fixture changes diagnostics.
    # The smaller private quota makes the real idle append guard observable.
    quota_store = h.work / 'quota-store'; shutil.copytree(store, quota_store)
    terminal_path = record_path(quota_store, 'results', 'receipt'); immutable = terminal_path.read_bytes()
    event_path = quota_store / 'events.jsonl'
    with event_path.open('ab') as stream:
        stream.write((encoded(dict(event='fixture-history')) + b'\n') * 1024)
    baseline_bytes = sum(p.stat().st_size for p in quota_store.rglob('*') if p.is_file())
    quota = baseline_bytes + 32768
    bounded = h.service('bounded-idle-diagnostics', store=quota_store, config=dict(**fixture_config(),
        limits=dict(store_limit_bytes=quota, store_admission_floor_bytes=32768)))
    until(lambda: bounded.status().get('state') == 'faulted', 10, 'near-capacity diagnostics latch fault before consuming reserve')
    paths = [quota_store / 'events.jsonl', quota_store / 'rss.csv']
    sizes = [p.stat().st_size if p.exists() else 0 for p in paths]
    time.sleep(2)
    h.check(sizes == [p.stat().st_size if p.exists() else 0 for p in paths], 'idle faulted service stops appending RSS and event logs')
    h.check(terminal_path.read_bytes() == immutable, 'quota exhaustion preserves authoritative terminal bytes')
    h.check(sum(p.stat().st_size for p in quota_store.rglob('*')
                if p.is_file() and p.relative_to(quota_store).parts[0] != 'runtime') <= quota,
            'actual result-store bytes remain below private quota; IPC has its separate bound')
    h.check(bounded.post(request_body('over-capacity'))['status'] == 503, 'quota fault refuses new admission')
    bounded.close()


def profile_check(h):
    assert h.args.environment and h.args.profile, 'native gates require --environment and --profile; no fixture fallback'
    profile = h.contract['profiles'][h.args.profile]
    manifest = h.report['prepared_environment']
    h.check(manifest['model']['alias'] == profile['model_alias'], 'native model alias matches declared profile')
    h.check(manifest['backend'] == profile['backend'], 'native backend matches declared profile')
    os_ok = (platform.system() == 'Darwin' and platform.machine() == 'arm64') if h.args.profile.startswith('mac_') else (
        platform.system() == 'Linux' and platform.machine() == 'x86_64')
    h.check(os_ok, 'actual OS and ISA match declared native profile')
    return profile


def development(h):
    path = ROOT / 'examples/funding-extraction/documents.json'
    h.report['development_corpus_sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    return read_json(path)


def sample_rows(service):
    if not service.samples.exists(): return []
    with service.samples.open(newline='') as stream:
        return list(csv.DictReader(stream))


def idle_rss(h, service):
    row = fresh_sample(service, timeout=10*h.limits['control_poll_ms']/1000)
    identities = json.loads(row['identities'])
    status = service.status()
    for expected in (status['frontend'], status['worker']):
        h.check(any(x['pid'] == expected['pid'] and abs(float(x['birth'])-float(expected['birth'])) < .001
                    for x in identities), 'RSS sample includes live process creation identity')
    return int(float(row['rss_bytes']))


def fresh_sample(service, timeout=1):
    """Require a new sample after entry, not a stale pre-request observation."""
    baseline = sample_rows(service)
    before = int(baseline[-1]['sample']) if baseline else 0
    def check():
        assert service.sampler and service.sampler.poll() is None, 'RSS sampler exited before a fresh post-request sample'
        rows = sample_rows(service)
        if rows and int(rows[-1]['sample']) > before:
            row = rows[-1]
            assert not baseline or float(row['elapsed_seconds']) > float(baseline[-1]['elapsed_seconds']), 'RSS timestamp did not advance'
            return row
        return None
    return until(check, timeout, 'fresh post-request RSS sample', .02)


def resource_check(h, service, profile):
    rows = sample_rows(service)
    h.check(bool(rows), 'real process resource samples recorded')
    h.check(service.sampler is not None and service.sampler.poll() == 0, 'RSS sampler exited successfully')
    indices = [int(row['sample']) for row in rows]
    h.check(indices == list(range(1, len(rows)+1)), 'RSS sample sequence has no missing or reused rows')
    times = [float(row['elapsed_seconds']) for row in rows]
    h.check(all(b > a for a, b in zip(times, times[1:])), 'RSS monotonic timestamps strictly increase')
    peak = max(float(row['rss_bytes']) for row in rows)
    h.check(peak <= profile['rss_budget_bytes'], 'measured frontend/worker/supervisor RSS within profile')
    h.report.setdefault('resources', {})[service.name] = dict(peak_rss_bytes=peak, samples=len(rows),
        sampling_seconds=.1, scope='frontend and descendants tracked by ps creation-time handles; not Metal device allocation')


def sampler_self_test():
    # Harness guard regression only; it neither runs nor passes any G1-G8 gate.
    class Fixture:
        pass
    with tempfile.TemporaryDirectory(prefix='relm-sampler-guard-') as directory:
        service = Fixture(); service.samples = Path(directory) / 'rss.csv'
        service.samples.write_text('sample,elapsed_seconds,rss_bytes,identities\n1,0.1,123,[]\n')
        service.sampler = subprocess.Popen([sys.executable, '-c', 'pass'])
        service.sampler.wait()
        try: fresh_sample(service, .2)
        except AssertionError as error: assert 'sampler exited' in str(error)
        else: raise AssertionError('dead sampler incorrectly passed')
        service.sampler = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'])
        try:
            try: fresh_sample(service, .2)
            except AssertionError as error: assert 'fresh post-request' in str(error)
            else: raise AssertionError('stalled sampler reused stale sample')
        finally:
            service.sampler.terminate(); service.sampler.wait(timeout=3)
    print('PASS: harness-only dead/stalled sampler guards; no service gate executed')


def isolation_suite(h):
    profile = profile_check(h); corpus = development(h)
    config = dict(worker=dict(mode='native'), request_modes=dict(injected_invalid=dict(mode='post_generate_invalid', raw='not JSON')))
    service = h.service('native-isolation', native=True, config=config).ready()
    h.report['native_fault_injection'] = 'One explicitly labelled validator fault replaces output AFTER real generation; engine remains native.'
    outputs = []
    for ident, row in [('A1', corpus[0]), ('B', corpus[1]), ('A2', corpus[0])]:
        outputs.append(service.run_job(dict(row, id=ident)))
    h.check(outputs[0]['raw_output'] == outputs[2]['raw_output'], 'seeded native A/B/A output isolation')
    invalid = service.run_job(dict(corpus[0], id='injected_invalid'))
    h.check(invalid['state'] == 'invalid', 'post-generation invalid JSON retained as invalid accounting')
    overflow = service.run_job(dict(corpus[0], id='context-overflow', text='q ' * 4096))
    h.check(overflow['state'] == 'error', 'actual native context overflow is terminal error')
    h.check('context' in str(overflow.get('error', {}).get('class', '')).lower(), 'native context condition class retained')
    after = service.run_job(dict(corpus[0], id='A3'))
    h.check(after['raw_output'] == outputs[0]['raw_output'], 'native A unchanged after validation/context failures')
    old, start = service.kill_worker(); service.ready(h.limits['recovery_seconds'])
    h.check(service.status()['worker']['epoch'] != old['epoch'], 'native fresh worker after actual SIGKILL')
    after_restart = service.run_job(dict(corpus[0], id='A4'))
    h.check(after_restart['raw_output'] == outputs[0]['raw_output'], 'native A unchanged after hard worker restart')
    service.close(); resource_check(h, service, profile)
    fresh = h.service('native-independent-baseline', native=True).ready()
    baseline = fresh.run_job(dict(corpus[0], id='baseline'))
    h.check(baseline['raw_output'] == outputs[0]['raw_output'], 'independently initialized native worker baseline agrees')
    fresh.close(); resource_check(h, fresh, profile)


def native_suite(h, stress=False):
    profile = profile_check(h); corpus = development(h)
    if stress: h.check(h.args.profile in ('mac_qwen', 'linux_qwen'), '1000-call native stress requires a Qwen profile')
    service = h.service('native-stress' if stress else 'native-30', native=True).ready()
    h.check(time.monotonic()-service.started <= h.limits['worker_start_seconds'], 'native startup within120s')
    original_worker = service.status()['worker']
    count = h.limits['native_stress_requests' if stress else 'normal_sequential_requests']
    outcomes = []; first = {}; last = {}; rss = []
    for i in range(count):
        case = i % len(corpus); row = dict(corpus[case], id=f'native-{i+1:04d}')
        start = time.monotonic(); terminal = service.run_job(row); elapsed = time.monotonic()-start
        h.check(terminal['state'] in ('success', 'invalid'), 'ordinary native call has no infrastructure failure')
        h.check(elapsed <= h.limits['request_deadline_seconds'], 'ordinary native request deadline')
        worker = service.status()['worker']
        h.check((worker['pid'], worker['birth'], worker['epoch']) ==
                (original_worker['pid'], original_worker['birth'], original_worker['epoch']), 'persistent native worker never recycled')
        memory = idle_rss(h, service); rss.append(memory)
        first.setdefault(case, terminal['raw_output']); last[case] = terminal['raw_output']
        outcomes.append(dict(index=i+1, id=row['id'], case=case, state=terminal['state'], elapsed_seconds=elapsed,
                             idle_rss_bytes=memory, worker_pid=worker['pid'], epoch=worker['epoch']))
        if (i+1) % 25 == 0: print(f'{i+1}/{count} actual native requests committed', flush=True)
    with (service.directory / 'native.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, list(outcomes[0])); writer.writeheader(); writer.writerows(outcomes)
    h.check(len(list((service.store / 'results').glob('*.json'))) == count, 'every native admission has exactly one terminal file')
    h.check(first == last, 'native first/last output isolation for each frozen development case')
    if stress:
        h.check(not service.sample_error.exists(), 'no missing process identity samples during stress')
        warm = h.limits['stress_warmup_requests']; tail = h.limits['stress_tail_requests']
        growth = statistics.median(rss[-tail:]) - statistics.median(rss[:warm])
        x = list(range(warm+1, count+1)); y = rss[warm:]
        xmean = statistics.mean(x); ymean = statistics.mean(y)
        slope = sum((a-xmean)*(b-ymean) for a, b in zip(x, y))/sum((a-xmean)**2 for a in x)
        h.check(growth <= h.limits['stress_growth_bytes'], 'tail-minus-warmup RSS within256MiB')
        h.check(slope <= h.limits['stress_slope_bytes_per_request'], 'post-warmup RSS slope within256KiB/request')
        h.report['stress'] = dict(requests=count, growth_bytes=growth, slope_bytes_per_request=slope,
                                states={state: sum(r['state'] == state for r in outcomes) for state in ('success', 'invalid', 'error', 'interrupted')})
    else:
        h.check(service.post(dict(corpus[0], id='controlled-crash'))['status'] == 202, 'native crash fixture admitted')
        killed, start = service.kill_worker(); terminal = service.terminal('controlled-crash')
        h.check(terminal['state'] in h.contract['accepted_terminal_states'], 'controlled native crash remains accounted')
        service.ready(h.limits['recovery_seconds'])
        h.check(service.status()['worker']['epoch'] != killed['epoch'], 'native crash/reload changes epoch')
    service.close(); resource_check(h, service, profile)


def supervisor_suite(h):
    profile_check(h)
    manager = h.args.supervisor
    assert manager in ('launchd', 'systemd-user'), 'G8 requires --supervisor launchd|systemd-user'
    executable = 'launchctl' if manager == 'launchd' else 'systemctl'
    if not shutil.which(executable):
        raise RuntimeError('UNEXECUTED: actual requested service manager is unavailable')
    def run(*command, success=True):
        value = subprocess.run(command, capture_output=True, text=True, timeout=30)
        if success and value.returncode: raise AssertionError('manager command failed: ' + value.stderr)
        return value
    if manager == 'systemd-user' and run('systemctl', '--user', 'show-environment', success=False).returncode:
        raise RuntimeError('UNEXECUTED: systemd user manager cannot execute; unit syntax is not acceptance')
    service = h.service('manager', native=True, start=False)
    name = f'relm-accept-{os.getpid()}'
    unit = service.directory / (name + ('.plist' if manager == 'launchd' else '.service'))
    label = f'gui/{os.getuid()}/{name}'
    installed = False
    def generate(environment):
        run('Rscript', '--vanilla', str(ROOT / 'examples/funding-service/supervisor.R'), '--manager', manager,
            '--name', name, '--environment', environment, '--store', str(service.store), '--port', str(service.port), '--output', str(unit))
    def manager_start():
        nonlocal installed
        if manager == 'launchd': run('launchctl', 'bootstrap', f'gui/{os.getuid()}', str(unit))
        else:
            run('systemctl', '--user', 'link', str(unit))
            run('systemctl', '--user', 'reset-failed', name + '.service', success=False)
            run('systemctl', '--user', 'start', name + '.service')
        installed = True
    def manager_stop():
        if manager == 'launchd': run('launchctl', 'bootout', label, success=False)
        else: run('systemctl', '--user', 'stop', name + '.service', success=False)
    def observation():
        value = run('launchctl', 'print', label, success=False) if manager == 'launchd' else run(
            'systemctl', '--user', 'show', name + '.service', success=False)
        return value.stdout + value.stderr
    def failure_cycle(reason):
        started = time.monotonic(); manager_start(); observations = []; changes = []
        health = []; probe_errors = []; stop_probe = threading.Event()
        def probe():
            while not stop_probe.is_set():
                try:
                    value = service.http('GET', '/health/ready', timeout=1)
                    health.append(dict(elapsed_seconds=time.monotonic()-started, status=value['status']))
                except (OSError, http.client.HTTPException) as error:
                    health.append(dict(elapsed_seconds=time.monotonic()-started, status=None, error=type(error).__name__))
                except Exception as error:
                    probe_errors.append(str(error)); return
                stop_probe.wait(1)
        thread = threading.Thread(target=probe, daemon=True); thread.start()
        last = None; seen_workers = set(); previous_observation = 0
        try:
            while time.monotonic()-started < 17:
                body = observation(); elapsed = time.monotonic()-started
                status = service.status()
                worker = status.get('worker')
                if worker and worker['epoch'] not in seen_workers:
                    for older in service.workers:
                        if older['epoch'] != worker['epoch']:
                            h.check(not h.same_alive(older), 'failed startup never overlaps model-worker identities: ' + reason)
                    seen_workers.add(worker['epoch'])
                # Ignore persisted readiness from a different/dead frontend.
                # A new process may legitimately be running while startup fails.
                pid_match = re.search(r'\bpid = (\d+)', body) if manager == 'launchd' else re.search(r'^MainPID=(\d+)', body, re.M)
                if pid_match and status.get('frontend', {}).get('pid') == int(pid_match[1]):
                    h.check(status.get('state') != 'ready', 'failing current frontend never publishes ready status: ' + reason)
                pattern = r'\bruns = (\d+)' if manager == 'launchd' else r'^NRestarts=(\d+)'
                match = re.search(pattern, body, re.M)
                if match:
                    count = int(match[1]) + (0 if manager == 'launchd' else 1)
                    if count != last:
                        if last is not None:
                            h.check(count == last+1, 'manager failure attempts individually observed: ' + reason)
                        changes.append(dict(elapsed_seconds=elapsed, lower_seconds=previous_observation, attempts=count)); last = count
                observations.append(dict(elapsed_seconds=elapsed, state=body, service=status))
                previous_observation = elapsed
                time.sleep(.25)
        finally:
            stop_probe.set(); thread.join(timeout=3)
        write_json(service.directory / (reason + '-manager-observations.json'), observations)
        write_json(service.directory / (reason + '-readiness-observations.json'), health)
        h.check(not thread.is_alive() and bool(health) and not probe_errors, 'real readiness probes completed without harness errors: ' + reason)
        h.check(all(row['status'] != 200 for row in health), 'failed startup never serves ready HTTP200: ' + reason)
        h.check(len(changes) >= 2, 'actual manager repeatedly attempts failed startup: ' + reason)
        failed = r'last exit code = [1-9]\d*' if manager == 'launchd' else r'(?:^Result=exit-code$|^ExecMainStatus=[1-9]\d*$)'
        h.check(any(re.search(failed, row['state'], re.M) for row in observations), 'manager records actual unsuccessful exits: ' + reason)
        # Each transition lies between its preceding and detecting observations.
        # Use those actual times, including inspection/probe overhead, to expose
        # measurement uncertainty without changing the configured five seconds.
        intervals = []
        for previous, current in zip(changes, changes[1:]):
            interval = dict(lower_seconds=current['lower_seconds']-previous['elapsed_seconds'],
                            upper_seconds=current['elapsed_seconds']-previous['lower_seconds'])
            intervals.append(interval)
            h.check(interval['upper_seconds'] >= 5,
                    'observed restart spacing is compatible with five-second backoff: ' + reason)
        h.report.setdefault('manager_backoff_intervals', {})[reason] = intervals
        manager_stop()
        for identity in service.workers: h.dead(identity)

    try:
        existing = run('launchctl', 'print', label, success=False) if manager == 'launchd' else run('systemctl', '--user', 'cat', name + '.service', success=False)
        h.check(existing.returncode != 0, 'disposable manager name does not replace existing user service')
        generate(service.environment); manager_start()
        service.ready(h.limits['worker_start_seconds']); original = service.status()
        first = original['frontend']; worker = original['worker']
        os.kill(first['pid'], signal.SIGKILL); h.dead(worker)
        until(lambda: service.status().get('frontend', {}).get('pid') != first['pid'], h.limits['recovery_seconds'], 'actual manager restart')
        service.ready(h.limits['recovery_seconds'])
        h.check(service.status()['worker']['epoch'] != worker['epoch'], 'manager restart creates no overlapping model owner')

        # Exercise the actual operator stop path against a separate live process.
        # An invented owner file cannot authorize an OS signal to that process.
        victim = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        try:
            identity = h.inspect([dict(pid=victim.pid)])[0]
            fake = service.directory / 'unowned-store'; (fake / 'store.lock').mkdir(parents=True, mode=0o700)
            owner = dict(read_json(service.store / 'store.lock/owner.json'), nonce='e'*32,
                         frontend=dict(pid=victim.pid, birth=f"{float(identity['birth']):.6f}"), worker=None)
            write_json(fake / 'store.lock/owner.json', owner)
            command = ['Rscript', '--vanilla', str(ROOT / 'examples/funding-service/stop.R'),
                       '--environment', service.environment, '--store', str(fake)]
            refused = run(*command, success=False)
            h.check(refused.returncode != 0 and victim.poll() is None, 'unowned live PID is never signalled by operator stop')
            owner['frontend']['birth'] = f"{float(identity['birth'])-100:.6f}"
            write_json(fake / 'store.lock/owner.json', owner)
            run(*command, success=False)
            h.check(victim.poll() is None, 'PID reused with different birth is never stopped')
            h.check(service.http('GET', '/health/ready')['status'] == 200, 'unowned stop cannot disturb manager-owned service')
        finally:
            victim.terminate(); victim.wait(timeout=3)
        current = service.status(); begin = time.monotonic(); manager_stop()
        h.dead(current['frontend'], h.limits['stop_seconds']); h.dead(current['worker'])
        h.check(time.monotonic()-begin <= h.limits['stop_seconds'], 'actual manager ordinary stop within15s')
        with socket.socket() as occupied:
            occupied.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            occupied.bind(('127.0.0.1', service.port)); occupied.listen()
            failure_cycle('occupied-port')

        # Hard links keep the prepared package snapshot bounded; only config is
        # replaced with independent bytes. The supplied environment is untouched.
        changed = service.directory / 'changed-environment'
        shutil.copytree(service.environment, changed, copy_function=os.link)
        config = changed / 'config.json'; original = config.read_bytes(); config.unlink(); config.write_bytes(original+b' ')
        unit.unlink(); generate(str(changed))
        if manager == 'systemd-user': run('systemctl', '--user', 'daemon-reload')
        failure_cycle('changed-configuration')
        h.check(Path(service.environment, 'config.json').read_bytes() == original, 'original prepared environment remains unchanged')
    finally:
        if installed:
            manager_stop()
            if manager == 'systemd-user':
                run('systemctl', '--user', 'disable', name + '.service', success=False)
                run('systemctl', '--user', 'reset-failed', name + '.service', success=False)
                run('systemctl', '--user', 'daemon-reload', success=False)
        for worker in service.workers: h.dead(worker)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=[*GATES, 'deterministic'])
    parser.add_argument('--self-test', action='store_true', help='test harness failure guards only; not a service gate')
    parser.add_argument('--contract', default=str(ROOT / 'tests/service-contract/contract.json'))
    parser.add_argument('--source-library')
    parser.add_argument('--environment')
    parser.add_argument('--profile', choices=['mac_spark', 'mac_qwen', 'linux_qwen'])
    parser.add_argument('--supervisor', choices=['launchd', 'systemd-user'])
    parser.add_argument('--work-dir')
    parser.add_argument('--default-deadline', action='store_true', help='run required unchanged120s real-child deadline in G3')
    args = parser.parse_args(); os.umask(0o077)
    if args.self_test:
        sampler_self_test()
        return 0
    if not args.suite or not args.work_dir: parser.error('--suite and --work-dir are required for runtime acceptance')
    offline_evidence = ensure_offline() if args.suite == 'native' else None
    harness = Harness(args)
    if offline_evidence: harness.report['offline_isolation'] = offline_evidence
    suites = ['http', 'admission', 'recovery', 'persistence'] if args.suite == 'deterministic' else [args.suite]
    functions = dict(http=http_suite, admission=admission_suite, recovery=recovery_suite, persistence=persistence_suite,
                     isolation=isolation_suite, native=native_suite, stress=lambda h: native_suite(h, stress=True), supervisor=supervisor_suite)
    try:
        for suite in suites:
            print('Running actual runtime gate ' + GATES[suite] + ' (' + suite + ')', flush=True)
            start = time.monotonic(); functions[suite](harness)
            harness.report['gates'][GATES[suite]] = dict(status='passed', elapsed_seconds=time.monotonic()-start)
        harness.report['status'] = 'passed'
        if harness.report.get('unexecuted'):
            harness.report['status'] = 'partial'
            harness.report['gates']['G3']['status'] = 'partial'
    except Exception as error:
        harness.report['status'] = 'unexecuted' if str(error).startswith('UNEXECUTED') else 'failed'
        harness.report['error'] = f'{type(error).__name__}: {error}'
        print(harness.report['error'], file=sys.stderr)
    finally:
        harness.finish()
    print(json.dumps(dict(status=harness.report['status'], checks=len(harness.checks), report=str(harness.work / 'acceptance.json'))))
    return 0 if harness.report['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
