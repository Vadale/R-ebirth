import csv,hashlib,json,shutil
from pathlib import Path
root=Path('/private/tmp/relm-f6e'); repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
run=root/'public-application-source-20261008-040358'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=json.loads((run/'source-manifest.json').read_text()); assert len(m)==18
for p,h in m.items(): assert sha(run/'sources'/p)==h and sha(repo/p)==h, p
s=json.loads((run/'status.json').read_text()); assert s['status']=='awaiting_owner_verification' and s['exit_code']==0 and s['source_drift']==[]
assert sha(run/'r-source.log')==s['log_sha256']=='0598ef8715dd3cd92dab49333bfcaffa6ab5ebdaf13d7c0f5f191d5e9a840888'
rows=list(csv.DictReader((run/'results.csv').open()))
names=[
'direction operators are exact plain strings before artifact work',
'projection application routes validated first and last component sites',
'operator mismatch tampering and foreign provenance precede derivation',
'projection coefficients retain zero and reject hidden or non-f32 values',
'additive application preserves old dispatch and charges new artifact on projected source',
'ordinary residual derivation preserves the recorded projection admission',
'projection image requests and live projection revisions refuse without execution',
'explicit direction inheritance uses a new combined budget and production preflight',
'projection responses bind every term and actual model fact before derivation']
counts=[9,20,5,8,6,8,5,5,31]
assert [r['test'] for r in rows]==names
assert [int(r['passed']) for r in rows]==counts and sum(counts)==97
for r,c in zip(rows,counts):
 assert int(r['nb'])==c and r['failed']=='0' and r['skipped']=='FALSE' and r['error']=='FALSE' and r['warning']=='0'
log=(run/'r-source.log').read_text(); assert log.count('F6E_PUBLIC_APPLICATION_R_SOURCE cases=9 expectations=97 failures=0 errors=0 skips=0 warnings=0 native=0 models=0')==1
assert 'package ‘testthat’ was built under R version 4.5.2' in log
assert 'Failure' not in log and 'Error' not in log
result={'status':'PASS','scope':'Source-only exact R implementation and boundary doubles; not installed, native, model or UI acceptance.','cases':9,'expectations':97,'new_cases':8,'new_expectations':66,'affected_existing_response_expectations':31,'failed':0,'error':0,'skipped':0,'test_warnings':0,'external_warning':'testthat built under R 4.5.2','source_count':len(m),'source_manifest_sha256':sha(run/'source-manifest.json'),'raw_log_sha256':sha(run/'r-source.log'),'results_csv_sha256':sha(run/'results.csv'),'source_drift':[],'native_calls':0,'model_calls':0,'driver_status_preserved':s['status']}
(run/'owner-verification.json').write_text(json.dumps(result,indent=2)+'\n')
shutil.copy2(__file__,run/'verify-public-application-source-owner.py')
dest=repo/'tests/projection/measurements'/run.name
assert not dest.exists()
shutil.copytree(run,dest)
files={str(p.relative_to(dest)):sha(p) for p in sorted(dest.rglob('*')) if p.is_file()}
(dest/'archive-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print(json.dumps(result)); print('Archived',len(files),'files at',dest)
