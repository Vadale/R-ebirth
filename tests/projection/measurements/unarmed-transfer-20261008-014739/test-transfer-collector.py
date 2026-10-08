from pathlib import Path
import copy,importlib.util,json
r=Path('/private/tmp/relm-f6e');ready=json.loads((r/'transfer-ready.json').read_text())
s=importlib.util.spec_from_file_location('c',r/'transfer-collector.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
passed=0
def positive(f):
 global passed
 f();passed+=1
def negative(f):
 global passed
 try:f()
 except (AssertionError,ValueError,TypeError,KeyError):passed+=1
 else:raise AssertionError('Malformed receipt accepted')
def record(t):return dict(test=t.get('test',t.get('id','').split('::')[-1]),status='passed',expected_cases=t['expected_cases'],executed_cases=t['expected_cases'],expected_rejections=t['expected_rejections'],rejected_cases=t['expected_rejections'])
def line(row):return 'F6E_PROJECTION_TRANSFER_TEST '+json.dumps(row)+'\n'
for t in ready['tests']:
 row=record(t)
 def log(x):return 'test '+t['id']+' ... '+line(x)+'ok\ntest result: ok. 1 passed; 0 failed; 0 ignored;\n'
 positive(lambda:c.native(log(row),t))
 for key in ['executed_cases','rejected_cases','test','status']:
  bad=copy.deepcopy(row);bad[key]='wrong' if isinstance(row[key],str) else row[key]-1
  negative(lambda:c.native(log(bad),t))
 negative(lambda:c.native(log(row).replace('1 passed;','0 passed;'),t))
 negative(lambda:c.native(log(row)+line(row),t))
rows=[record(t) for t in ready['r_hosted']['outcomes']]
done='F6E_TRANSFER_R_HOSTED_SUCCESS outcomes=3 cases=42 rejections=31 models=0\n'
log=''.join(map(line,rows))+done
positive(lambda:c.hosted(log,ready))
negative(lambda:c.hosted(log.replace(done,''),ready))
negative(lambda:c.hosted(log+done,ready))
negative(lambda:c.hosted(done+''.join(map(line,rows)),ready))
negative(lambda:c.hosted(''.join(map(line,rows[::-1]))+done,ready))
negative(lambda:c.hosted(log+'test result: ok.',ready))
p={'ffi_response_bytes':1464}
facts=[dict(fixture=k,hash_slots=v,bindings=2,c_finalizer_bytes=8,query_workspace_bytes=280,ffi_response_bytes=1464) for k,v in ready['markers']['F6E_PROJECTION_STATE_FACTS']['fixtures'].items()]
def logs(rows):return ''.join('F6E_PROJECTION_STATE_FACTS '+json.dumps(x)+'\n' for x in rows)
positive(lambda:c.facts(logs(facts),p,ready))
for key,val in [('hash_slots',999),('bindings',3),('c_finalizer_bytes',4),('query_workspace_bytes',1465),('ffi_response_bytes',1463)]:
 bad=copy.deepcopy(facts);bad[0][key]=val
 negative(lambda:c.facts(logs(bad),p,ready))
negative(lambda:c.facts(logs(facts[::-1]),p,ready))
negative(lambda:c.facts(logs(facts+facts[:1]),p,ready))
assert passed==35,passed
print(json.dumps({'status':'passed','synthetic_collector_controls':passed,'native_execution':False}))
