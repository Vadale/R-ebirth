import copy,importlib.util,json
from pathlib import Path
root=Path('/private/tmp/relm-f6e')
s=importlib.util.spec_from_file_location('c',root/'ledger-collector.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
t={'id':'projection_profile::tests::example','expected_cases':3,'expected_rejections':1}
r={'test':'example','status':'passed','expected_cases':3,'executed_cases':3,'expected_rejections':1,'rejected_cases':1}
log='test '+t['id']+' ... ok\nF6E_PROJECTION_LEDGER_TEST '+json.dumps(r)+'\ntest result: ok. 1 passed; 0 failed; 0 ignored; 12 filtered out;\n'
assert c.exact_test(log,t)==r
controls=1
neg=[log.replace('1 passed','0 passed'),log.replace('0 failed','1 failed'),log.replace('0 ignored','1 ignored'),log.replace(t['id'],'other'),log+log,log.replace('F6E_PROJECTION_LEDGER_TEST','missing')]
for field,value in [('executed_cases',2),('rejected_cases',0),('expected_cases',True),('status','failed'),('test','other')]:
 bad=copy.deepcopy(r);bad[field]=value;neg.append(log.replace(json.dumps(r),json.dumps(bad)))
for x in neg:
 try:c.exact_test(x,t)
 except (AssertionError,ValueError):controls+=1
 else:raise AssertionError('accepted invalid evidence')
for x in [dict(a=True),dict(a=-1),dict(a=2**53),dict(a=1.1),dict(b=1),dict(a=1,extra=1)]:
 try:c.numeric_record(x,['a'])
 except AssertionError:controls+=1
 else:raise AssertionError('accepted invalid numeric record')
print(json.dumps({'collector_controls':controls,'status':'passed','native_execution':False}))
b=24;p={'ffi_handle_tag_bytes':b};v=c.rbytes(8);chars=c.rbytes(b+1)
r={'fixture':'two_closed_llm_handles','model_count':0,'externalptr_r_type':'externalptr','protected_is_null':True,'tag_r_type':'character','tag_length':1,'tag_utf8_bytes':b,'externalptr_bytes':[64,64],'tag_bytes':[v+chars]*2,'pointer_pair_bytes':c.rbytes(16)+128,'tag_pair_bytes':c.rbytes(16)+2*(v+chars),'combined_bytes':c.rbytes(32)+128+2*(v+chars),'empty_pair_bytes':c.rbytes(16),'empty_quad_bytes':c.rbytes(32),'charged_tag_bytes':2*v+chars,'shared_character_payload':True}
assert c.verify_tag(r,p)==r;controls+=1
for field,value in [('model_count',1),('protected_is_null',False),('shared_character_payload',False),('tag_utf8_bytes',23),('externalptr_bytes',[64,65]),('tag_bytes',[v+chars,v]),('charged_tag_bytes',2*v),('pointer_pair_bytes',0),('tag_pair_bytes',r['empty_pair_bytes']+2*v),('combined_bytes',r['empty_quad_bytes']+128+2*v)]:
 bad=copy.deepcopy(r);bad[field]=value
 try:c.verify_tag(bad,p)
 except AssertionError:controls+=1
 else:raise AssertionError('accepted invalid tag receipt')
print(json.dumps({'collector_controls':controls,'status':'passed','native_execution':False}))
ready=json.load(open(root/'public-ledger-ready.json'))
p={k:1 for k in ready['profile_fields']};p.update(version=1,max_sites=32,max_width=65536)
rows=[]
for n,name in enumerate(ready['markers']['F6E_PROJECTION_LEDGER_TWIN']['cases']):
 i={k:0 for k in ready['input_fields']};i.update(mode=n%2,backend=n%3,hidden_size=[1,32,65536][n%3],previous_sites=[0,1,31,32][n%4],steer_entries=n%2,ablate_entries=(n//2)%2,max_bytes=1024)
 t={k:0 for k in ready['term_fields']};t['total_bytes']=1
 rows.append(dict(case=name,profile=p.copy(),inputs=i,terms=t))
def log_twins(p,rows):return 'F6E_PROJECTION_ALLOCATION_PROFILE '+json.dumps(p)+'\n'+'\n'.join('F6E_PROJECTION_LEDGER_TWIN '+json.dumps(x) for x in rows)
assert c.twins(log_twins(p,rows),ready)==(p,rows);controls+=1
for kind in ['missing','duplicate','fraction','wrong_profile','armed','overbudget','field_order','missing_backend','wrong_case']:
 bad=copy.deepcopy(rows)
 if kind=='missing':bad.pop()
 if kind=='duplicate':bad[-1]=bad[0]
 if kind=='fraction':bad[0]['terms']['total_bytes']=.5
 if kind=='wrong_profile':bad[0]['profile']['site_bytes']=2
 if kind=='armed':bad[0]['inputs']['production_armed']=1
 if kind=='overbudget':bad[0]['terms']['total_bytes']=1025
 if kind=='field_order':bad[0]['terms']=dict(reversed(list(bad[0]['terms'].items())))
 if kind=='missing_backend':
  for x in bad:x['inputs']['backend']=0
 if kind=='wrong_case':bad[0]['case']='unexpected'
 try:c.twins(log_twins(p,bad),ready)
 except AssertionError:controls+=1
 else:raise AssertionError('accepted invalid twins '+kind)
print(json.dumps({'collector_controls':controls,'status':'passed','native_execution':False}))
