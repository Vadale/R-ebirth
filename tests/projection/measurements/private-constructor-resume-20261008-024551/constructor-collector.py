"""Strict raw receipts; importing never executes native/model work."""
import json,math,re
MARKER='F6E_PROJECTION_CONSTRUCTOR_TEST'
DONE='F6E_CONSTRUCTOR_R_HOSTED_SUCCESS outcomes=1 cases=18 rejections=10 model_loads=1'
def markers(log,key):
 return [json.loads(line.split(key+' ',1)[1]) for line in log.splitlines() if key+' ' in line]
def record(row,test,source=None):
 common={'test','status','expected_cases','executed_cases','expected_rejections','rejected_cases','expected_values','compared_values','max_abs_error','model_loads'}
 assert set(row)==common|({'source'} if source is not None else {'twin_cases'})
 assert row['test']==test.get('marker_test',test['id']) and row['status']=='passed'
 for key,want in [('expected_cases',test['expected_cases']),('executed_cases',test['expected_cases']),('expected_rejections',test['expected_rejections']),('rejected_cases',test['expected_rejections']),('expected_values',test['expected_values']),('compared_values',test['expected_values']),('model_loads',test['model_loads'])]:
  assert type(row[key]) is int and row[key]==want,(key,row)
 error=row['max_abs_error'];assert type(error) in (int,float) and math.isfinite(error) and 0<=error<=.01
 if test['expected_values']==0:assert error==0
 if source is not None:assert re.fullmatch('[0-9a-f]{64}',source) and row['source']==source
 else:assert type(row['twin_cases']) is int and row['twin_cases']==4
 return row
def native(log,test,source):
 assert re.findall(r'test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored;',log)==[('1','0','0')]
 assert re.search(r'test '+re.escape(test['id'])+r' \.\.\. ',log)
 rows=markers(log,MARKER);assert len(rows)==1
 return record(rows[0],test,source)
def hosted(log,test):
 assert 'test result: ok.' not in log and log.count(DONE)==1
 rows=markers(log,MARKER);assert len(rows)==1
 assert log.rindex(MARKER+' ')<log.index(DONE)
 return record(rows[0],test)
def twins(log,ready):
 rows=markers(log,'F6E_PROJECTION_CONSTRUCTOR_TWIN')
 assert len(rows)==4 and [r['case'] for r in rows]==['s0a0','s1a0','s0a1','s1a1']
 for row,(s,a) in zip(rows,[(0,0),(1,0),(0,1),(1,1)]):
  assert set(row)=={'case','profile','inputs','terms'}
  for section,fieldkey in [('profile','profile_fields'),('inputs','input_fields'),('terms','term_fields')]:
   assert list(row[section])==ready[fieldkey]
   assert all(type(x) is int and 0<=x<2**53 for x in row[section].values())
  p=row['profile'];i=row['inputs'];t=row['terms']
  assert p['version']==2 and p['max_sites']==32 and p['max_width']==65536
  assert i['mode']==1 and i['hidden_size']==32 and i['layers']==3 and i['previous_sites']==1
  assert i['steer_entries']==s and i['ablate_entries']==a and i['production_armed']==0
  assert i['metadata_bytes']==i['metadata_scratch_bytes']==i['source_baseline_values']==0
  assert i['backend']==0 and i['r_projection_fixed_bytes']==4096 and i['r_adapter_bytes']==0
  assert t['total_bytes']<=i['max_bytes']
 return rows
