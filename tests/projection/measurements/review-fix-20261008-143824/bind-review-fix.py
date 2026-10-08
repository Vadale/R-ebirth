import ast,copy,hashlib,importlib.util,json,subprocess
from pathlib import Path
T=Path('/private/tmp/relm-f6e');R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
ready=json.loads((T/'review-fix-ready.json').read_text());base=json.loads((T/'budget-class-binding.json').read_text())
assert sha(T/'review-fix-ready.json')=='fadae960a9662e9b0702567f4f770d48076d494d5217e33da8c4bae4b2afeb53'
fmt=json.loads((T/'review-fix-format-original/receipt.json').read_text())['changes']
sources=dict(ready['preserved_source_hashes'])
for group,records in ready['preserved_groups'].items():
 assert records['count']==len(records['source_hashes'])
 sources.update(records['source_hashes'])
for p,h in ready['source_hashes'].items():sources[p]=fmt.get(p,{}).get('formatted_sha256',h)
for p,h in sources.items():assert sha(R/p)==h,p
for p,h in base['r_headers'].items():assert sha(Path(p))==h,p
for name in ['verify-review-fix.py','review-fix-collector.py','bind-review-fix.py']:
 ast.parse((T/name).read_text(),filename=name)
sp=importlib.util.spec_from_file_location('collector',T/'review-fix-collector.py');c=importlib.util.module_from_spec(sp);sp.loader.exec_module(c)
tests=copy.deepcopy(ready['tests']);controls=[]
for test in tests:
 test['marker']=test['marker_prefix'].strip()
 def log(marker):return 'running 1 test\ntest '+test['id']+' ... '+test['marker']+' '+json.dumps(marker)+'\nok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 5 filtered out; finished in 0.01s\n'
 c.native(log(test['expected_marker']),test);controls.append({'test':test['id'],'control':'bound marker accepted','status':'passed'})
 bad=copy.deepcopy(test['expected_marker']);bad['executed_cases']-=1
 try:c.native(log(bad),test)
 except AssertionError:controls.append({'test':test['id'],'control':'wrong count refused','status':'passed'})
 else:raise AssertionError('wrong count accepted')
 if 'source' in bad:
  bad=copy.deepcopy(test['expected_marker']);bad['source']='wrong-source'
  try:c.native(log(bad),test)
  except AssertionError:controls.append({'test':test['id'],'control':'wrong source refused','status':'passed'})
  else:raise AssertionError('wrong source accepted')
(T/'review-fix-bound-collector-controls.json').write_text(json.dumps({'model_calls':0,'controls':controls},indent=2)+'\n')
files={str(T/n):sha(T/n) for n in ['verify-review-fix.py','review-fix-collector.py','check-review-fix-profile.R','bind-review-fix.py','review-fix-bound-collector-controls.json']}
bind={'schema':1,'ready_sha256':sha(T/'review-fix-ready.json'),'base_commit':ready['base_commit'],'repo_sources':sources,'files':files,'r_headers':base['r_headers'],'fresh_default_dll_contract':base['fresh_default_dll_contract'],'default_build_command':base['default_build_command'],'tests':tests,'model_loads_planned':1,'parent_formatting':fmt,'scope':'Two new exact default-library regressions, 86 cases / 7 refusals / 224 identity values planned; one tiny load / one constructor / two construction probes. Fresh current default DLL/profile. No old suites, Qwen, independent goldens, installed or scientific acceptance.'}
assert not (T/'review-fix-binding.json').exists()
(T/'review-fix-binding.json').write_text(json.dumps(bind,indent=2)+'\n')
print(json.dumps({'source_hashes':len(sources),'headers':len(base['r_headers']),'contract_controls':len(controls),'driver_sha256':sha(T/'verify-review-fix.py'),'binding_sha256':sha(T/'review-fix-binding.json')},indent=2))
