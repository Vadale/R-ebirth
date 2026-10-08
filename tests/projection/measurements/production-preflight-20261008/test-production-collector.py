import copy,importlib.util,json
from pathlib import Path
root=Path('/private/tmp/relm-f6e');spec=importlib.util.spec_from_file_location('c',root/'production-collector.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
ready=json.loads((root/'production-ready.json').read_text());positive=negative=0
for test in ready['tests']:
 r={'test':test['marker_test'],'status':'passed','expected_cases':test['expected_cases'],'executed_cases':test['expected_cases'],'expected_rejections':test['expected_rejections'],'rejected_cases':test['expected_rejections'],'expected_values':test['expected_values'],'compared_values':test['expected_values'],'model_loads':test['model_loads'],'constructor_calls':test['constructor_calls'],'library_cfg_test':test['library_cfg_test'],'private_feature':False}
 def log(x,prefix=True):
  s='running 1 test\n'+'test '+test['id']+' ... '+('' if prefix else '\n')+'F6E_PROJECTION_PRODUCTION_TEST '+json.dumps(x)+'\nok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 100 filtered out; finished in 0.10s\n';return s
 for prefix in [True,False]:c.native(log(r,prefix),test);positive+=1
 badlogs=[]
 for key,val in [('test','wrong'),('status','failed'),('executed_cases',0),('rejected_cases',0),('compared_values',0),('model_loads',0),('constructor_calls',0),('private_feature',True),('library_cfg_test',not test['library_cfg_test']),('expected_cases',True)]:
  b=dict(r);b[key]=val;badlogs.append(log(b))
 badlogs.extend([log(r).replace('running 1 test','running 0 tests'),log(r).replace('1 passed; 0 failed; 0 ignored','0 passed; 0 failed; 1 ignored'),log(r).replace('\nok\n','\n'),log(r).replace('test '+test['id'],'test wrong'),log(r)+'F6E_PROJECTION_PRODUCTION_TEST '+json.dumps(r)+'\n',log(r)+'warning: compiler warning\n',log(r).replace('"status": "passed"','"status": "passed", "status": "passed"')])
 for s in badlogs:
  try:c.native(s,test)
  except (AssertionError,ValueError):negative+=1
  else:raise AssertionError('accepted malformed native receipt')
g=ready['r_hosted_default_gate'];profile={k:ready['profile']['expected_host_fixed_profile'].get(k,0) for k in g['profile_fields']};profile['ffi_registry_bytes']=32;profile['ffi_fixed_bytes']=profile['ffi_response_bytes']+32+160
r={'status':'passed','expected_cases':4,'executed_cases':4,'expected_rejections':2,'rejected_cases':2,'model_loads':0,'results':g['expected_results']}
def host(a,b):return g['profile_marker']+' '+json.dumps({'profile':b})+'\n'+g['marker']+' '+json.dumps(a)+'\n'
c.registration(host(r,profile),ready);positive+=1
bads=[]
for key,val in [('executed_cases',0),('rejected_cases',1),('model_loads',1),('results',list(reversed(g['expected_results'])))]:
 b=copy.deepcopy(r);b[key]=val;bads.append(host(b,profile))
for key,val in [('runtime_bytes',5073),('ffi_registry_bytes',33),('ffi_fixed_bytes',1705),('version',1)]:
 b=dict(profile);b[key]=val;bads.append(host(r,b))
bads.append(host(r,profile)+g['marker']+' '+json.dumps(r)+'\n')
for s in bads:
 try:c.registration(s,ready)
 except (AssertionError,ValueError):negative+=1
 else:raise AssertionError('accepted malformed R registration')
result={'status':'PASS','positive':positive,'negative':negative,'controls':positive+negative,'scope':'synthetic collector controls only; no native/model acceptance'}
(root/'production-collector-controls.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
