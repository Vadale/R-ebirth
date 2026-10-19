from pathlib import Path
import datetime, hashlib, json, os, shutil, subprocess, tarfile, time, traceback
ROOT = Path('/home/grauk/Documents/Codex/Recupero-Mac-2026-10-13/DOCUDESK/R-ebirth')
BASE = Path('/home/grauk/Work/relm-phase9')
OUT = BASE / 'readiness-fixtures'
STATUS = BASE / 'readiness-fixtures-status.json'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
state = dict(status='running', pid=os.getpid(), output=str(OUT), stages=[])

def save():
    state['updated_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    tmp = STATUS.with_suffix('.tmp'); tmp.write_text(json.dumps(state, indent=2)+'\n'); tmp.replace(STATUS)

def stage(name, command, cwd, env, timeout=2400):
    state['stage'] = name; save(); start = time.monotonic()
    log = OUT / (name+'.log')
    with log.open('w') as stream:
        stream.write(json.dumps(command)+'\n'); stream.flush()
        result = subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    state['stages'].append(dict(name=name, returncode=result.returncode, seconds=time.monotonic()-start, log_sha256=sha(log)))
    save()
    if result.returncode: raise RuntimeError(name+' failed; preserve passed stages')
    return log.read_text(errors='replace')

def r_config(name, env):
    return subprocess.check_output(['/usr/bin/R','CMD','config',name], env=env, text=True).strip()

try:
    OUT.mkdir(exist_ok=False); save()
    previous=BASE/'readiness-build'
    prior=json.loads((BASE/'readiness-build-status.json').read_text())
    assert prior['status']=='failed' and prior['stages'][-1]['returncode']==101
    for item in prior['stages']:
        assert sha(previous/(item['name']+'.log'))==item['log_sha256']
    diagnosis=json.loads((previous/'diagnosis.json').read_text())
    binding=json.loads((BASE/'readiness-fixtures-binding.json').read_text())
    assert sha(Path(__file__))==binding['driver_sha256']
    sources=binding['sources']
    assert sources=={name:sha(ROOT/name) for name in sources}
    shutil.copy2(__file__,OUT/'driver.py')
    shutil.copy2(previous/'diagnosis.json',OUT/'parent-diagnosis.json')
    for name in ['source-before.json','source-tar.json','environment.json','native-environment.json']:
        shutil.copy2(previous/name,OUT/name)
    (OUT/'carried-stages.json').write_text(json.dumps(prior['stages'][:2],indent=2)+'\n')
    package=previous/'package';src=package/'src';target=src/'rust/target'
    assert all(sha(package/Path(name).relative_to('rebirth'))==h for name,h in sources.items() if name.startswith('rebirth/'))
    for name,h in diagnosis['fixtures'].items():
        assert sha(ROOT/name)==h
        destination=previous/name
        assert not destination.exists()
        destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,destination)
        assert sha(destination)==h
    for name,record in diagnosis['native_files'].items():
        assert sha(target/'release'/name)==record['sha256']
    env=os.environ.copy()
    for key in list(env):
        if key.startswith(('RELM_', 'F6E_', 'CUDA','CARGO_','CMAKE_')) or key in ('DEBUG','MAKEFLAGS','RUSTFLAGS','RUSTC_WRAPPER','CC','CXX','CFLAGS','CXXFLAGS','LDFLAGS','LD_LIBRARY_PATH','RUSTUP_TOOLCHAIN'):
            env.pop(key,None)
    env.update(json.loads((previous/'environment.json').read_text()))
    library=OUT/'library';library.mkdir();env['R_LIBS']=str(library)+':/home/grauk/.local/share/relm/phase8/R-library'
    native=env.copy();native.update(json.loads((previous/'native-environment.json').read_text()))
    output=stage('context-budget',['cargo','test','--locked','--offline','-j','2','--release','-p','rebirth-llm','--lib','--manifest-path=./rust/Cargo.toml','--target-dir=./rust/target','engine::tests::r_check_budget_reaches_all_owned_contexts','--','--exact','--nocapture'],src,native)
    for count in [2,4]:
        marker=f'CRAN_CONTEXT_THREADS_OK threads={count} contexts=4 text_fields=8 vision_parameter=1 loads=1 decodes=0'
        assert output.count(marker)==1,marker
    assert '1 passed; 0 failed' in output
    retained={}
    for name,record in diagnosis['native_files'].items():
        path=target/'release'/name
        now={'sha256':sha(path),'bytes':path.stat().st_size,'mtime_ns':path.stat().st_mtime_ns}
        assert now==record, 'Native artifact unexpectedly rebuilt: '+name
        retained[name]=now
    (OUT/'native-reuse.json').write_text(json.dumps(retained,indent=2,sort_keys=True)+'\n')
    receipt=OUT/'native-build';receipt.mkdir()
    target=src/'rust/target'
    selected={}
    for p in target.rglob('*'):
        if p.is_file() and (p.name in ['CMakeCache.txt','flags.make','compile_commands.json'] or p.suffix=='.a'):
            rel=p.relative_to(target); selected[str(rel)]=sha(p)
            if p.suffix!='.a':
                dest=receipt/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
    assert any(p.endswith('CMakeCache.txt') for p in selected)
    (receipt/'inventory.json').write_text(json.dumps(selected,indent=2,sort_keys=True)+'\n')
    caches=list(receipt.rglob('CMakeCache.txt'))
    engine=[p for p in caches if 'GGML_NATIVE:BOOL=OFF' in p.read_text()];assert len(engine)==1
    cache=engine[0].read_text()
    for option in ['GGML_AVX','GGML_AVX2','GGML_FMA','GGML_F16C','GGML_SSE42','GGML_CPU_ALL_VARIANTS']:
        assert option+':BOOL=OFF' in cache,option
    flags='\n'.join(p.read_text() for p in receipt.rglob('flags.make'))
    assert '-march=native' not in flags and '-mcpu=native' not in flags
    assert '-mavx' not in flags and '-mfma' not in flags
    assert native['CFLAGS'] in cache and native['CXXFLAGS'] in cache
    state['context_control']=dict(loads=2,decodes=0,text_contexts=8,text_thread_fields=16,vision_parameter_values=2)
    save()
    # Configure/Makevars performs the normal production library build and
    # wrapper generation in this same package/target. It cleans its own caches.
    stage('install',['/usr/bin/R','CMD','INSTALL','--library='+str(library),str(package)],OUT,env)
    dll=library/'relm/libs/relm.so';assert dll.is_file()
    output=stage('elf',['readelf','-d',str(dll)],OUT,env,30)
    assert 'TEXTREL' not in output and 'libcudart' not in output and 'libcublas' not in output
    stage('installed-inspection',['/usr/bin/Rscript','--vanilla',str(ROOT/'tests/cran/installed-readiness.R'),str(library/'relm'),str(package),str(OUT/'installed-result.rds')],ROOT,env,120)
    after={n:sha(ROOT/n) for n in sources};assert after==sources,'frozen inputs changed'
    (OUT/'source-after.json').write_text(json.dumps(after,indent=2,sort_keys=True)+'\n')
    installed={str(p.relative_to(library)):sha(p) for p in sorted(library.rglob('*')) if p.is_file()}
    (OUT/'installed-hashes.json').write_text(json.dumps(installed,indent=2)+'\n')
    state.update(status='awaiting_owner_verification',dll_sha256=sha(dll),source_files=len(sources),installed_files=len(installed),scope='New portable CPU install and thread-parameter control; no inference or full CRAN/manual claim')
except Exception as error:
    state.update(status='failed',error=str(error),traceback=traceback.format_exc())
    if OUT.is_dir(): (OUT/'failure.txt').write_text(state['traceback'])
finally:
    save()
