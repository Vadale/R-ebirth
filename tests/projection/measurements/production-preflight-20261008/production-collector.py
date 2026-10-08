import json,re
NATIVE_FIELDS={'test','status','expected_cases','executed_cases','expected_rejections','rejected_cases','expected_values','compared_values','model_loads','constructor_calls','library_cfg_test','private_feature'}
def unique(pairs):
 d={}
 for k,v in pairs:
  assert k not in d, 'duplicate JSON field';d[k]=v
 return d
def marker(log,prefix,name=None):
 lines=log.splitlines(); hits=[]
 for line in lines:
  if name is not None and line.startswith('test '+name+' ... '):line=line[len('test '+name+' ... '):]
  if line.startswith(prefix+' '):hits.append(line[len(prefix)+1:])
 assert len(hits)==1,(prefix,len(hits))
 return json.loads(hits[0],object_pairs_hook=unique)
def native(log,test):
 exact=test['id']
 assert re.search(r'^running 1 test$',log,re.M)
 names=re.findall(r'^test ([^ ]+) \.\.\. ',log,re.M);assert names==[exact],names
 matches=re.findall(r'^test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured; (\d+) filtered out;',log,re.M)
 assert len(matches)==1 and tuple(map(int,matches[0][:4]))==(1,0,0,0),matches
 assert re.search(r'^(?:ok|test '+re.escape(exact)+r' \.\.\. ok)$',log,re.M)
 r=marker(log,'F6E_PROJECTION_PRODUCTION_TEST',exact);assert set(r)==NATIVE_FIELDS
 assert r['test']==test['marker_test'] and r['status']=='passed'
 for k,w in [('expected_cases','expected_cases'),('executed_cases','expected_cases'),('expected_rejections','expected_rejections'),('rejected_cases','expected_rejections'),('expected_values','expected_values'),('compared_values','expected_values'),('model_loads','model_loads'),('constructor_calls','constructor_calls')]:assert type(r[k]) is int and r[k]==test[w],(k,r[k])
 for k in ['library_cfg_test','private_feature']:assert type(r[k]) is bool and r[k]==test[k]
 assert not re.search(r'^(?:warning(?:\[|:)|error(?:\[|:)|test result: FAILED)',log,re.M)
 return r
def registration(log,ready):
 g=ready['r_hosted_default_gate'];r=marker(log,g['marker']);p=marker(log,g['profile_marker'])
 assert set(r)=={'status','expected_cases','executed_cases','expected_rejections','rejected_cases','model_loads','results'}
 assert r['status']=='passed' and r['results']==g['expected_results']
 for k,w in [('expected_cases',4),('executed_cases',4),('expected_rejections',2),('rejected_cases',2),('model_loads',0)]:assert type(r[k]) is int and r[k]==w
 assert set(p)=={'profile'} and list(p['profile'])==g['profile_fields']
 profile=p['profile']
 assert all(type(v) is int and v>=0 for v in profile.values())
 for k,v in ready['profile']['expected_host_fixed_profile'].items():assert profile[k]==v,(k,profile[k],v)
 # The registry is empty in this new R process. Its allocated capacity remains
 # an observed dynamic quantity, validated against the unchanged exact formula.
 registry=profile['ffi_registry_bytes'];assert registry>=32 and (registry-32)%16==0
 assert profile['ffi_fixed_bytes']==profile['ffi_response_bytes']+registry+160
 assert not re.search(r'^(?:Warning|warning|Error|error)',log,re.M)
 return {'registration':r,'profile':profile,'registry_capacity_derived':(registry-32)//16}
