#!/usr/bin/env python3
"""Focused controls for new producer/collector transport and CPU proof."""
import csv
import importlib.util
import json
from pathlib import Path
import struct
import sys
import unittest
import collect_run as c

class CollectorControls(unittest.TestCase):
    def test_cpu_positive_and_rejections(self):
        raw=b'[2] load: offloaded 0/25 layers to GPU\n[2] load: CPU_Mapped model buffer size = 507.00 MiB\n[2] cache: CPU KV buffer size = 12.00 MiB\n[2] ctx: CPU compute buffer size = 22.00 MiB\n'
        self.assertEqual(c.cpu_receipt(raw)['n_gpu_layers'],0)
        for bad in (raw.replace(b'0/25',b'1/25'),raw.replace(b'0/25',b'0/24'),
                    raw.replace(b'CPU compute',b'Metal compute'),raw.replace(b'CPU_Mapped',b'MTL0'),
                    raw.replace(b'compute buffer',b'other buffer'),raw+b'[3] retained warning\n',
                    raw+b'[4] retained error\n',raw+raw):
            with self.subTest(bad=bad),self.assertRaises(ValueError):c.cpu_receipt(bad)
    def test_actual_r_serialization(self):
        root=Path(sys.argv_bundle)
        nodes=[c.decode_node(x) for x in json.loads((root/'typed.json').read_text())]
        expected=[['N',None],['L',True],['I',2],['D',-0.0],['S','è 🚀'],['i',[1,2]],
                  ['d',[.1,-0.0]],['s',['x','y']],['F',[['a',['i',[1,2]]],['b',['d',[.5,-.25]]]]],
                  ['R',[['neuron',['i',[1]]],['value',['d',[.2]]]]],
                  ['M',[2,2,['a','b'],['1','2'],[.5,2.,-0.,3.]]]]
        self.assertEqual(nodes,expected)
        for a,b in zip(nodes,expected):self.assertEqual(b''.join(c.reference.encode(a)),b''.join(c.reference.encode(b)))
        self.assertEqual(struct.pack('<d',nodes[3][1]),struct.pack('<d',-0.0))
        self.assertEqual((root/'text.txt').read_bytes(),'è\n'.encode())
        with (root/'transport.csv').open(newline='') as stream: rows=list(csv.DictReader(stream))
        self.assertEqual(rows,[dict(x='a\nb',y='',z='TRUE'),dict(x='è,"x"',y='1',z='FALSE'),dict(x='NA',y='2',z='')])
    def test_setting_routes(self):
        rows=json.loads((Path(sys.argv_bundle)/'settings.json').read_text());self.assertEqual(len(rows),14)
        for row in rows:
            self.assertEqual((row['operator'],row['coefficient'],row['artifact']),c.v.setting_spec(row['setting'],dict(add=-1,project=.5)))

if __name__=='__main__':
    sys.argv_bundle=sys.argv.pop(1);unittest.main(verbosity=2)
