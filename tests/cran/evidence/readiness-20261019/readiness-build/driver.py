from pathlib import Path
import datetime, hashlib, json, os, shutil, subprocess, tarfile, time, traceback
ROOT = Path('/home/grauk/Documents/Codex/Recupero-Mac-2026-10-13/DOCUDESK/R-ebirth')
BASE = Path('/home/grauk/Work/relm-phase9')
OUT = BASE / 'readiness-build'
STATUS = BASE / 'readiness-build-status.json'
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
    binding = json.loads((BASE/'readiness-build-binding.json').read_text())
    assert binding['driver_sha256'] == sha(Path(__file__))
    sources = binding['sources']
    assert sources == {name:sha(ROOT/name) for name in sources}, 'source freeze differs before execution'
    shutil.copy2(__file__, OUT/'driver.py')
    (OUT/'source-before.json').write_text(json.dumps(sources,indent=2,sort_keys=True)+'\n')
    package=OUT/'package'; package.mkdir()
    for name in sources:
        if name.startswith('rebirth/'):
            target=package/Path(name).relative_to('rebirth'); target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(ROOT/name,target)
    library=OUT/'library'; library.mkdir(); tmp=OUT/'tmp';tmp.mkdir()
    assert str(package.resolve()).startswith('/home/') and str(tmp.resolve()).startswith('/home/')
    assert shutil.disk_usage(OUT).free > 20*1024**3
    env=os.environ.copy()
    for key in list(env):
        if key.startswith(('RELM_', 'F6E_', 'CUDA','CARGO_','CMAKE_')) or key in ('DEBUG','MAKEFLAGS','RUSTFLAGS','RUSTC_WRAPPER','CC','CXX','CFLAGS','CXXFLAGS','LDFLAGS','LD_LIBRARY_PATH','RUSTUP_TOOLCHAIN'):
            env.pop(key,None)
    env.update(TMPDIR=str(tmp),R_LIBS=str(library)+':/home/grauk/.local/share/relm/phase8/R-library',R_LIBS_USER='/home/grauk/.local/share/relm/phase8/R-library',R_ENVIRON_USER='/dev/null',R_PROFILE_USER='/dev/null',RELM_ENABLE_CUDA='0',RELM_ENABLE_SELFTESTS='0',NOT_CRAN='false',CARGO_NET_OFFLINE='true',CARGO_BUILD_JOBS='2',RUST_TEST_THREADS='1',OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',MKL_NUM_THREADS='1',VECLIB_MAXIMUM_THREADS='1',BLIS_NUM_THREADS='1',_R_CHECK_LIMIT_CORES_='true')
    env['R_HOME']=subprocess.check_output(['/usr/bin/R','RHOME'],text=True).strip()
    (OUT/'environment.json').write_text(json.dumps({k:v for k,v in env.items() if k in ('TMPDIR','R_HOME','R_LIBS','R_LIBS_USER','R_ENVIRON_USER','R_PROFILE_USER','RELM_ENABLE_CUDA','RELM_ENABLE_SELFTESTS','NOT_CRAN','CARGO_NET_OFFLINE','CARGO_BUILD_JOBS','RUST_TEST_THREADS','OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS','VECLIB_MAXIMUM_THREADS','BLIS_NUM_THREADS','_R_CHECK_LIMIT_CORES_')},indent=2)+'\n')
    stage('source-build',['/usr/bin/R','CMD','build','--no-build-vignettes','--no-manual',str(package)],OUT,env)
    archives=list(OUT.glob('relm_*.tar.gz')); assert len(archives)==1
    archive=archives[0]
    with tarfile.open(archive) as tar:
        files=[m for m in tar if m.isfile()]
        assert not [m.name for m in files if len(m.name.encode())>100]
        inventory={m.name:hashlib.sha256(tar.extractfile(m).read()).hexdigest() for m in files}
        assert len(inventory)==len(files)
        for name,h in inventory.items():
            rel=Path(name).relative_to('relm').as_posix(); source='rebirth/'+rel
            if source in sources and rel!='DESCRIPTION': assert sources[source]==h,name
    (OUT/'source-tar.json').write_text(json.dumps(dict(sha256=sha(archive),bytes=archive.stat().st_size,files=inventory,vignettes_built=False,manual_built=False),indent=2)+'\n')
    stage('configure',['/usr/bin/Rscript','--vanilla','tools/config.R'],package,env,60)
    # The one engine compilation is shared by the new native parameter control
    # and the following ordinary R installation; no alternate native recipe.
    src=package/'src'
    with tarfile.open(src/'rust/vendor.tar.xz') as tar:
        tar.extractall(src, filter='data')
    cargo_home=src/'.cargo';cargo_home.mkdir(exist_ok=False)
    shutil.copy2(src/'rust/vendor-config.toml',cargo_home/'config.toml')
    native=env.copy()
    native.update(CARGO_HOME=str(cargo_home),RELM_R_PORTABLE='1',CC=r_config('CC',env),CXX=r_config('CXX17',env),CMAKE=shutil.which('cmake'),RUSTFLAGS=' --print=native-static-libs')
    native['CFLAGS']=' '.join(r_config(k,env) for k in ['CPPFLAGS','CFLAGS','CPICFLAGS'])
    native['CXXFLAGS']=' '.join(r_config(k,env) for k in ['CPPFLAGS','CXX17FLAGS','CXX17PICFLAGS','CXX17STD'])
    (OUT/'native-environment.json').write_text(json.dumps({k:native[k] for k in ['CARGO_HOME','RELM_R_PORTABLE','CC','CXX','CMAKE','CFLAGS','CXXFLAGS','RUSTFLAGS']},indent=2)+'\n')
    output=stage('context-budget',['cargo','test','--locked','--offline','-j','2','--release','-p','rebirth-llm','--lib','--manifest-path=./rust/Cargo.toml','--target-dir=./rust/target','engine::tests::r_check_budget_reaches_all_owned_contexts','--','--exact','--nocapture'],src,native)
    for count in [2,4]:
        marker=f'CRAN_CONTEXT_THREADS_OK threads={count} contexts=4 text_fields=8 vision_parameter=1 loads=1 decodes=0'
        assert output.count(marker)==1,marker
    assert '1 passed; 0 failed' in output
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
