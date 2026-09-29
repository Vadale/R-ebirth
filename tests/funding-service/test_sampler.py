"""Model-free sampler regressions; run in R-CMD-check and native acceptance."""
import csv
import io
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import threading
import unittest
from unittest.mock import Mock, patch

from accept import Service, fresh_sample, latest_sample


class SamplerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='relm-sampler-test-')
        self.addCleanup(self.directory.cleanup)
        self.service = Service.__new__(Service)
        self.service.samples = Path(self.directory.name) / 'rss.csv'
        self.service.sample_error = Path(self.directory.name) / 'rss.error'
        self.service.sampler = Mock()
        self.service.sampler.poll.return_value = None
        self.service.require_complete_samples = True
        self.header = 'sample,elapsed_seconds,rss_bytes,identities\n'
        self.service.samples.write_text(self.header + '1,0.1,123,[]\n')

    def test_complete_rows_match_csv_and_partial_tail_is_ignored(self):
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(['sample', 'elapsed_seconds', 'rss_bytes', 'identities'])
        writer.writerow([1, .1, 123, '[{"pid":42,"birth":12.5}]'])
        complete = output.getvalue()
        for suffix in ('', '2,0.2,456,"[{', '2,0.2,456,"' + 'x' * 20000):
            self.service.samples.write_text(complete + suffix)
            self.assertEqual(latest_sample(self.service), list(csv.DictReader(io.StringIO(complete)))[-1])

    def test_empty_header_only_and_malformed_completed_rows(self):
        for text in ('', self.header, self.header + '1,0.1'):
            self.service.samples.write_text(text)
            self.assertIsNone(latest_sample(self.service))
        self.service.samples.write_text(self.header + '1,0.1\n')
        with self.assertRaisesRegex(AssertionError, 'incomplete RSS sample'):
            latest_sample(self.service)

    def test_history_read_cost_is_bounded_by_tail(self):
        self.service.samples.write_text(self.header + '1,0.1,123,[]\n' * 100000 + '2,0.2,456,[]\n')
        with self.service.samples.open('rb') as stream:
            reader = Mock(wraps=stream)
            with patch.object(Path, 'open') as opener:
                opener.return_value.__enter__.return_value = reader
                self.assertEqual(latest_sample(self.service)['sample'], '2')
            self.assertEqual(reader.read.call_count, 1)
            self.assertEqual(reader.read.call_args.args, (8192,))

    def test_fresh_sample_waits_for_completed_new_row(self):
        def append():
            with self.service.samples.open('a') as stream:
                stream.write('2,0.2,456,[]\n')
        timer = threading.Timer(.05, append)
        timer.start()
        try:
            self.assertEqual(fresh_sample(self.service, 1)['sample'], '2')
        finally:
            timer.join()

    def test_failed_sampling_stops_before_another_http_request(self):
        self.service.sample_error.write_text('missed an entire100ms sampling period')
        with patch('accept.http.client.HTTPConnection') as connection:
            with self.assertRaisesRegex(AssertionError, 'stress RSS sampling failed'):
                self.service.http('POST', '/v1/extractions', {'id': 'must-not-dispatch'})
            connection.assert_not_called()
        with self.assertRaisesRegex(AssertionError, 'stress RSS sampling failed'):
            fresh_sample(self.service, 1)

    def test_dead_sampler_stops_before_another_http_request(self):
        self.service.sampler.poll.return_value = 1
        with patch('accept.http.client.HTTPConnection') as connection:
            with self.assertRaisesRegex(AssertionError, 'sampler exited'):
                self.service.http('GET', '/health/ready')
            connection.assert_not_called()

    def test_launcher_preserves_identity_uid_and_default_priority(self):
        metadata = Path(self.directory.name) / 'launcher.json'
        environment = os.environ.copy(); environment.pop('RELM_SAMPLER_NICE', None)
        before = os.getpriority(os.PRIO_PROCESS, 0)
        child = subprocess.run([sys.executable, str(Path(__file__).with_name('sampler_launcher.py')),
                                str(metadata), sys.executable, '-c',
                                'import json,os; print(json.dumps([os.getpid(),os.geteuid(),os.getpriority(os.PRIO_PROCESS,0)]))'],
                               env=environment, capture_output=True, text=True, check=True)
        recorded = json.loads(metadata.read_text())
        self.assertEqual(json.loads(child.stdout), [recorded['pid'], os.geteuid(), before])
        self.assertEqual(recorded['actual_nice'], before)
        self.assertEqual(os.getpriority(os.PRIO_PROCESS, 0), before)

    def test_launcher_rejects_invalid_priority_before_exec(self):
        metadata = Path(self.directory.name) / 'invalid-launcher.json'
        environment = dict(os.environ, RELM_SAMPLER_NICE='-20')
        child = subprocess.run([sys.executable, str(Path(__file__).with_name('sampler_launcher.py')),
                                str(metadata), sys.executable, '-c', 'print("MUST_NOT_EXECUTE")'],
                               env=environment, capture_output=True, text=True)
        self.assertNotEqual(child.returncode, 0)
        self.assertNotIn('MUST_NOT_EXECUTE', child.stdout)
        self.assertFalse(metadata.exists())

    def test_manager_readiness_checks_status_identities_without_popen(self):
        service = self.service
        service.process = None; service.sampler = None; service.name = 'manager'
        service.h = Mock(); service.h.report = {}; service.h.limits = {'worker_start_seconds': 2}
        status = {'frontend': {'pid': 123, 'birth': 1.0}, 'worker': {'pid': 456, 'birth': 2.0}}
        service.status = Mock(return_value=status); service.http = Mock(return_value={'status': 200})
        service.h.inspect.return_value = [dict(x, alive=True) for x in status.values()]
        with patch.dict(os.environ, RELM_SAMPLER_NICE='-10'), patch('accept.sys.platform', 'linux'), \
                patch('accept.os.getpriority', return_value=0) as priority:
            self.assertIs(service.ready(), service)
            self.assertEqual([call.args[1] for call in priority.call_args_list], [os.getpid(), 123, 456])
            self.assertIsNone(service.h.report['scheduling']['manager'][0]['observer'])
            priority.side_effect = [0, 0, -10]
            with self.assertRaisesRegex(AssertionError, 'workload priority must remain normal'):
                service.ready()
            service.h.inspect.return_value[1]['birth'] = 99.0
            with self.assertRaisesRegex(AssertionError, 'current frontend and worker identities'):
                service.ready()


if __name__ == '__main__':
    unittest.main()
