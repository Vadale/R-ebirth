#!/usr/bin/env python3
"""Bounded, model-free sampler timing diagnosis. Never certifies a service gate."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent


def host_counters():
    membership = Path('/proc/self/cgroup')
    result = {'cgroup_membership': membership.read_text() if membership.is_file() else None,
              'cgroups': {}}
    root = Path('/sys/fs/cgroup')
    current = root
    for line in (result['cgroup_membership'] or '').splitlines():
        if line.startswith('0::'):
            candidate = root / line[3:].lstrip('/')
            if candidate.is_dir(): current = candidate
    while current == root or root in current.parents:
        result['cgroups'][str(current)] = {
            name: (current / name).read_text() if (current / name).is_file() else None
            for name in ('cpu.stat', 'cpu.max', 'cpu.pressure')}
        if current == root: break
        current = current.parent
    result['loadavg'] = list(os.getloadavg())
    return result


def load_worker(count):
    # hashlib releases the GIL for this buffer: threads compete for CPU without
    # downloading a model or changing the process tree on every iteration.
    payload = b'x' * (1024 * 1024)
    def busy():
        while True:
            hashlib.sha256(payload).digest()
    threads = [threading.Thread(target=busy, daemon=True) for _ in range(count)]
    for thread in threads: thread.start()
    threads[0].join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library')
    parser.add_argument('--work-dir')
    parser.add_argument('--seconds', type=float, default=1800)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--load-worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not 1 <= args.threads <= 8 or not 0 < args.seconds <= 1800:
        parser.error('use 1–8 threads and a duration in (0, 1800] seconds')
    if args.load_worker:
        load_worker(args.threads)
        return 0
    if not args.library or not args.work_dir: parser.error('--library and --work-dir are required')
    os.umask(0o077)
    directory = Path(args.work_dir).resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = dict(scope='Timing diagnosis only; no model, HTTP service or G1–G8 acceptance.',
                  status='running', os=platform.platform(), duration_limit_seconds=args.seconds,
                  busy_threads=args.threads, cpu_count=os.cpu_count(),
                  affinity=sorted(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else None,
                  host_before=host_counters(),
                  sources={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in (Path(__file__), HERE / 'processes.R')})
    worker = None; sampler = None
    error_path = directory / 'rss.error'; stop_path = directory / 'sampler.stop'
    started = time.monotonic()
    try:
        with (directory / 'sampler.log').open('wb') as log, (directory / 'host.csv').open('w', newline='') as host:
            worker = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--load-worker',
                                       '--threads', str(args.threads)])
            environment = os.environ.copy()
            environment['RELM_SAMPLER_DIAGNOSTICS'] = str(directory / 'timings.csv')
            sampler = subprocess.Popen(['Rscript', '--vanilla', str(HERE / 'processes.R'),
                                        str(Path(args.library).resolve()), 'sample', str(worker.pid),
                                        str(directory / 'rss.csv'), str(stop_path), str(error_path)],
                                       env=environment, stdout=log, stderr=subprocess.STDOUT)
            writer = csv.writer(host); writer.writerow(['elapsed_seconds', 'counters'])
            while time.monotonic() - started < args.seconds:
                writer.writerow([time.monotonic() - started, json.dumps(host_counters())]); host.flush()
                if worker.poll() is not None: raise RuntimeError('controlled CPU worker exited unexpectedly')
                if sampler.poll() is not None: raise RuntimeError('RSS sampler exited unexpectedly')
                if error_path.exists():
                    report['status'] = 'sampling_failed'
                    report['sampling_error'] = error_path.read_text()
                    break
                time.sleep(min(1, max(0, args.seconds - (time.monotonic() - started))))
            else:
                report['status'] = 'completed_without_reproducing_gap'
            # Stop the observer while the controlled workload remains alive;
            # this diagnostic measures timing, not operator-shutdown behavior.
            stop_path.touch(); sampler.wait(timeout=5)
            if sampler.returncode: raise RuntimeError('RSS sampler failed at diagnostic stop')
            report['measurement_rows'] = {}
            for name, required in [('rss.csv', {'sample', 'rss_bytes', 'identities'}),
                                   ('timings.csv', {'sample', 'gc_elapsed_seconds', 'interval_cpu_seconds'})]:
                with (directory / name).open() as stream:
                    rows = csv.DictReader(stream)
                    if not required.issubset(rows.fieldnames or []):
                        raise RuntimeError('Missing measurement fields: ' + name)
                    count = sum(1 for _ in rows)
                if not count: raise RuntimeError('No measurement rows: ' + name)
                report['measurement_rows'][name] = count
            if error_path.exists():
                report['status'] = 'sampling_failed'; report['sampling_error'] = error_path.read_text()
    except Exception as error:
        report['status'] = 'diagnostic_error'; report['error'] = str(error)
    finally:
        stop_path.touch()
        for process in (sampler, worker):
            if process and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
        report['elapsed_seconds'] = time.monotonic() - started
        report['host_after'] = host_counters()
        (directory / 'diagnostic.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    return 1 if report['status'] == 'diagnostic_error' else 0


if __name__ == '__main__':
    sys.exit(main())
