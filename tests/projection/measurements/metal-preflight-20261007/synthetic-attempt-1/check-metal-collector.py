"""Synthetic collector controls only. Never counted as native execution."""
import ast, copy, importlib.util, json
from pathlib import Path
ROOT=Path(__file__).parent
s=importlib.util.spec_from_file_location('collector',ROOT/'metal-collector.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
results=[]
def control(label,fn,reject=False):
 try:fn()
 except (AssertionError,ValueError,KeyError,TypeError,UnicodeError):
  assert reject,label
 else:assert not reject,label
 results.append({'name':label,'status':'passed','expected_rejection':reject})
def encoded(s,n):return list(s.encode())+[0]*(n-len(s))
rows=[]
for (h,d,phase,layer,c),n in m.expected_counts().items():
 for _ in range(n):
  rows.append(dict(schema=1,phase=phase,width=h,depth=d,layer_native=layer,component_code=c,kind=2,is_host=0,usage=2,device_type=1,flags=255,device_index=0,type_name_bytes=encoded('MTL0',32),device_name_bytes=encoded('MTL0',32),registry_name_bytes=encoded('MTL',16),rows=1,bytes=4*h,dtype_f32=True,view_offset=0,data_nonnull=True,contiguous=True,no_staging_supported=True,decode_failed=False))
proof={'selected_devices':['MTL0: Synthetic control'],'compute_buffers_mib':[['MTL0',1.0]]}
bench={'tiny_forward':{'backend':proof},'hooked_backend':proof}
control('exact 71 synthetic receipts',lambda:m.verify_buffers(rows,bench))
for key,value in [('kind',0),('kind',1),('is_host',1),('device_type',0),('usage',1),('view_offset',4),('dtype_f32',False),('data_nonnull',False),('contiguous',False),('no_staging_supported',False),('decode_failed',True),('width',31),('depth',4),('layer_native',1),('component_code',1),('phase','unknown'),('rows',0),('bytes',129),('device_index',1),('schema',2),('flags',True)]:
 altered=copy.deepcopy(rows);altered[0][key]=value
 control(f'refuse {key}={value}',lambda a=altered:m.verify_buffers(a,bench),True)
for bit in range(8):
 altered=copy.deepcopy(rows);altered[0]['flags']&=~(1<<bit)
 control(f'refuse missing identity/shape flag {bit}',lambda a=altered:m.verify_buffers(a,bench),True)
for key,value in [('type_name_bytes',encoded('MTL0_Private',32)),('type_name_bytes',encoded('MTL00',32)),('registry_name_bytes',encoded('FAKE',16)),('device_name_bytes',[65]*32),('type_name_bytes',encoded('MTL0',32)[:-1]),('device_name_bytes',encoded('MTL0',32)[:-1]+[1])]:
 altered=copy.deepcopy(rows);altered[0][key]=value
 control(f'refuse bounded-name corruption {len(results)}',lambda a=altered:m.verify_buffers(a,bench),True)
control('refuse missing actual receipt',lambda:m.verify_buffers(rows[:-1],bench),True)
control('refuse duplicate actual receipt',lambda:m.verify_buffers(rows+[rows[0]],bench),True)
bad=copy.deepcopy(rows);bad[-1]=copy.deepcopy(rows[0])
control('refuse wrong per-site multiplicity',lambda:m.verify_buffers(bad,bench),True)
badbench=copy.deepcopy(bench);badbench['hooked_backend']['compute_buffers_mib']=[['CPU',1.0]]
control('refuse unbound native backend',lambda:m.verify_buffers(rows,badbench),True)
bad=copy.deepcopy(rows);bad[0]['pointer']='0x123'
control('refuse unapproved pointer/field',lambda:m.verify_buffers(bad,bench),True)
# Compiled POD fixture; arbitrary positive Rust sizes are controls, not measured evidence.
ledger=dict(width=65536,sites=32,direction_bytes=32*(8*65536+16),plan_bytes=4200,runtime_bytes=2*(4*65536+8192)+2048,probe_bytes=20*65536+8192+96+2048,frame_bytes=1024,total=1,runtime_size=8192,site_size=40,probe_size=96,projection_info_size=128,buffer_info_size=104,proof_size=160,proof_slots=32,access_frame_bytes=80)
ledger['total']=sum(ledger[k] for k in ('direction_bytes','plan_bytes','runtime_bytes','probe_bytes','frame_bytes'))
control('compiled-ledger-shaped synthetic positive',lambda:m.verify_ledger([ledger]))
for key,value in [('total',1),('buffer_info_size',103),('projection_info_size',127),('proof_slots',31),('proof_size',8),('runtime_size',1),('frame_bytes',256),('direction_bytes',1),('runtime_bytes',1),('probe_bytes',1),('access_frame_bytes',0)]:
 altered=dict(ledger);altered[key]=value
 control(f'refuse ledger {key}',lambda a=altered:m.verify_ledger([a]),True)
old=ast.parse((ROOT/'verify-feasibility-pruning.py').read_text());new=ast.parse((ROOT/'verify-feasibility-metal.py').read_text())
for name in ('digest','integer','number','markers','test_result','test_receipt','verify_same_row','verify_backend','verify_benchmark'):
 oldnode=next(n for n in old.body if isinstance(n,ast.FunctionDef) and n.name==name)
 newnode=next(n for n in new.body if isinstance(n,ast.FunctionDef) and n.name==name)
 control(f'unchanged inherited {name}',lambda a=oldnode,b=newnode:__import__('builtins').exec('assert same',{'same':ast.dump(a)==ast.dump(b)}))
result={'status':'passed','scope':'synthetic collector checks only; not native, numerical or Metal acceptance','controls':len(results),'results':results}
(ROOT/'metal-collector-controls.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:result[k] for k in ('status','scope','controls')}))
