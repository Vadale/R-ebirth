import ast,copy,hashlib,importlib.util,json,shutil
from pathlib import Path
T=Path('/private/tmp/relm-f6e');R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
ready=json.loads((T/'review-fix-counter-ready.json').read_text());assert sha(T/'review-fix-counter-ready.json')=='141bb5fe313457248707587c3898a23555358e0ed4d86c880b3ac20535752471'
b=copy.deepcopy(json.loads((T/'review-fix-binding.json').read_text()));b['ready_sha256']=sha(T/'review-fix-counter-ready.json');b['repo_sources'].update(ready['source_hashes'])
for p,h in {**b['repo_sources'],**ready['unchanged_source_hashes']}.items():assert sha(R/p)==h,p
parent=T/'review-fix-20261008-143824';b['parent_run']=str(parent);b['parent_status_sha256']=sha(parent/'status.json')
receipt='review-fix-counter-'+b['ready_sha256'];b['tests'][0]['expected_marker']['source']=receipt
for t in b['tests']:t['env']['F6E_SOURCE']=receipt
sp=importlib.util.spec_from_file_location('collector',T/'review-fix-collector.py');c=importlib.util.module_from_spec(sp);sp.loader.exec_module(c)
t=b['tests'][0]
def log(marker):return 'running 1 test\ntest '+t['id']+' ... '+t['marker']+' '+json.dumps(marker)+'\nok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 5 filtered out; finished in 0.01s\n'
c.native(log(t['expected_marker']),t);wrong=copy.deepcopy(t['expected_marker']);wrong['source']='prior-source'
try:c.native(log(wrong),t)
except AssertionError:pass
else:raise AssertionError('old source accepted')
(T/'review-fix-counter-binding-control.json').write_text(json.dumps({'status':'passed','positive_current_source':1,'negative_old_source':1,'models':0},indent=2)+'\n')
for n in ['verify-review-fix-counter.py','bind-review-fix-counter.py']:ast.parse((T/n).read_text())
b['files']={str(T/n):sha(T/n) for n in ['verify-review-fix-counter.py','review-fix-collector.py','check-review-fix-profile.R','bind-review-fix-counter.py','review-fix-counter-binding-control.json']}
b['correction_scope']='Only cumulative capture counter assertions changed; both no-spill library checks carried. Product and all numerical/zero-work assertions unchanged.'
p=T/'review-fix-counter-binding.json';assert not p.exists();p.write_text(json.dumps(b,indent=2)+'\n')
A=R/'tests/projection/measurements/review-fix-counter-preflight-20261008';A.mkdir()
for file in list(b['files'])+[str(p),str(T/'review-fix-counter-ready.json'),str(T/'review-fix-counter.patch')]:shutil.copy2(file,A/Path(file).name)
shutil.copytree(T/'review-fix-counter-originals',A/'originals')
(A/'manifest.json').write_text(json.dumps({str(p.relative_to(A)):sha(p) for p in A.rglob('*') if p.is_file()},indent=2)+'\n')
print(json.dumps({'binding_sha256':sha(T/'review-fix-counter-binding.json'),'driver_sha256':sha(T/'verify-review-fix-counter.py'),'source_hashes':len(b['repo_sources']),'scope':'bound; not launched'}))
