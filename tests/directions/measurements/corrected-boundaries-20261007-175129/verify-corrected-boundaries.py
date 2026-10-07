from pathlib import Path
import fcntl,hashlib,json,os,shutil,signal,subprocess,time,traceback
root=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); scratch=Path('/private/tmp/relm-f6d')
lock=(scratch/'pipeline.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
run=scratch/('corrected-boundaries-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
state=dict(status='running',pid=os.getpid(),directory=str(run),started_at=time.time(),stages=[])
env=os.environ.copy();env['R_LIBS']=':'.join([str(scratch/'library'),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
env['RELM_F6D_EVIDENCE']=str(run)
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
 stage('fixture-mirror',['python3','tests/directions/check-fixture-mirror.py'])
 stage('documentation',['Rscript','--vanilla','-e',"roxygen2::roxygenise('rebirth',load_code=roxygen2::load_installed)"])
 paths=[]
 for d in ['rebirth/R','rebirth/man','rebirth/inst','rebirth/tests/testthat']:
  paths.extend(p for p in (root/d).rglob('*') if p.is_file())
 paths.extend(root/'rebirth'/p for p in ['DESCRIPTION','NAMESPACE','NEWS.md'])
 manifest={str(p.relative_to(root)):sha(p) for p in sorted(paths)}
 (run/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 for p in (root/'rebirth/R').glob('direction*.R'):
  dest=run/'source'/p.relative_to(root);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
 for p in (root/'rebirth/tests/testthat').glob('*direction*.R'):
  dest=run/'source'/p.relative_to(root);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
 for name in ['verify-corrected-boundaries.py','corrected-tests.R']:shutil.copy2(scratch/name,run/name)
 native=Path('/private/tmp/relm-f6b/library/relm/libs/relm.so')
 assert sha(native)=='6edc6e6d512bb16e9d5ad8ed22093291e61a81bb89e5c2d07bee134db6ff04ac'
 state['native']={'path':str(native),'sha256':sha(native),'scope':'Unchanged accepted F6b DLL; no native build or renewed acceptance.'}
 lib=scratch/'library';lib.mkdir(exist_ok=True);assert (lib/'relm').exists(),'Corrected R install reuses isolated F6d library; native bytes unchanged'
 package=run/'r-install-source';package.mkdir()
 for d in ['R','man','inst']:shutil.copytree(root/'rebirth'/d,package/d)
 for name in ['DESCRIPTION','NAMESPACE','LICENSE','NEWS.md']:shutil.copy2(root/'rebirth'/name,package/name)
 binary=package/'inst/libs';binary.mkdir();shutil.copy2(native,binary/'relm.so')
 stage('install',['R','CMD','INSTALL','--no-configure','--no-libs','--library='+str(lib),str(package)])
 assert sha(lib/'relm/libs/relm.so')==sha(native)
 (run/'installed-manifest.json').write_text(json.dumps({str(p.relative_to(lib/'relm')):sha(p) for p in sorted((lib/'relm').rglob('*')) if p.is_file()},indent=2)+'\n')
 stage('installed-tests',['Rscript','--vanilla',str(scratch/'corrected-tests.R')])
 state['source_drift']=[p for p,h in manifest.items() if sha(root/p)!=h];assert not state['source_drift']
 state['status']='passed'
except Exception as e:state.update(status='failed',error=str(e),traceback=traceback.format_exc())
finally:state['finished_at']=time.time();save()
