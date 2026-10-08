"""Fail-closed evidence parser; no native execution on import."""
import json,re

def markers(log,key):
 out=[]
 for line in log.splitlines():
  if key+' ' in line:out.append(json.loads(line.split(key+' ',1)[1]))
 return out

def exact_test(log,test):
 rows=re.findall(r'test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored;',log)
 assert rows==[('1','0','0')],rows
 assert re.search(r'test '+re.escape(test['id'])+r' \.\.\. ',log),test['id']
 rows=markers(log,'F6E_PROJECTION_LEDGER_TEST');assert len(rows)==1
 r=rows[0]
 assert set(r)=={'test','status','expected_cases','executed_cases','expected_rejections','rejected_cases'}
 assert r['status']=='passed' and r['test']==test['id'].split('::')[-1]
 for name,want in [('expected_cases',test['expected_cases']),('executed_cases',test['expected_cases']),('expected_rejections',test['expected_rejections']),('rejected_cases',test['expected_rejections'])]:
  assert type(r[name]) is int and r[name]==want,(name,r[name],want)
 return r

def numeric_record(x,fields):
 assert isinstance(x,dict) and list(x)==fields,list(x)
 assert all(type(v) is int and 0<=v<2**53 for v in x.values())

def twins(log,ready):
 profiles=markers(log,'F6E_PROJECTION_ALLOCATION_PROFILE');assert len(profiles)==1
 p=profiles[0];numeric_record(p,ready['profile_fields'])
 assert p['version']==1 and p['max_sites']==32 and p['max_width']==65536
 rows=markers(log,'F6E_PROJECTION_LEDGER_TWIN');assert len(rows)==12
 ids=[]
 for r in rows:
  assert set(r)=={'case','profile','inputs','terms'}
  assert isinstance(r['case'],str) and 0<len(r['case'])<128
  ids.append(r['case'])
  numeric_record(r['profile'],ready['profile_fields']);assert r['profile']==p
  numeric_record(r['inputs'],ready['input_fields']);numeric_record(r['terms'],ready['term_fields'])
  assert r['inputs']['production_armed']==0
  assert 0<r['terms']['total_bytes']<=r['inputs']['max_bytes']<=512*2**20
 assert len(set(ids))==12
 assert ids==ready['markers']['F6E_PROJECTION_LEDGER_TWIN']['cases']
 assert {r['inputs']['backend'] for r in rows}=={0,1,2}
 assert {r['inputs']['mode'] for r in rows}=={0,1}
 assert {r['inputs']['hidden_size'] for r in rows}=={1,32,65536}
 assert {r['inputs']['previous_sites'] for r in rows}>={0,1,31,32}
 assert {(r['inputs']['steer_entries']>0,r['inputs']['ablate_entries']>0) for r in rows}=={(False,False),(False,True),(True,False),(True,True)}
 return p,rows

def rbytes(n):
 assert type(n) is int and n>=0
 return 48+next((p for p in [0,8,16,32,48,64,128] if p>=n),8*((n+7)//8))

def verify_tag(r,profile):
 fields=['fixture','model_count','externalptr_r_type','protected_is_null','tag_r_type','tag_length','tag_utf8_bytes','externalptr_bytes','tag_bytes','pointer_pair_bytes','tag_pair_bytes','combined_bytes','empty_pair_bytes','empty_quad_bytes','charged_tag_bytes','shared_character_payload']
 assert list(r)==fields
 assert r['fixture']=='two_closed_llm_handles' and type(r['model_count']) is int and r['model_count']==0
 assert r['externalptr_r_type']=='externalptr' and r['tag_r_type']=='character'
 assert r['protected_is_null'] is True and r['shared_character_payload'] is True
 assert type(r['tag_length']) is int and r['tag_length']==1
 for name in ['tag_utf8_bytes','pointer_pair_bytes','tag_pair_bytes','combined_bytes','empty_pair_bytes','empty_quad_bytes','charged_tag_bytes']:
  assert type(r[name]) is int and 0<r[name]<2**53,name
 for name in ['externalptr_bytes','tag_bytes']:
  assert len(r[name])==2 and all(type(x) is int and 0<x<2**53 for x in r[name])
 assert r['tag_utf8_bytes']==profile['ffi_handle_tag_bytes']
 chars=rbytes(r['tag_utf8_bytes']+1);vector=rbytes(8)
 assert r['charged_tag_bytes']==2*vector+chars
 assert r['externalptr_bytes']==[64,64],r['externalptr_bytes']
 assert r['tag_bytes']==[vector+chars]*2,r['tag_bytes']
 assert r['empty_pair_bytes']==rbytes(16) and r['empty_quad_bytes']==rbytes(32)
 assert r['pointer_pair_bytes']==r['empty_pair_bytes']+128
 # object.size can count the shared CHARSXP twice across character vectors;
 # the explicit address-identity assertion supports charging that payload once.
 assert 2*vector+chars<=r['tag_pair_bytes']-r['empty_pair_bytes']<=2*(vector+chars)
 assert 128+2*vector+chars<=r['combined_bytes']-r['empty_quad_bytes']<=128+2*(vector+chars)
 return r
