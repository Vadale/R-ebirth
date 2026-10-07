from pathlib import Path
import fcntl,hashlib,json,os,shutil,signal,subprocess,time,traceback
root=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); scratch=Path('/private/tmp/relm-f6d')
lock=(scratch/'pipeline.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
run=scratch/('docs-check-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
state=dict(status='running',pid=os.getpid(),directory=str(run),started_at=time.time(),stages=[])
env=os.environ.copy();env['R_LIBS']=':'.join([str(scratch/'library'),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
env['RELM_F6D_EVIDENCE']=str(run)
env['PATH']='/Applications/RStudio.app/Contents/Resources/app/quarto/bin:'+env['PATH']
env['DENO_DIR']=str(scratch/'deno-cache')
for k in list(env):
 if k.startswith(('RELM_TEST_MODEL','RELM_TEST_MMPROJ')):env.pop(k)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save():
 data=json.dumps(state,indent=2)+'\n';(run/'status.json').write_text(data); p=scratch/'active-status.tmp';p.write_text(data);p.replace(scratch/'active-status.json')
def stage(name,cmd,timeout=600,cwd=root):
 item=dict(name=name,command=cmd,status='running');state['stages'].append(item);state['stage']=name;save()
 with (run/(name+'.log')).open('w') as f:
  p=subprocess.Popen(cmd,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);item['pid']=p.pid;save()
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
 runtime=json.loads((previous/'source-manifest.json').read_text())
 assert all(sha(root/p)==h for p,h in runtime.items() if p.startswith('rebirth/R/') or p in ['rebirth/NAMESPACE','rebirth/DESCRIPTION'])
 paths=[]
 for d in ['rebirth/R','rebirth/man','rebirth/inst','rebirth/tests/testthat','rebirth/vignettes']:
  paths.extend(p for p in (root/d).rglob('*') if p.is_file() and '/.quarto/' not in str(p) and '_files/' not in str(p))
 paths.extend(root/'rebirth'/p for p in ['DESCRIPTION','NAMESPACE','NEWS.md'])
 manifest={str(p.relative_to(root)):sha(p) for p in sorted(paths)}
 (run/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 shutil.copy2(scratch/'verify-docs.py',run/'verify-docs.py')
 qmd=root/'rebirth/vignettes/contrast-directions.qmd';shutil.copy2(qmd,run/qmd.name)
 stage('vignette',['quarto','render',qmd.name,'--to','html'],timeout=600,cwd=run)
 stage('source-build',['R','CMD','build','--no-build-vignettes','--no-manual',str(root/'rebirth')],timeout=600,cwd=run)
 tar=list(run.glob('relm_*.tar.gz'));assert len(tar)==1
 stage('scoped-check',['R','CMD','check','--no-install','--no-tests','--no-vignettes','--no-manual','--library='+str(scratch/'library'),str(tar[0])],timeout=600,cwd=run)
 check=(run/'relm.Rcheck/00check.log').read_text()
 assert 'Status: 2 WARNINGs' in check and ' ERROR' not in check and ' NOTE' not in check, check[-1500:]
 state['scoped_check']={'errors':0,'warnings':2,'notes':0,'scope':'Full rendered vignettes deliberately omitted; new vignette executed separately; installed tests recorded separately.'}
 state['source_drift']=[p for p,h in manifest.items() if sha(root/p)!=h];assert not state['source_drift']
 state['status']='passed'
except Exception as e:state.update(status='failed',error=str(e),traceback=traceback.format_exc())
finally:state['finished_at']=time.time();save()
