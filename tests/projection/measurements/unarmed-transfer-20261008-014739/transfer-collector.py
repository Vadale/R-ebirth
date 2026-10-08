"""Strict collectors for new transfer/state gates; imports never execute tests."""
import json,re
def markers(log,key):
 return [json.loads(line.split(key+' ',1)[1]) for line in log.splitlines() if key+' ' in line]
def record(r,t):
 assert set(r)=={'test','status','expected_cases','executed_cases','expected_rejections','rejected_cases'}
 assert r['test']==t.get('test',t.get('id','').split('::')[-1]) and r['status']=='passed'
 for field,want in [('expected_cases',t['expected_cases']),('executed_cases',t['expected_cases']),('expected_rejections',t['expected_rejections']),('rejected_cases',t['expected_rejections'])]:
  assert type(r[field]) is int and r[field]==want,(field,r)
 return r
def native(log,t):
 assert re.findall(r'test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored;',log)==[('1','0','0')]
 assert re.search(r'test '+re.escape(t['id'])+r' \.\.\. ',log)
 rows=markers(log,'F6E_PROJECTION_TRANSFER_TEST');assert len(rows)==1
 return record(rows[0],t)
def hosted(log,ready):
 assert 'test result: ok.' not in log
 rows=markers(log,'F6E_PROJECTION_TRANSFER_TEST');tests=ready['r_hosted']['outcomes']
 assert len(rows)==len(tests)==3
 for r,t in zip(rows,tests):record(r,t)
 done='F6E_TRANSFER_R_HOSTED_SUCCESS outcomes=3 cases=42 rejections=31 models=0'
 assert log.count(done)==1 and log.rindex('F6E_PROJECTION_TRANSFER_TEST ')<log.index(done)
 return rows
def facts(log,profile,ready):
 rows=markers(log,'F6E_PROJECTION_STATE_FACTS');assert len(rows)==3
 contract=ready['markers']['F6E_PROJECTION_STATE_FACTS']
 assert [r['fixture'] for r in rows]==list(contract['fixtures'])
 for r in rows:
  assert list(r)==contract['fields']
  assert all(type(v) is int and 0<=v<2**53 for k,v in r.items() if k!='fixture')
  assert r['hash_slots']==contract['fixtures'][r['fixture']] and r['bindings']==2
  assert r['c_finalizer_bytes']==8
  assert 0<r['query_workspace_bytes']<=r['ffi_response_bytes']==profile['ffi_response_bytes']
 assert len({r['query_workspace_bytes'] for r in rows})==1
 return rows
