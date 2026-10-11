import fcntl,hashlib,json,os,shlex,shutil,subprocess,time,traceback
from pathlib import Path
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); root=Path('/private/tmp/relm-maintenance-040'); work=repo/'rebirth/src/rust'
lock=(root/'build.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
run=root/('builds-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
env=os.environ.copy();env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip();env['RUST_TEST_THREADS']='1';env['NOT_CRAN']='true'
for k in list(env):
 if k.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_','F6E_MODEL')) or k=='RELM_NATIVE_SANITIZERS':env.pop(k)
state={'status':'running','pid':os.getpid(),'directory':str(run),'stages':[],'started':time.time()}
def save():
 text=json.dumps(state,indent=2)+'\n';(run/'status.json').write_text(text);p=root/'build-status.tmp';p.write_text(text);p.replace(root/'build-status.json')
def stage(name,cmd,cwd=work,extra=None):
 row={'name':name,'command':cmd,'status':'running'};state['stages'].append(row);state['stage']=name;save()
 with (run/(name+'.log')).open('w') as log:r=subprocess.run(cmd,cwd=cwd,env={**env,**(extra or {})},stdout=log,stderr=subprocess.STDOUT,timeout=3600)
 row.update(status='passed' if r.returncode==0 else 'failed',exit_code=r.returncode,log_sha256=sha(run/(name+'.log')));save()
 if r.returncode:raise RuntimeError(name+' failed: inspect retained log')
 return (run/(name+'.log')).read_text()
save()
try:
 sources={str(p.relative_to(repo)):sha(p) for folder in ['rebirth/R','rebirth/src/rust/rebirth-ffi','rebirth/tests/testthat'] for p in (repo/folder).rglob('*') if p.is_file() and p.suffix in ['.rs','.c','.R','.toml']}
 (run/'source-manifest.json').write_text(json.dumps(sources,indent=2)+'\n')
 (run/'candidate.patch').write_bytes(subprocess.check_output(['git','diff','--binary'],cwd=repo))
 contract=json.loads((root/'previous-link-contract.json').read_text())
 for mode,features in [('production',[]),('selftest',['--features','selftest'])]:
  stage(mode+'-clippy',['cargo','clippy','--locked','--offline','-p','rebirth-ffi','--all-targets']+features+['--','-D','warnings'])
  stage(mode+'-no-spill',['cargo','check','--locked','--offline','-p','rebirth-ffi','--no-default-features']+features)
  raw=stage(mode+'-build',['cargo','build','--locked','--offline','-p','rebirth-ffi','--lib','--message-format=json']+features)
  messages=[json.loads(x) for x in raw.splitlines() if x.startswith('{')]
  artifact=[x for x in messages if x.get('reason')=='compiler-artifact' and x['target']['name']=='relm' and 'staticlib' in x['target']['crate_types']];assert len(artifact)==1
  assert ('selftest' in artifact[0]['features']) == (mode=='selftest')
  dest=run/mode;dest.mkdir();shutil.copy2(repo/'rebirth/src/entrypoint.c',dest/'entrypoint.c')
  stage(mode+'-link',contract['link_command'],dest,contract['link_environment'])
  dll=dest/'relm.so'; archive=Path(contract['static_archive'])
  (dest/'binary.json').write_text(json.dumps({'artifact':artifact[0],'archive_sha256':sha(archive),'dll_sha256':sha(dll)},indent=2)+'\n')
  stage(mode+'-profile',['Rscript','--vanilla',str(root/'check-profile.R'),str(dll),str(dest)])
  package=dest/'package';package.mkdir()
  for d in ['R','man','inst']:shutil.copytree(repo/'rebirth'/d,package/d)
  for f in ['DESCRIPTION','NAMESPACE','LICENSE','NEWS.md']:shutil.copy2(repo/'rebirth'/f,package/f)
  stage(mode+'-wrappers',['Rscript','--vanilla',str(root/'generate-wrappers.R'),str(dll),str(package/'R/extendr-wrappers.R')])
  libdir=package/'inst/libs';libdir.mkdir();shutil.copy2(dll,libdir/'relm.so')
  library=dest/'library';library.mkdir()
  runenv={'RELM_ENABLE_SELFTESTS':'1' if mode=='selftest' else '0','R_LIBS':str(library)+':/private/tmp/relm-service/library:/Users/alessandrovadala/Library/R/arm64/4.5/library'}
  stage(mode+'-install',['R','CMD','INSTALL','--no-configure','--no-libs','--library='+str(library),str(package)],repo,runenv)
  assert sha(library/'relm/libs/relm.so')==sha(dll)
  (dest/'installed-manifest.json').write_text(json.dumps({str(p.relative_to(library/'relm')):sha(p) for p in (library/'relm').rglob('*') if p.is_file()},indent=2)+'\n')
  stage(mode+'-R',['Rscript','--vanilla',str(root/'check-installed.R'),str(library/'relm'),str(package),str(repo),str(dest)],repo,runenv)
 stage('private-check',['cargo','check','--locked','--offline','-p','rebirth-ffi','--features','projection-private'])
 state['status']='awaiting_owner_verification'
except Exception as e:state.update(status='failed',error=str(e),traceback=traceback.format_exc())
state['finished']=time.time();save()
