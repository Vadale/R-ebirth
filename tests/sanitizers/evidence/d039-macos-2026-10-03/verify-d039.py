import fcntl, hashlib, json, os, signal, subprocess, time, traceback
from pathlib import Path
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); root=Path('/private/tmp/relm-maintenance')
lock=(root/'verify.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
run=root/('d039-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
state=dict(status='running',pid=os.getpid(),directory=str(run),started_at=time.time(),stages=[])
env=os.environ.copy();env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip()
env['RUST_TEST_THREADS']='1';env['R_LIBS']=':'.join([str(root/'d039-library'),'/private/tmp/relm-wp10/library','/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
env['PATH']='/Applications/RStudio.app/Contents/Resources/app/quarto/bin:'+env['PATH']
env['RELM_MAINTENANCE_EVIDENCE']=str(run)
for k in list(env):
 if k.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_')) or k=='RELM_NATIVE_SANITIZERS':env.pop(k)
(root/'d039-library').mkdir(exist_ok=True)
def save():
 data=json.dumps(state,indent=2)+'\n';(run/'status.json').write_text(data)
 tmp=root/'d039-status.tmp';tmp.write_text(data);tmp.replace(root/'d039-status.json')
def stage(name,cmd,cwd=repo/'rebirth/src/rust',timeout=1800):
 item=dict(name=name,command=cmd,status='running',started_at=time.time());state['stages'].append(item);state['stage']=name;save()
 with (run/(name+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
   item['status']='failed';save();raise
 item.update(status='passed' if rc==0 else 'failed',exit_code=rc,finished_at=time.time());save()
 if rc:raise RuntimeError(name+' failed')
save()
try:
 paths=subprocess.check_output(['git','ls-files','-co','--exclude-standard','rebirth/R','rebirth/src/rust','rebirth/tests/testthat','rebirth/src/llama.cpp'],cwd=repo,text=True).splitlines()
 (run/'source-manifest.json').write_text(json.dumps({p:hashlib.sha256((repo/p).read_bytes()).hexdigest() for p in sorted(set(paths)) if (repo/p).is_file()},indent=2)+'\n')
 stage('format',['cargo','fmt','--all','--check'])
 stage('format-ffi',['rustfmt','--check','--edition','2021','rebirth-ffi/src/async_boundary.rs'])
 stage('clippy',['cargo','clippy','--locked','--offline','--workspace','--all-targets','--','-D','warnings'])
 stage('engine',['cargo','test','--locked','--offline','-p','rebirth-llm'],timeout=1800)
 stage('ffi',['cargo','test','--locked','--offline','-p','rebirth-ffi','--lib'],timeout=1800)
 stage('install',['R','CMD','INSTALL','--no-multiarch','--library='+str(root/'d039-library'),str(repo/'rebirth')],cwd=repo,timeout=3600)
 stage('r-tests',['Rscript','--vanilla',str(root/'r-d039.R')],cwd=repo,timeout=1800)
 state['status']='passed'
except Exception as exc:state.update(status='failed',error=str(exc),traceback=traceback.format_exc())
finally:state['finished_at']=time.time();save()
