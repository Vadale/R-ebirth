from pathlib import Path
import fcntl,hashlib,json,os,shutil,signal,subprocess,time,traceback
root=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); scratch=Path('/private/tmp/relm-f6d')
lock=(scratch/'pipeline.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
run=scratch/('model-reset-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
state=dict(status='running',pid=os.getpid(),directory=str(run),started_at=time.time(),stages=[])
env=os.environ.copy();env['R_LIBS']=':'.join([str(scratch/'library'),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
env['RELM_F6D_EVIDENCE']=str(run)
env['RELM_TEST_MODEL_QWEN']='/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save():
 data=json.dumps(state,indent=2)+'\n';(run/'status.json').write_text(data); p=scratch/'active-status.tmp';p.write_text(data);p.replace(scratch/'active-status.json')
def stage(name,cmd,timeout=600):
 item=dict(name=name,command=cmd,status='running');state['stages'].append(item);state['stage']=name;save()
 with (run/(name+'.log')).open('w') as f:
  p=subprocess.Popen(cmd,cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);item['pid']=p.pid;save()
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=10);raise RuntimeError(name+' timeout')
 item.update(status='passed' if rc==0 else 'failed',exit_code=rc);save()
 if rc:raise RuntimeError(name+' failed')
try:
 save()
 previous=scratch/'corrected-boundaries-20261007-175129'
 installed=json.loads((previous/'installed-manifest.json').read_text())
 assert all(sha(scratch/'library/relm'/p)==h for p,h in installed.items())
 paths=list((root/'rebirth/R').glob('direction*.R'))+[root/'rebirth/tests/testthat/test-directions-model.R',root/'rebirth/tests/testthat/fixtures/direction-qwen.rds']
 manifest={str(p.relative_to(root)):sha(p) for p in paths};(run/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 shutil.copy2(scratch/'verify-model-reset.py',run/'verify-model-reset.py');shutil.copy2(scratch/'model-reset.R',run/'model-reset.R')
 stage('model-reset',['Rscript','--vanilla',str(scratch/'model-reset.R')],timeout=180)
 state['source_drift']=[p for p,h in manifest.items() if sha(root/p)!=h];assert not state['source_drift']
 state['status']='passed'
except Exception as e:state.update(status='failed',error=str(e),traceback=traceback.format_exc())
finally:state['finished_at']=time.time();save()
