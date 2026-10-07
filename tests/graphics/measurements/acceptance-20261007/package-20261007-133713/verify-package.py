from pathlib import Path
import fcntl,hashlib,json,os,shutil,signal,subprocess,time,traceback
root=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); scratch=Path('/private/tmp/relm-f6c')
lock=(scratch/'package.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
run=scratch/('package-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
state=dict(status='running',pid=os.getpid(),directory=str(run),started_at=time.time(),stages=[])
env=os.environ.copy(); env['R_LIBS']=':'.join([str(scratch/'library'),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
env['RELM_F6C_EVIDENCE']=str(run);env['PATH']='/Applications/RStudio.app/Contents/Resources/app/quarto/bin:'+env['PATH']
for k in list(env):
 if k.startswith(('RELM_TEST_MODEL','RELM_TEST_MMPROJ')):env.pop(k)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save():
 data=json.dumps(state,indent=2)+'\n';(run/'status.json').write_text(data)
 p=scratch/'active-status.tmp';p.write_text(data);p.replace(scratch/'active-status.json')
def stage(name,cmd,cwd=root,timeout=600):
 item=dict(name=name,command=cmd,status='running');state['stages'].append(item);state['stage']=name;save()
 with (run/(name+'.log')).open('w') as f:
  p=subprocess.Popen(cmd,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  item['pid']=p.pid;save()
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGTERM);rc=p.wait(timeout=10);raise RuntimeError(name+' timeout')
 item.update(status='passed' if rc==0 else 'failed',exit_code=rc);save()
 if rc:raise RuntimeError(name+' failed')
try:
 save(); paths=[]
 for d in ['rebirth/R','rebirth/man','rebirth/inst','rebirth/tests/testthat','rebirth/vignettes']:
  paths.extend(p for p in (root/d).rglob('*') if p.is_file() and '/.quarto/' not in str(p) and '_files/' not in str(p))
 paths.extend(root/'rebirth'/p for p in ['DESCRIPTION','NAMESPACE','NEWS.md'])
 manifest={str(p.relative_to(root)):sha(p) for p in sorted(paths)}
 (run/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 for name in ['verify-package.py','installed-tests.R','model-composition.R','render-installed.R']:
  shutil.copy2(scratch/name,run/name)
 native=Path('/private/tmp/relm-f6b/library/relm/libs/relm.so')
 assert sha(native)=='6edc6e6d512bb16e9d5ad8ed22093291e61a81bb89e5c2d07bee134db6ff04ac'
 state['native']=dict(path=str(native),sha256=sha(native),scope='Accepted F6b DLL reused unchanged. No native compilation or renewed native acceptance.')
 lib=scratch/'library';lib.mkdir(exist_ok=True);assert not (lib/'relm').exists(),'Fresh library required'
 package=run/'r-install-source';package.mkdir()
 for d in ['R','man','inst']:shutil.copytree(root/'rebirth'/d,package/d)
 for name in ['DESCRIPTION','NAMESPACE','LICENSE','NEWS.md']:shutil.copy2(root/'rebirth'/name,package/name)
 binary=package/'inst/libs';binary.mkdir();shutil.copy2(native,binary/'relm.so')
 stage('install',['R','CMD','INSTALL','--no-configure','--no-libs','--library='+str(lib),str(package)])
 assert sha(lib/'relm/libs/relm.so')==sha(native)
 (run/'installed-files.json').write_text(json.dumps({str(p.relative_to(lib/'relm')):sha(p) for p in sorted((lib/'relm').rglob('*')) if p.is_file()},indent=2)+'\n')
 stage('installed-tests',['Rscript','--vanilla',str(scratch/'installed-tests.R')])
 stage('model-composition',['Rscript','--vanilla',str(scratch/'model-composition.R')],timeout=300)
 stage('visual',['Rscript','--vanilla',str(scratch/'render-installed.R')])
 stage('vignette',['quarto','render','rebirth/vignettes/model-interventions.qmd','--to','html'],timeout=600)
 stage('source-build',['R','CMD','build','--no-build-vignettes','--no-manual',str(root/'rebirth')],cwd=run)
 tar=list(run.glob('relm_*.tar.gz'));assert len(tar)==1
 stage('scoped-check',['R','CMD','check','--no-install','--no-tests','--no-vignettes','--no-manual','--library='+str(lib),str(tar[0])],cwd=run)
 state['source_drift']=[p for p,h in manifest.items() if sha(root/p)!=h]
 assert not state['source_drift']
 state['status']='passed'
except Exception as e:state.update(status='failed',error=str(e),traceback=traceback.format_exc())
finally:state['finished_at']=time.time();save()
