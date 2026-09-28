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
candidate_path=base/'candidate.json'
candidate=verify.loads(candidate_path.read_text())
canonical=lambda value: json.dumps(value,sort_keys=True,ensure_ascii=True,separators=(',', ':'),allow_nan=False).encode()
assert hashlib.sha256(canonical(candidate['identity'])).hexdigest()==candidate['identity_sha256']
assert hashlib.sha256((base/'development-final/report.json').read_bytes()).hexdigest()==candidate['development_report_sha256']
assert (base/'held-out/report.json').is_file(), 'Missing held-out result'
checked=0
reports=sorted(base.glob("*/report.json"))
assert reports, "Missing D1 reports"
for path in reports:
 report=verify.loads(path.read_text()); selected=[c for c in cases if c['split']==report['config']['split']]
 if report['config']['split']=='held_out':
  assert report['config']['identity']==candidate['identity']
  assert report['config']['candidate_sha256']==hashlib.sha256(candidate_path.read_bytes()).hexdigest()
  assert candidate['frozen_utc']<report['config']['created_utc']
  metrics=report['runs']['structured']['metrics']
  gate={'no_failed_or_invalid': metrics['failed_or_invalid']==0,
        'record_accuracy_at_least_0_8': metrics['record_accuracy']>=0.8,
        'known_amount_accuracy_at_least_0_9': metrics['known_amount_accuracy'] is not None and metrics['known_amount_accuracy']>=0.9,
        'unsupported_nonmissing_rate_at_most_0_05': metrics['unsupported_nonmissing_rate'] is not None and metrics['unsupported_nonmissing_rate']<=0.05}
  assert gate==report['held_out_gate']
  assert report['held_out_gate_passed']==(all(gate.values()) and report['execution_complete'])
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
  for diagnostic in diagnostics.values():
   if 'partial_file' in diagnostic:
    partial=path.parent/mode/diagnostic['partial_file']
    assert hashlib.sha256(partial.read_bytes()).hexdigest()==diagnostic['partial_sha256']
  checked+=len(rows)
audit=verify.loads((base/'semantic-review.json').read_text())
assert audit['original_report_sha256']==hashlib.sha256((base/'held-out/report.json').read_bytes()).hexdigest()
held_cases={c['id']:c for c in cases if c['split']=='held_out'}
assert len(audit['records'])==2*len(held_cases)
assert {(r['mode'],r['id']) for r in audit['records']}=={(m,i) for m in ('unconstrained','structured') for i in held_cases}
for mode in ('unconstrained','structured'):
 originals={r['id']:r['output'] for r in map(verify.loads,(base/'held-out'/(mode+'.jsonl')).read_text().splitlines())}
 for reviewed in (r for r in audit['records'] if r['mode']==mode):
  assert hashlib.sha256(originals[reviewed['id']].encode()).hexdigest()==reviewed['original_output_sha256']
  proposed=json.dumps(reviewed['proposed_output'],ensure_ascii=False)
  assert profile.check_task_output(proposed,held_cases[reviewed['id']]['text'])['valid']
  assert reviewed['human_review_seconds'] is None and reviewed['human_correction_seconds'] is None
print(f'Archived reports match {checked} exact raw predictions and frozen scores; source-review proposals remain separate.')
