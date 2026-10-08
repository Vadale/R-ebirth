import hashlib,json,re,shutil,tarfile
from pathlib import Path
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');P=Path('/private/tmp/relm-f6e/review-fix-20261008-143824')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
s=json.loads((P/'status.json').read_text());m=json.loads((P/'source-manifest.json').read_text());assert s['status']=='failed' and not s['source_drift']
assert sha(P/'source-manifest.json')==s['source_manifest_sha256']
with tarfile.open(P/'changed-source.tar.gz') as t:
 frozen={x.name:t.extractfile(x).read() for x in t.getmembers() if x.isfile()}
for path,h in m.items():
 data=frozen.get(path,(R/path).read_bytes())
 assert hashlib.sha256(data).hexdigest()==h,path
names=['format','clippy-default','clippy-private','no-spill-default','no-spill-private','native-1'];assert [x['name'] for x in s['stages']]==names
for i,row in enumerate(s['stages']):
 log=P/(row['name']+'.log');assert sha(log)==row['log_sha256']
 assert row['exit_code']==(101 if i==5 else 0)
 assert not re.search(r'^(?:warning(?:\[|:)|ld: warning:)',log.read_text(),re.M)
log=(P/'native-1.log').read_text();assert 'left: 2\n right: 1' in log and 'projection_review_tests.rs:117:17' in log
assert 'test result: FAILED. 0 passed; 1 failed; 0 ignored' in log and 'F6E_PROJECTION_REVIEW_TEST ' not in log
assert not (P/'native-2.log').exists() and not (P/'binary-bindings.json').exists()
source=(R/'rebirth/src/rust/rebirth-llm/src/live_capture.rs').read_text();assert 'copies: state.copies,' in source and 'state.copies += 1;' in source
advance=source.split('pub(crate) fn advance(',1)[1].split('pub(crate) fn ',1)[0];assert not re.search(r'state[.]cop(?:ies|ied_bytes)\s*=',advance)
report={'status':'failed_execution_preserved','original_pid':95151,'verified_source_hashes':len(m),'verified_stage_logs':6,'passed_preparatory_stages':names[:5],'native_test_status':'FAILED; no complete native cases or final marker accepted','failure':'Second live state compares cumulative copies2 with erroneous per-state expected1. Capture counters initialize once and accumulate. Product counter semantics unchanged. Correct test expectations; preserve zero projection stats and all numerical assertions.','native_2_and_fresh_dll_profile':'unexecuted','compiler_linker_warnings':0,'model_replay':False,'scope':'Raw failure/source inspection only; no compilation/model/test rerun'}
(P/'owner-failure-verification.json').write_text(json.dumps(report,indent=2)+'\n')
A=R/'tests/projection/measurements/review-fix-20261008-143824';assert not A.exists();shutil.copytree(P,A)
shutil.copy2('/private/tmp/relm-f6e/verify-review-fix-failure.py',A/'verify-review-fix-failure.py')
(A/'manifest.json').write_text(json.dumps({str(p.relative_to(A)):sha(p) for p in A.rglob('*') if p.is_file()},indent=2)+'\n')
print(json.dumps({'status':report['status'],'source_hashes':len(m),'passed_stages':5,'failed_native_tests':1,'manifest_sha256':sha(A/'manifest.json')}))
