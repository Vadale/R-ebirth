from pathlib import Path
import ast,datetime,hashlib,json,os,re,shutil,subprocess,traceback
ROOT=Path('/home/grauk/Documents/Codex/Recupero-Mac-2026-10-13/DOCUDESK/R-ebirth')
OUT=Path('/tmp/relm-phase8/installed-cuda');OUT.mkdir(exist_ok=False)
STATUS=Path('/tmp/relm-phase8/installed-status.json')
state={'status':'running','pid':os.getpid(),'output':str(OUT),'stages':[]}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def save():
 state['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();tmp=STATUS.with_suffix('.tmp');tmp.write_text(json.dumps(state,indent=2)+'\n');tmp.replace(STATUS)
def stage(name,cmd,cwd,env):
 state['stage']=name;save()
 with (OUT/(name+'.log')).open('w') as log:
  log.write(json.dumps(cmd)+'\n');log.flush();r=subprocess.run(cmd,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT)
 state['stages'].append({'name':name,'returncode':r.returncode,'log_sha256':sha(OUT/(name+'.log'))});save()
 if r.returncode:raise RuntimeError(name+' failed; preserve and diagnose')
 return (OUT/(name+'.log')).read_text()
def ignored(folder,names):
 result=[]
 for n in names:
  p=Path(folder)/n
  if n=='.DS_Store' or p.suffix in ['.o','.so','.dylib','.a'] or n in ['.cargo','target','CMakeFiles','CMakeCache.txt'] or (Path(folder).name=='src' and n in ['Makevars','Makevars.win','vendor']):result.append(n)
 return result
try:
 assert json.loads(Path('/tmp/relm-phase8/projection-permit-correction/owner.json').read_text())['status']=='passed'
 package=OUT/'package';shutil.copytree(ROOT/'rebirth',package,ignore=ignored)
 copied={str(p.relative_to(package)):sha(p) for p in package.rglob('*') if p.is_file()}
 (OUT/'package-source-before.json').write_text(json.dumps(copied,indent=2,sort_keys=True)+'\n')
 scripts=['/tmp/relm-phase8/check-installed-cuda.R','/tmp/relm-phase8/installed-workflow.R']
 bindings={str(ROOT/'rebirth'/p):h for p,h in copied.items()}
 for p in scripts+['examples/research-workflow/run.R','tests/projection/evaluation/log_capture.c']:
  q=Path(p) if p.startswith('/') else ROOT/p;bindings[str(q)]=sha(q)
 (OUT/'source-before.json').write_text(json.dumps(bindings,indent=2,sort_keys=True)+'\n')
 cuda=Path('/home/grauk/.local/share/relm/toolchains/cuda-13.3.1');env=os.environ.copy()
 for k in list(env):
  if k.startswith(('RELM_TEST_MODEL','RELM_TEST_MMPROJ','F6E_MODEL')) or k in ['DEBUG','RELM_NATIVE_SANITIZERS','CARGO_TARGET_DIR']:env.pop(k,None)
 env.update(json.loads(Path('/tmp/relm-phase8/native-metadata-correction/build-environment.json').read_text()))
 env.pop('CARGO_TARGET_DIR',None)
 cargo=OUT/'temporary-cargo-home';cargo.mkdir();shutil.copytree(Path.home()/'.cargo/registry',cargo/'registry')
 library=OUT/'library';library.mkdir()
 env.update({'RELM_ENABLE_CUDA':'1','RELM_ENABLE_SELFTESTS':'0','CARGO_NET_OFFLINE':'true','CARGO_BUILD_JOBS':'2','MAKEFLAGS':'CARGOTMP='+str(cargo),'R_LIBS':str(library)+':/home/grauk/.local/share/relm/phase8/R-library','R_HOME':subprocess.check_output(['R','RHOME'],text=True).strip()})
 env['PATH']=str(cuda/'bin')+':'+env['PATH']
 (OUT/'build-environment.json').write_text(json.dumps({k:env[k] for k in ['CUDA_PATH','CUDAARCHS','CUDACXX','CUDAHOSTCXX','CC','CXX','CMAKE_GENERATOR','CARGO_BUILD_JOBS','LD_LIBRARY_PATH','RELM_ENABLE_CUDA','RELM_ENABLE_SELFTESTS','CARGO_NET_OFFLINE','MAKEFLAGS','R_LIBS','R_HOME']},indent=2)+'\n')
 # Run the actual configure first to bind the generated commands. INSTALL
 # then uses that exact Makevars; no alternate native linker or skipped build.
 stage('configure',['sh','configure'],package,env)
 mv=(package/'src/Makevars').read_text();assert '--features cuda' in mv and '-lggml-cuda' in mv
 for operation in ['build','run']:
  command=next(line for line in mv.splitlines() if 'cargo '+operation+' ' in line)
  assert '--release' in command and '--features cuda' in command and '--print=native-static-libs' in command
 assert '-Wl,-rpath,' in mv and 'stubs' not in mv
 (OUT/'generated-Makevars').write_text(mv)
 stage('install',['R','CMD','INSTALL','--no-configure','--library='+str(library),str(package)],ROOT,env)
 dll=library/'relm/libs/relm.so';assert dll.is_file()
 # Installation legitimately creates generated files. Every original source
 # byte, including R wrappers, must still equal the accepted candidate.
 after={p:sha(package/p) for p in copied};assert after==copied
 (OUT/'package-source-after.json').write_text(json.dumps(after,indent=2,sort_keys=True)+'\n')
 runtime=env.copy();runtime.pop('LD_LIBRARY_PATH',None)
 elf=stage('dynamic-links',['readelf','-d',str(dll)],ROOT,runtime)
 assert 'libcudart.so' in elf and 'libcublas.so' in elf and ('RUNPATH' in elf or 'RPATH' in elf)
 stage('installed-check',['Rscript','--vanilla',scripts[0],str(library/'relm'),str(package),str(ROOT),str(OUT)],ROOT,runtime)
 logger=OUT/'log_capture.so'
 stage('logger-compile',['gcc','-std=c11','-D_GNU_SOURCE','-fPIC','-shared','-Wall','-Wextra','-Werror','-I'+str(ROOT/'rebirth/src/llama.cpp/include'),'-I'+str(ROOT/'rebirth/src/llama.cpp/ggml/include'),str(ROOT/'tests/projection/evaluation/log_capture.c'),'-ldl','-o',str(logger)],ROOT,runtime)
 stage('workflow',['Rscript','--vanilla',scripts[1],str(ROOT),str(OUT),'/home/grauk/.local/share/relm/models/qwen2.5-0.5b-instruct-q8_0.gguf',str(logger)],ROOT,runtime)
 current={p:sha(Path(p)) for p in bindings};assert current==bindings
 (OUT/'source-after.json').write_text(json.dumps(current,indent=2,sort_keys=True)+'\n')
 (OUT/'installed-hashes.json').write_text(json.dumps({str(p.relative_to(library/'relm')):sha(p) for p in (library/'relm').rglob('*') if p.is_file()},indent=2,sort_keys=True)+'\n')
 state.update(status='awaiting_owner_verification',dll_sha256=sha(dll),default_fixture_hooks=False,build_profile='release',runtime_without_ld_library_path=True)
except Exception as e:
 state.update(status='failed',error=str(e));(OUT/'driver-error.txt').write_text(traceback.format_exc())
finally:save()
