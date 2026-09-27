#!/usr/bin/env python3
"""Verify recorded D1 bytes and scores; Rust CI golden job, no model or R."""
import importlib.util
import hashlib
import json
from pathlib import Path
import sys

if not __debug__:
 raise SystemExit("Python -O disables fixture assertions")
root=Path(__file__).resolve().parent
sys.path.insert(0,str(root))
import verify
spec=importlib.util.spec_from_file_location('profile',root/'run-model.py')
profile=importlib.util.module_from_spec(spec);spec.loader.exec_module(profile)
base=root/'measurements/d1-macos-metal-2026-09-27'
cases=verify.loads((root/'cases.json').read_text())
checked=0
reports=sorted(base.glob("*/report.json"))
assert reports, "Missing D1 reports"
for path in reports:
 report=verify.loads(path.read_text()); selected=[c for c in cases if c['split']==report['config']['split']]
 assert hashlib.sha256((path.parent/'prompt-template.txt').read_bytes()).hexdigest()==report['config']['identity']['template_sha256']
 for mode,recorded in report['runs'].items():
  rows=[verify.loads(line) for line in (path.parent/(mode+'.jsonl')).read_text().splitlines()]
  assert verify.evaluate(selected,rows)==recorded['metrics'], (path,mode,'metrics')
  valid=sum(profile.check_schema_output(row['output'])['valid'] for row in rows if row['status']=='success')
  assert valid==recorded['schema_valid_records'], (path,mode,'schema')
  diagnostics={r['id']:r for r in recorded['diagnostics']}
  for row in rows:
   if row['status']=='success':
    assert hashlib.sha256(row['output'].encode('utf-8')).hexdigest()==diagnostics[row['id']]['output_sha256'], (path,mode,row['id'])
  checked+=len(rows)
print(f'Archived reports match {checked} exact raw predictions and frozen scores.')
