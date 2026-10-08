#!/usr/bin/env python3
"""Only new affected-selection/marker controls; no native process or model."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('review_memory', Path(__file__).with_name('instrumented_review.py'))
R = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(R)
SOURCE = 'frozen-source'


def events(marker=None):
    return [{'type':'suite','event':'started','test_count':1},
            {'type':'test','event':'started','name':R.ZERO_ID},
            {'type':'test','event':'ok','name':R.ZERO_ID,
             'stdout':R.MARKER + json.dumps(R.expected_zero(SOURCE) if marker is None else marker)+'\n'},
            {'type':'suite','event':'ok','passed':1,'failed':0,'ignored':0}]


def encoded(rows):
    return '\n'.join(json.dumps(row) for row in rows)


class Controls(unittest.TestCase):
    def test_bound_positive(self):
        self.assertEqual(R.collect_zero(encoded(events()), '', SOURCE)['compared_values'],224)

    def test_only_affected_names(self):
        self.assertEqual(R.selected('sanitizers'),[R.ZERO_ID])
        self.assertEqual(R.selected('valgrind'),[R.P.CASES['rebirth_llm']['id'],R.ZERO_ID])
        with self.assertRaises(RuntimeError): R.selected('full')

    def test_marker_mutations_refused(self):
        changes={'executed_cases':7,'rejected_cases':1,'compared_values':223,'zero_rows':1,
                 'zero_read_bytes':128,'zero_write_bytes':128,'zero_barriers':1,
                 'audit_rows':0,'refused_deliveries':1,'source':'different','model_loads':True,
                 'max_abs_error':0,'extra':'invented'}
        for key,value in changes.items():
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                marker=R.expected_zero(SOURCE);marker[key]=value
                R.collect_zero(encoded(events(marker)),'',SOURCE)

    def test_structural_mutations_refused(self):
        rows=[]
        x=events();x[0]['test_count']=0;rows.append(x)
        x=events();x[2]['event']='ignored';rows.append(x)
        x=events();x[2]['name']='different';rows.append(x)
        x=events();x[2]['stdout']*=2;rows.append(x)
        x=events();del x[2]['stdout'];rows.append(x)
        x=events();x.insert(3,copy.deepcopy(x[2]));rows.append(x)
        for i,x in enumerate(rows):
            with self.subTest(i=i), self.assertRaises(RuntimeError):R.collect_zero(encoded(x),'',SOURCE)

    def test_actual_finding_refused(self):
        with self.assertRaises(RuntimeError):
            R.collect_zero(encoded(events()),'ERROR: AddressSanitizer: heap-use-after-free',SOURCE)


if __name__=='__main__':
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Controls))
    if not result.wasSuccessful() or result.testsRun!=5:raise SystemExit(1)
    print('F6E_REVIEW_MEMORY_CONTROLS {"methods":5,"marker_negatives":13,"structural_negatives":6,"models":0}')
