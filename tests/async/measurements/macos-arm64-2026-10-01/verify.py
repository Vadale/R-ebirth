"""Durable, single-owner WP9 verification; no interactive polling."""
import json, os, subprocess, time, traceback, fcntl
from pathlib import Path
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
root=Path('/private/tmp/relm-wp9')
phase=os.environ.get('RELM_WP9_PHASE','compile')
job_lock=(root/'verification.lock').open('w')
try: fcntl.flock(job_lock.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: raise SystemExit('Another WP9 verification process owns the build pipeline')
status={'status':'running','phase':phase,'pid':os.getpid(),'started_at':time.time(),'stages':[]}
env=os.environ.copy()
env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip()
env['RUST_TEST_THREADS']='1'
env['R_LIBS']=':'.join([str(root/'library'),'/private/tmp/relm-service/library','/private/tmp/relm-maintenance-2026-09-27/R-library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
def save():
 path=root/(phase+'-status.tmp');path.write_text(json.dumps(status,indent=2)+'\n');path.replace(root/(phase+'-status.json'))
def stage(name,cmd,cwd=repo/'rebirth/src/rust',timeout=1800):
 item={'name':name,'command':cmd,'started_at':time.time(),'status':'running'}
 status['stage']=name;status['stages'].append(item);save()
 with (root/(phase+'-'+name+'.log')).open('w') as out:
  done=subprocess.run(cmd,cwd=cwd,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=timeout)
 item.update(status='passed' if done.returncode==0 else 'failed',exit_code=done.returncode,finished_at=time.time());save()
 if done.returncode:raise RuntimeError(name+' failed; inspect its retained log')
try:
 if phase=='compile':
  stage('check',['cargo','check','--locked','--offline','--workspace','--all-targets'])
 elif phase=='rust':
  stage('clippy',['cargo','clippy','--locked','--offline','--workspace','--all-targets','--','-D','warnings'])
  stage('async-debug',['cargo','test','--locked','--offline','-p','rebirth-llm','async'])
  stage('async-release',['cargo','test','--locked','--offline','--release','-p','rebirth-llm','async'])
  stage('engine',['cargo','test','--locked','--offline','-p','rebirth-llm'])
  stage('ffi',['cargo','test','--locked','--offline','-p','rebirth-ffi'])
 elif phase=='acceptance':
  stage('clippy',['cargo','clippy','--locked','--offline','--workspace','--all-targets','--','-D','warnings'])
  cache=Path('/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm')
  env['RELM_REQUIRE_ASYNC_VLM']='1'
  env['RELM_TEST_MODEL_VLM']=str(cache/'Qwen2-VL-2B-Instruct-Q4_K_M.gguf')
  env['RELM_TEST_MMPROJ_VLM']=str(cache/'mmproj-Qwen2-VL-2B-Instruct-f16.gguf')
  assert all(Path(env[key]).is_file() for key in ['RELM_TEST_MODEL_VLM','RELM_TEST_MMPROJ_VLM'])
  stage('vision-boundaries',['cargo','test','--locked','--offline','-p','rebirth-llm','--lib','async_vlm_cancel_and_drop_at_native_boundaries','--','--nocapture'],timeout=900)
  assert 'ASYNC_VLM_BOUNDARIES_PASSED' in (root/'acceptance-vision-boundaries.log').read_text(), 'VLM gate did not execute'
  env.pop('RELM_TEST_MODEL_VLM');env.pop('RELM_TEST_MMPROJ_VLM')
  (root/'library').mkdir(exist_ok=True)
  stage('install',['R','CMD','INSTALL','--no-multiarch','--library='+str(root/'library'),str(repo/'rebirth')],cwd=repo,timeout=5400)
  stage('async-tests',['Rscript','--vanilla',str(root/'async-tests.R')],cwd=repo,timeout=1800)
 elif phase=='r-corrected':
  stage('install',['R','CMD','INSTALL','--no-multiarch','--library='+str(root/'library'),str(repo/'rebirth')],cwd=repo,timeout=1800)
  stage('async-tests',['Rscript','--vanilla',str(root/'async-tests.R')],cwd=repo,timeout=1800)
 elif phase=='integration':
  stage('package-tests',['Rscript','--vanilla',str(root/'integration.R')],cwd=repo,timeout=1800)
  stage('source-build',['R','CMD','build','--no-build-vignettes','--no-manual',str(repo/'rebirth')],cwd=root,timeout=600)
  stage('package-check',['R','CMD','check','--no-install','--no-tests','--no-vignettes','--no-manual','--library='+str(root/'library'),str(root/'relm_0.3.0.tar.gz')],cwd=root,timeout=900)
 elif phase=='install':
  (root/'library').mkdir(exist_ok=True)
  stage('install',['R','CMD','INSTALL','--no-multiarch','--library='+str(root/'library'),str(repo/'rebirth')],cwd=repo,timeout=5400)
 elif phase=='r-tests':
  stage('async-tests',['Rscript','--vanilla',str(root/'async-tests.R')],cwd=repo,timeout=1800)
 else:raise ValueError('unknown phase')
 status['status']='passed'
except Exception as exc:
 status['status']='failed';status['error']=str(exc)
 (root/(phase+'-error.log')).write_text(traceback.format_exc())
finally:
 status['finished_at']=time.time();save()
