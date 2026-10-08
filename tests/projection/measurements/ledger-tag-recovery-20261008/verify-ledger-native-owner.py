from pathlib import Path
import hashlib,json,tarfile,re,importlib.util
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');root=Path('/private/tmp/relm-f6e');run=root/'public-ledger-resume-20261008-010121'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
s=json.loads((run/'status.json').read_text());ready=json.loads((run/'ready.json').read_text());m=json.loads((run/'source-manifest.json').read_text())
assert s['status']=='failed' and s['source_drift']==[] and '[184, 184]'==s['error']
assert len(s['stages'])==12 and all(x['status']=='passed' for x in s['stages'])
for st in s['stages']:
 assert sha(run/(st['name']+'.log'))==st['log_sha256']
 assert not re.search(r'^warning(?:\[|:)',(run/(st['name']+'.log')).read_text(),re.M)
assert hashlib.sha256((run/'source-manifest.json').read_bytes()).hexdigest()==s['source_manifest_sha256']
for p,h in m.items():assert sha(repo/p)==h,p
with tarfile.open(run/'changed-source.tar.gz') as tar:
 members=[x for x in tar.getmembers() if x.isfile()]
 for x in members:assert hashlib.sha256(tar.extractfile(x).read()).hexdigest()==m[x.name]
sp=importlib.util.spec_from_file_location('c',run/'ledger-collector.py');c=importlib.util.module_from_spec(sp);sp.loader.exec_module(c)
receipts=[]
for n,test in enumerate(ready['tests'][:6],1):receipts.append(c.exact_test((run/f'native-{n:02d}.log').read_text(),test))
log=(run/'ffi-r-hosted.log').read_text();receipts.append(c.hosted_test(log,ready['tests'][6]));p,twins=c.twins(log,ready)
assert sum(x['executed_cases'] for x in receipts)==95 and sum(x['rejected_cases'] for x in receipts)==40
b=json.loads((run/'fresh-ffi-binding.json').read_text())
for path,h in b['static_archives'].items():assert sha(Path(path))==h,path
assert sha(Path(b['dll_path']))==b['dll_sha256'];assert sha(run/'ffi-hosted/entrypoint.c')==b['entrypoint_sha256']
a=json.loads((run/'cargo-static-artifact.json').read_text());assert str(repo/'rebirth/src/rust/target/debug/librelm.a') in a['filenames']
assert json.loads((run/'native-profile.json').read_text())==p and json.loads((run/'native-twins.json').read_text())==twins
result={'status':'partial_verified','overall_attempt':'failed_collector','native_outcomes':7,'native_cases':95,'native_rejections':40,'libtest_outcomes':6,'R_hosted_outcomes':1,'source_count':len(m),'archived_source_members':len(members),'source_manifest_sha256':s['source_manifest_sha256'],'stage_logs':len(s['stages']),'compiler_linker_warnings':0,'model_runs':0,'native_reexecution':False,'pending':'Correct tag-size collector assumption and run previously unexecuted independent R156terms; full constructor ownership still pending'}
(run/'owner-native-verification.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
