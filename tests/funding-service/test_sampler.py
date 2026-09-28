"""Model-free sampler regressions; run in R-CMD-check and native acceptance."""
import csv
import io
from pathlib import Path
import tempfile
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


if __name__ == '__main__':
    unittest.main()
