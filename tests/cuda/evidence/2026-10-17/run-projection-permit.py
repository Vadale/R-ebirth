import datetime, hashlib, json, os, pathlib, subprocess, traceback
ROOT=pathlib.Path('/home/grauk/Documents/Codex/Recupero-Mac-2026-10-13/DOCUDESK/R-ebirth')
OUT=pathlib.Path('/tmp/relm-phase8/projection-permit-correction')
OUT.mkdir(exist_ok=False)
status_path=pathlib.Path('/tmp/relm-phase8/projection-permit-status.json')
state={'status':'running','pid':os.getpid(),'output':str(OUT),'stages':[]}
def status():
 state['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 tmp=status_path.with_suffix('.tmp');tmp.write_text(json.dumps(state,indent=2)+'\n');tmp.replace(status_path)
def run(name,args,env):
 state['stage']=name;status()
 with (OUT/(name+'.log')).open('w') as log:
  log.write(json.dumps(args)+'\n');log.flush()
  result=subprocess.run(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
 state['stages'].append({'name':name,'returncode':result.returncode});status()
 if result.returncode: raise RuntimeError(f'{name} exited {result.returncode}')
def sources():
 result={}
 for folder in ['rebirth/src/rust/rebirth-llm','rebirth/src/rust/rebirth-ffi','rebirth/src/llama.cpp','tests/llm-golden/synthetic','tests/llm-golden/projection','tests/llm-golden/live-state/f6b']:
  for path in (ROOT/folder).rglob('*'):
   if path.is_file(): result[str(path.relative_to(ROOT))]=hashlib.sha256(path.read_bytes()).hexdigest()
 for name in ['rebirth/src/rust/Cargo.lock','rebirth/src/rust/Cargo.toml']:
  result[name]=hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
 return result
try:
 env=os.environ.copy();cuda=pathlib.Path('/home/grauk/.local/share/relm/toolchains/cuda-13.3.1')
 env.update({'CUDA_PATH':str(cuda),'CUDAARCHS':'75-real','CUDACXX':str(cuda/'bin/nvcc'),'CUDAHOSTCXX':'/usr/bin/g++-15','CC':'/usr/bin/gcc-15','CXX':'/usr/bin/g++-15','CMAKE_GENERATOR':'Ninja','CARGO_TARGET_DIR':'/tmp/relm-phase8/native-initial/target','CARGO_BUILD_JOBS':'2','LD_LIBRARY_PATH':str(cuda/'lib')+(':'+env['LD_LIBRARY_PATH'] if env.get('LD_LIBRARY_PATH') else '')})
 env['PATH']=str(cuda/'bin')+':/home/grauk/.cargo/bin:'+env['PATH']
 before=sources();(OUT/'source-before.json').write_text(json.dumps(before,sort_keys=True,indent=2)+'\n')
 (OUT/'build-environment.json').write_text(json.dumps({k:env[k] for k in ['CUDA_PATH','CUDAARCHS','CUDACXX','CUDAHOSTCXX','CC','CXX','CMAKE_GENERATOR','CARGO_TARGET_DIR','CARGO_BUILD_JOBS','LD_LIBRARY_PATH']},indent=2)+'\n')
 manifest=str(ROOT/'rebirth/src/rust/Cargo.toml')
 command=['cargo','test','--locked','--manifest-path',manifest,'-p','rebirth-llm','--features','cuda','-j','2','--offline','--lib']
 run('clippy',['cargo','clippy','--locked','--offline','--manifest-path',manifest,'-p','rebirth-llm','--features','cuda','--tests','-j','2','--','-D','warnings'],env)
 tests=[
 ('rows_cuda','projection::tests::cuda_projection_device_rows_match_scalar_equation'),
 ('zero_live_cuda','projection::review_tests::cuda_projection_zero_live_capture_preserves_identity_without_row_work'),
 ('worker_cuda','async_job::tests::cuda_projection_static_live_restore_cancel_and_poison')]
 for name,test in tests:
  run(name,command+[test,'--','--exact','--nocapture','--test-threads=1'],env)
 after=sources();(OUT/'source-after.json').write_text(json.dumps(after,sort_keys=True,indent=2)+'\n')
 if before!=after: raise RuntimeError('Build/test source drift')
 state['status']='awaiting_owner_verification'
except Exception as error:
 state['status']='failed';state['error']=str(error)
 (OUT/'driver-error.txt').write_text(traceback.format_exc())
finally: status()
