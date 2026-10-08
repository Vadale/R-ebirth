from pathlib import Path
import copy,importlib.util,json
root=Path('/private/tmp/relm-f6e');ready=json.loads((root/'constructor-ready.json').read_text())
spec=importlib.util.spec_from_file_location('c',root/'constructor-collector.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
passed=[]
def positive(name,fn):fn();passed.append(name)
def negative(name,fn):
 try:fn()
 except (AssertionError,ValueError,TypeError,KeyError):passed.append(name)
 else:raise AssertionError('Accepted malformed receipt: '+name)
def row(t):
 r=dict(test=t.get('marker_test',t['id']),status='passed',expected_cases=t['expected_cases'],executed_cases=t['expected_cases'],expected_rejections=t['expected_rejections'],rejected_cases=t['expected_rejections'],expected_values=t['expected_values'],compared_values=t['expected_values'],max_abs_error=.001 if t['expected_values'] else 0,model_loads=t['model_loads'])
 if t['execution']=='cargo_libtest':r['source']='a'*64
 else:r['twin_cases']=4
 return r
def marker(r):return c.MARKER+' '+json.dumps(r)+'\n'
for t in ready['tests']:
 r=row(t);native=t['execution']=='cargo_libtest'
 def log(r):return ('test '+t['id']+' ... ' if native else '')+marker(r)+('ok\ntest result: ok. 1 passed; 0 failed; 0 ignored;\n' if native else c.DONE+'\n')
 def check(text):return c.native(text,t,'a'*64) if native else c.hosted(text,t)
 positive(t['id']+':positive',lambda:check(log(r)))
 for key,value in [('executed_cases',0),('rejected_cases',False),('compared_values',t['expected_values']+1),('model_loads',t['model_loads']+1),('max_abs_error',float('nan')),('max_abs_error',.0100001),('test','wrong'),('status','failed')]:
  bad=copy.deepcopy(r);bad[key]=value
  negative(t['id']+':'+key,lambda:check(log(bad)))
 negative(t['id']+':duplicate',lambda:check(log(r)+marker(r)))
 if native:
  negative(t['id']+':no_execution',lambda:check(log(r).replace('1 passed','0 passed')))
  bad=copy.deepcopy(r);bad['source']='b'*64
  negative(t['id']+':source',lambda:check(log(bad)))
 else:
  negative(t['id']+':missing_return',lambda:check(log(r).replace(c.DONE,'')))
  negative(t['id']+':early_return',lambda:check(c.DONE+'\n'+marker(r)))
rows=[]
for s,a in [(0,0),(1,0),(0,1),(1,1)]:
 p=dict.fromkeys(ready['profile_fields'],64);p.update(version=2,max_sites=32,max_width=65536)
 i=dict.fromkeys(ready['input_fields'],0);i.update(mode=1,hidden_size=32,layers=3,previous_sites=1,steer_entries=s,ablate_entries=a,r_projection_fixed_bytes=4096,max_bytes=2**26)
 terms=dict.fromkeys(ready['term_fields'],0);terms['total_bytes']=5000
 rows.append(dict(case=f's{s}a{a}',profile=p,inputs=i,terms=terms))
def logs(x):return ''.join('F6E_PROJECTION_CONSTRUCTOR_TWIN '+json.dumps(r)+'\n' for r in x)
positive('twins:positive',lambda:c.twins(logs(rows),ready))
negative('twins:order',lambda:c.twins(logs(rows[::-1]),ready))
negative('twins:missing',lambda:c.twins(logs(rows[:-1]),ready))
for section,key,value in [('profile','version',1),('inputs','production_armed',1),('terms','total_bytes',2**27),('profile','ffi_fixed_bytes',False),('inputs','hidden_size',31)]:
 bad=copy.deepcopy(rows);bad[0][section][key]=value
 negative('twins:'+key,lambda:c.twins(logs(bad),ready))
print(json.dumps({'status':'passed','synthetic_controls':len(passed),'native_execution':False,'names':passed}))
