from pathlib import Path
import json,hashlib,re,math,struct
root=Path.cwd();out=Path('/tmp/relm-phase8/projection-permit-correction');parent=Path('/tmp/relm-phase8/projection-lint-correction')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before=json.loads((out/'source-before.json').read_text());after=json.loads((out/'source-after.json').read_text());assert before==after
assert all(sha(root/p)==v for p,v in after.items())
prev=json.loads((parent/'source-before.json').read_text());delta=[p for p in prev if prev[p]!=before[p]];assert delta==['rebirth/src/rust/rebirth-llm/src/projection_cuda_tests.rs']
def records(log,marker):
 return [json.loads(s.split(marker,1)[1]) for s in log.splitlines() if marker in s]
f32=lambda x:struct.unpack('<f',struct.pack('<f',x))[0]
logs={k:(out/(k+'.log')).read_text() for k in ['rows_cuda','zero_live_cuda','worker_cuda']}
for log in logs.values(): assert re.search(r'test result: ok\. 1 passed; 0 failed; 0 ignored;',log)
rows=records(logs['rows_cuda'],'WP13_CUDA_ROW ');assert len(rows)==16
count=0;maximum=0
for component in ['mlp_out','attn_out']:
 for pos in [0,3,8,9]:
  a=[x for x in rows if x['component']==component and x['position']==pos and x['before']];b=[x for x in rows if x['component']==component and x['position']==pos and not x['before']];assert len(a)==len(b)==1
  x=list(map(f32,a[0]['values']));y=list(map(f32,b[0]['values']));assert len(x)==len(y)==32
  dot=x[1]*.6+x[5]*.8
  for i,(v,actual) in enumerate(zip(x,y)):
   direction=.6 if i==1 else .8 if i==5 else 0.
   expected=f32(v-(.5*direction)*dot);err=abs(actual-expected)
   assert math.isfinite(actual) and err<=2e-6*(1+abs(expected));maximum=max(maximum,err);count+=1
assert count==256
buffers=[b for log in logs.values() for b in records(log,'F6E_PROJECTION_BUFFER ')]
assert buffers
for b in buffers:
 assert b['kind']==3 and b['is_host']==0 and b['flags']==510 and b['device_index']==0 and not b['no_staging_supported']
 assert bytes(b['type_name_bytes']).split(b'\0')[0]==b'CUDA0'
 assert bytes(b['registry_name_bytes']).split(b'\0')[0]==b'CUDA'
zero=records(logs['zero_live_cuda'],'F6E_PROJECTION_REVIEW_TEST ');assert len(zero)==1;zero=zero[0]
assert (zero['executed_cases'],zero['rejected_cases'],zero['compared_values'],zero['backend'])==(8,2,224,'Cuda')
assert all(zero[k]==0 for k in ['zero_barriers','zero_read_bytes','zero_rows','zero_write_bytes','max_abs_error','refused_deliveries'])
worker=records(logs['worker_cuda'],'F6E_PROJECTION_PRODUCTION_TEST ');assert len(worker)==1;worker=worker[0]
assert (worker['executed_cases'],worker['rejected_cases'],worker['compared_values'])==(10,2,3)
assert 'WP13_PROJECTION_WORKER_BACKEND Cuda' in logs['worker_cuda']
transfer=records(logs['rows_cuda'],'WP13_CUDA_TRANSFER ');assert len(transfer)==2
assert all((x['rows'],x['write_bytes'],x['same_row_values'],x['device_kind'])==(10,1280,128,3) for x in transfer)
receipt=records(logs['rows_cuda'],'WP13_CUDA_PROJECTION_PASS ');assert len(receipt)==1;receipt=receipt[0]
assert (receipt['sites'],receipt['values'],receipt['budget_refusals'],receipt['probe_decodes'])==(2,256,2,4)
profile=dict(receipt['profile']);assert len(profile)==27 and profile['cpp_access_frame_bytes']==77 and profile['runtime_bytes']==5072
for name in ['identity_existing','identity_cuda']:
 text=(parent/(name+'.log')).read_text();assert 'test result: ok. 1 passed; 0 failed; 0 ignored;' in text
clippy=(out/'clippy.log').read_text();assert 'Finished' in clippy and not re.search(r'^(warning|error):',clippy,re.M)
result={'status':'passed','scope':'Native CUDA projection only; no installed R/performance acceptance','source_files':len(before),'only_source_change_from_parent':delta,'independent_same_input_values':count,'independent_max_abs_error':maximum,'actual_cuda_buffer_receipts':len(buffers),'identity_controls_carried':{'host_metal':21,'cuda':14},'device_transfers':transfer,'zero_live':zero,'worker':worker,'compiled_profile':profile,'profile_scope':'Linux Rust1.99.1 layout; dynamic fields are not claimed equal to historical Mac/Rust layouts','raw_hashes':{p.name:sha(p) for p in out.glob('*.log')},'parent_failed_statuses_preserved':True,'model_replay_in_verification':False}
(out/'owner.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:result[k] for k in ['status','source_files','independent_same_input_values','independent_max_abs_error','actual_cuda_buffer_receipts']}))
