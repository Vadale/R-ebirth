import json,hashlib,tarfile,re,shutil
from pathlib import Path
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');run=Path('/private/tmp/relm-f6e/combined-binding-20261008-031008');sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
s=json.loads((run/'status.json').read_text());m=json.loads((run/'source-manifest.json').read_text())
assert s['status']=='failed' and s['stage']=='native-bridge-frame' and s['source_drift']==[]
assert len(m)==112 and sha(run/'source-manifest.json')==s['source_manifest_sha256']
assert all(sha(repo/p)==h for p,h in m.items())
with tarfile.open(run/'changed-source.tar.gz') as tar:
 members=[x for x in tar.getmembers() if x.isfile()]
 for x in members:assert hashlib.sha256(tar.extractfile(x).read()).hexdigest()==m[x.name]
assert len(s['stages'])==6
for row in s['stages']:
 assert row['status']=='passed' and row['exit_code']==0
 p=run/(row['name']+'.log');assert sha(p)==row['log_sha256']
 assert not re.search(r'^warning(?:\[|:)|^error:',p.read_text(),re.M)
raw=(run/'native-bridge-frame.log').read_text()
match=re.findall(r'^test tests::projection_bridge_compiled_frame \.\.\. F6E_PROJECTION_BRIDGE_TEST (\{.*\})$',raw,re.M);assert len(match)==1
native=json.loads(match[0]);assert native==dict(test='projection_bridge_compiled_frame',status='passed',expected_cases=2,executed_cases=2,expected_rejections=0,rejected_cases=0,bridge_frame_bytes=320,ffi_command_bytes=744)
assert 'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured;' in raw
(run/'native-bridge-receipt-recovered.json').write_text(json.dumps(native,indent=2)+'\n')
result=dict(status='verified_partial_execution_original_driver_failed',source_count=len(m),source_archive_members=len(members),log_hashes=6,compiler_warnings=0,native_outcomes=1,cases=2,refusals=0,models=0,bridge_frame_bytes=320,ffi_command_bytes=744,source_manifest_sha256=s['source_manifest_sha256'],failure='Collector expected marker at start of line; real libtest emits exact test-name prefix on the same line. Native test passed; no DLL registration/model gate executed.',next='Recover same raw receipt; carry six executed stages with exact source hashes and run only unexecuted stages.')
(run/'partial-verification.json').write_text(json.dumps(result,indent=2)+'\n')
a=repo/'tests/projection/measurements'/run.name;shutil.copytree(run,a);shutil.copyfile(__file__,a/Path(__file__).name)
files={str(p.relative_to(a)):{'sha256':sha(p),'bytes':p.stat().st_size} for p in sorted(a.rglob('*')) if p.is_file()};(a/'file-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print(json.dumps(result))
