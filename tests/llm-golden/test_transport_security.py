"""Bounded offline regressions for the three urllib3 advisories (D-057).

No external sockets, model calls, or reference generation. The former looping
case is bounded by iteration count and the oversized input by 65538 bytes.
"""
import http.client
import io
import ssl
import unittest
import zlib
from types import SimpleNamespace
from unittest.mock import patch

from urllib3.connection import HTTPSConnection
from urllib3.response import DeflateDecoder, HTTPResponse
from urllib3.exceptions import ProtocolError
from urllib3._base_connection import ProxyConfig
from urllib3.util import Url


class TransportSecurity(unittest.TestCase):
    def test_deflate_eof_does_not_leave_endless_tail(self):
        decoder = DeflateDecoder()
        expected = b"bounded-deflate-fixture"
        actual = decoder.decompress(zlib.compress(expected) + b"trailing", max_length=1)
        for _ in range(64):
            if not decoder.has_unconsumed_tail:
                break
            actual += decoder.decompress(b"", max_length=1)
        self.assertEqual(actual, expected)
        self.assertFalse(decoder.has_unconsumed_tail)

    def test_chunk_header_read_is_bounded(self):
        class TrackedStream(io.BytesIO):
            sizes = []
            def readline(self, size=-1):
                self.sizes.append(size)
                return super().readline(size)
        stream = TrackedStream(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + b"f" * 65537 + b"\n")
        raw = http.client.HTTPResponse(SimpleNamespace(makefile=lambda mode: stream))
        raw.begin()
        stream.sizes.clear()
        response = HTTPResponse(body=raw, headers=dict(raw.headers.items()), preload_content=False)
        with self.assertRaises(ProtocolError):
            list(response.stream(amt=1))
        self.assertTrue(stream.sizes)
        self.assertTrue(all(0 < n <= 65537 for n in stream.sizes), stream.sizes)

    def test_proxy_keeps_its_own_tls_verification_policy(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        proxy = ProxyConfig(context, False, "proxy.example", None)
        connection = HTTPSConnection("target.example", cert_reqs=ssl.CERT_NONE,
                                     proxy=Url(scheme="https", host="proxy.example"),
                                     proxy_config=proxy)
        with patch("urllib3.connection._ssl_wrap_socket_and_match_hostname",
                   return_value=SimpleNamespace(socket=object(), is_verified=True)) as wrap:
            connection._connect_tls_proxy("proxy.example", object())
        self.assertIs(wrap.call_args.kwargs["ssl_context"], context)
        self.assertEqual(wrap.call_args.kwargs["cert_reqs"], ssl.CERT_REQUIRED)
        self.assertEqual(wrap.call_args.kwargs["server_hostname"], "proxy.example")
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)


if __name__ == "__main__":
    unittest.main()
