"""Synthetic controls for the receipt collector; never native/model evidence."""
import copy
import importlib.util
import json
from pathlib import Path

ROOT=Path('/private/tmp/relm-f6e')
spec=importlib.util.spec_from_file_location('driver',ROOT/'verify-feasibility.py')
d=importlib.util.module_from_spec(spec);spec.loader.exec_module(d)

def backend(kind,layers):
 if kind=='cpu':
  log='load: offloaded 0/'+str(layers+1)+' layers\nctx: CPU compute buffer size = 10.0 MiB\n'
  return dict(resolved_backend=kind,gpu_layer_policy=0,offloaded_layers=[[0,layers+1]],selected_devices=[],compute_buffers_mib=[['CPU',10.0]],native_load_log=log)
 log='load: using device MTL0 (synthetic control)\nload: offloaded '+str(layers+1)+'/'+str(layers+1)+' layers\nctx: MTL0 compute buffer size = 10.0 MiB\n'
 return dict(resolved_backend=kind,gpu_layer_policy=999,offloaded_layers=[[layers+1,layers+1]],selected_devices=['MTL0 (synthetic control)'],compute_buffers_mib=[['MTL0',10.0]],native_load_log=log)

def receipt(kind):
 samples=[]
 for rnd,order in enumerate([d.MODES]+d.ORDERS):
  for mode in order:
   active=mode.startswith('active');n=128 if active else 0
   samples.append(dict(round=rnd,warmup=rnd==0,mode=mode,prefill_seconds=.1,decode_seconds=.8,elapsed_seconds=1.0,decoded_tokens=128,site_rows=n,read_bytes=n*896*4,write_bytes=n*896*4,barriers=n))
 tiny=None if kind=='cpu' else dict(status='passed',model_sha256=d.TINY_HASH,expected_cases=15,executed_cases=15,expected_values=34748,compared_values=34748,max_abs_error=.005,max_rel_error=.003,backend=backend(kind,3))
 if tiny is not None:
  tiny['same_row']=dict(schema=1,status='passed',source_manifest_sha256='synthetic-control-only',reference_manifest_sha256=d.REFERENCE_HASH,test_id=d.TEST_IDS[5],requested_backend=kind,expected_values=2944,compared_values=2944,max_abs_error=0.0,max_scaled_error=0.0,scaled_error_definition='abs(actual-expected_f32)/(1+abs(expected_f32))',scaled_error_limit=2e-6)
 return dict(schema=1,status='passed',source_manifest_sha256='synthetic-control-only',reference_manifest_sha256=d.REFERENCE_HASH,model_sha256=d.MODEL_HASH,model=str(d.MODEL),build_profile='release',debug_assertions=False,requested_backend=kind,resolved_backend=kind,callback_free_backend=backend(kind,24),hooked_backend=backend(kind,24),tiny_forward=tiny,settings=dict(n_batch=512,n_ubatch=128,context_length=768,max_tokens=128,seed=42,temperature=.8,top_p=.95,warmups_per_mode=1,measured_rounds=3,component='mlp_out',single_layer_native=12,multi_layers_native=[0,12,23],direction='unit axis at native coordinate 1',coefficient=1.0,prompt_tokens=42),samples=samples,mode_order=d.MODES,median_elapsed_seconds=[1.0]*5,dormant_ratio=1.0,dormant_limit=1.05,active_limit=None)

def raw(r):
 lines=['F6E_PROJECTION_SAMPLE '+json.dumps(s) for s in r['samples']]
 lines.append('F6E_PROJECTION_TIMING '+json.dumps(dict(medians=r['median_elapsed_seconds'],dormant_ratio=r['dormant_ratio'],dormant_limit=r['dormant_limit'],active_limit=r['active_limit'])))
 if r['tiny_forward'] is not None:
  lines.append('F6E_PROJECTION_METAL_FORWARD '+json.dumps(r['tiny_forward']))
  lines.append('F6E_PROJECTION_SAME_ROW '+json.dumps(r['tiny_forward']['same_row']))
 return '\n'.join(lines)

results=[]
def check(name,r,rejected=False,log=None):
 try:d.verify_benchmark([r],r['requested_backend'],'synthetic-control-only',raw(r) if log is None else log)
 except (AssertionError,ValueError,KeyError,TypeError):
  assert rejected,name
 else:assert not rejected,name
 results.append(dict(name=name,status='passed',expected_rejection=rejected))

cpu=receipt('cpu');metal=receipt('metal')
check('valid-cpu',cpu);check('valid-metal-with-tiny-forward',metal)
def mutation(name,path,value,base=cpu):
 r=copy.deepcopy(base);x=r
 for key in path[:-1]:x=x[key]
 x[path[-1]]=value
 check(name,r,True)

for name,path,value in [
 ('wrong-source',['source_manifest_sha256'],'wrong'),('wrong-model',['model_sha256'],'wrong'),
 ('debug-build',['debug_assertions'],True),('zero-work',['samples',0,'decoded_tokens'],0),
 ('short-work',['samples',0,'decoded_tokens'],127),('wrong-order',['samples',1,'mode'],'zero'),
 ('bool-round',['samples',0,'round'],False),('wrong-warmup',['samples',0,'warmup'],False),
 ('nan-time',['samples',0,'elapsed_seconds'],float('nan')),('negative-time',['samples',0,'decode_seconds'],-1),
 ('impossible-time',['samples',0,'elapsed_seconds'],.1),('zero-mode-copies',['samples',2,'read_bytes'],4),
 ('active-no-write',['samples',3,'write_bytes'],0),('false-volume',['samples',3,'write_bytes'],4),
 ('wrong-median',['median_elapsed_seconds',0],2),('wrong-ratio',['dormant_ratio'],.99),
 ('relaxed-bound',['dormant_limit'],1.1),('invented-active-bound',['active_limit'],2),
 ('wrong-grid',['settings','multi_layers_native'],[1,12,23]),('wrong-token-cap',['settings','max_tokens'],64),
 ('cpu-gpu-policy',['hooked_backend','gpu_layer_policy'],999),
 ('unbound-log',['hooked_backend','compute_buffers_mib'],[['CPU',11.0]])]:
 mutation(name,path,value)
for name,path,value in [
 ('metal-missing-forward',['tiny_forward'],None),('metal-zero-values',['tiny_forward','compared_values'],0),
 ('metal-golden-bound',['tiny_forward','max_abs_error'],.02),('metal-no-offload',['hooked_backend','offloaded_layers'],[[0,25]]),
 ('metal-wrong-device',['hooked_backend','selected_devices'],['MTL9 synthetic']),
 ('same-row-zero-work',['tiny_forward','same_row','compared_values'],0),
 ('same-row-nan',['tiny_forward','same_row','max_scaled_error'],float('nan')),
 ('same-row-bound-failure',['tiny_forward','same_row','max_scaled_error'],3e-6),
 ('same-row-relaxed-bound',['tiny_forward','same_row','scaled_error_limit'],.01),
 ('same-row-wrong-source',['tiny_forward','same_row','source_manifest_sha256'],'wrong'),
 ('metal-false-native-log',['hooked_backend','native_load_log'],'ctx: CPU compute buffer size = 10.0 MiB\n')]:
 mutation(name,path,value,metal)
check('missing-raw-sample',cpu,True,raw(cpu).split('\n',1)[1])
check('duplicate-raw-sample',cpu,True,raw(cpu)+'\n'+raw(cpu).splitlines()[0])
r=copy.deepcopy(cpu)
for s in r['samples']:
 if s['mode']=='dormant':s['elapsed_seconds']=1.06
r['median_elapsed_seconds'][1]=1.06;r['dormant_ratio']=1.06
check('honest-dormant-bound-failure',r,True)
micro=copy.deepcopy(metal['tiny_forward']['same_row']);micro.update(test_id=d.TEST_IDS[6],requested_backend='cpu',expected_values=704,compared_values=704)
d.verify_same_row(micro,d.TEST_IDS[6],'cpu','synthetic-control-only')
results.append(dict(name='valid-cpu-micro-same-row',status='passed',expected_rejection=False))
(ROOT/'benchmark-collector-controls.json').write_text(json.dumps(dict(scope='synthetic receipt parser controls only; no native/model execution',controls=results,count=len(results),driver_sha256=d.digest(ROOT/'verify-feasibility.py')),indent=2)+'\n')
print(json.dumps(dict(count=len(results),status='passed',scope='collector only')))
