import importlib.util,json,copy
from pathlib import Path
p=Path(__file__).with_name('combined-collector.py');s=importlib.util.spec_from_file_location('c',p);c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
count=0
def bad(fn,*args):
 global count
 try:fn(*args)
 except (AssertionError,ValueError,KeyError):count+=1;return
 raise AssertionError('negative collector control accepted')
r={'test':'projection_bridge_compiled_frame','status':'passed','expected_cases':2,'executed_cases':2,'expected_rejections':0,'rejected_cases':0,'bridge_frame_bytes':296,'ffi_command_bytes':720}
def log(v):return 'tests::projection_bridge_compiled_frame\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured;\nF6E_PROJECTION_BRIDGE_TEST '+json.dumps(v)
c.bridge_native(log(r));count+=1
for k,v in [('executed_cases',0),('rejected_cases',1),('ffi_command_bytes',1),('bridge_frame_bytes',0),('test','other')]:
 z=r.copy();z[k]=v;bad(c.bridge_native,log(z))
bad(c.bridge_native,log(r)+ '\nF6E_PROJECTION_BRIDGE_TEST '+json.dumps(r))
for mode in ['default','private']:
 z=dict(mode=mode,status='passed',expected_cases=2,executed_cases=2,expected_rejections=1,rejected_cases=1,model_count=0)
 text='F6E_PROJECTION_BRIDGE_R '+json.dumps(z);c.mode_receipt(text,mode);count+=1
 bad(c.mode_receipt,text,'wrong');z['model_count']=1;bad(c.mode_receipt,'F6E_PROJECTION_BRIDGE_R '+json.dumps(z),mode)
rows=[dict(case=x,status='passed',refusal='TRUE' if x in c.REFUSALS else 'FALSE') for x in c.CASES]
text='\n'.join('F6E_BINDING_CASE '+r['case']+' refusal='+r['refusal'] for r in rows)+'\nF6E_COMBINED_R_BINDING cases=27 refusals=4 constructor_calls=5 model_loads=1 source_reset=TRUE closed=TRUE'
c.combined_rows(rows,text);count+=1
bad(c.combined_rows,rows[:-1],text);bad(c.combined_rows,rows[::-1],text);bad(c.combined_rows,rows,text.replace('model_loads=1','model_loads=0'))
z=copy.deepcopy(rows);z[4]['refusal']='FALSE';bad(c.combined_rows,z,text)
m=dict(exact_budget='1400000',actual_R_bytes='1200000',R_bound_bytes='1300000',workspace_bytes='10000',model_skeleton_bytes='1205000',state_extra_bytes='1272',flat_bytes='800',mixed_flat_bytes='1100',construct_calls='5',model_loads='1')
c.materialized(m);count+=1
for k,v in [('actual_R_bytes','1400001'),('state_extra_bytes','992'),('construct_calls','6'),('exact_budget','1000000')]:
 z=m.copy();z[k]=v;bad(c.materialized,z)
assert count==23,count
print('F6E_COMBINED_COLLECTOR_CONTROLS passed=23 models=0 native_tests=0')
