from pathlib import Path
import fcntl,hashlib,json,os,shutil,signal,subprocess,time,traceback
root=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); scratch=Path('/private/tmp/relm-f6d')
lock=(scratch/'pipeline.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
run=scratch/('evaluation-resume-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
state=dict(status='running',pid=os.getpid(),directory=str(run),started_at=time.time(),stages=[])
env=os.environ.copy();env['R_LIBS']=':'.join([str(scratch/'library'),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
env['RELM_F6D_EVIDENCE']=str(run)
env['RELM_F6D_CONSTRUCTION']=str(scratch/'model-evaluation-20261007-175741')
for k in list(env):
 if k.startswith(('RELM_TEST_MODEL','RELM_TEST_MMPROJ')):env.pop(k)
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
 accepted=json.loads((previous/'independent-verification.json').read_text());assert accepted['status']=='passed'
 installed=json.loads((previous/'installed-manifest.json').read_text())
 assert all(sha(scratch/'library/relm'/p)==h for p,h in installed.items())
 runtime=json.loads((previous/'source-manifest.json').read_text())
 assert all(sha(root/p)==h for p,h in runtime.items() if p.startswith('rebirth/R/') or p in ['rebirth/NAMESPACE','rebirth/DESCRIPTION'])
 paths=list((root/'rebirth/R').glob('*.R'))+list((root/'tests/directions/evaluation').glob('*'))+[root/'docs/f6d-evaluation-protocol.md',root/'tests/directions/run-evaluation.R']
 manifest={str(p.relative_to(root)):sha(p) for p in sorted(paths) if p.is_file()}
 (run/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 (run/'installed-manifest.json').write_text(json.dumps(installed,indent=2)+'\n')
 for p in paths:
  if p.is_file():
   dest=run/'source'/p.relative_to(root);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
 shutil.copy2(scratch/'verify-evaluation-resume.py',run/'verify-evaluation-resume.py')
 stage('fixed-evaluation',['Rscript','--vanilla',str(root/'tests/directions/run-evaluation.R')],timeout=1800)
 log=(run/'fixed-evaluation.log').read_text()
 assert (run/'parent-construction-scope.txt').exists() and 'F6D_FIXED_EVALUATION_PASSED' in log
 state['source_drift']=[p for p,h in manifest.items() if sha(root/p)!=h];assert not state['source_drift']
 state['status']='passed_pending_independent_verification'
except Exception as e:state.update(status='failed',error=str(e),traceback=traceback.format_exc())
finally:state['finished_at']=time.time();save()
