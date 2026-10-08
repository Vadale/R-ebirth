import csv,fcntl,hashlib,json,os,re,shutil,signal,subprocess,tarfile,time,traceback
from pathlib import Path
ROOT=Path('/private/tmp/relm-f6e');REPO=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 lock=(ROOT/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 bind=json.loads((ROOT/'installed-public-budget-binding.json').read_text());assert all(sha(Path(p))==h for p,h in bind['files'].items());assert all(sha(REPO/p)==h for p,h in bind['native_sources'].items())
 native=Path(bind['native']['path']);assert sha(native)==bind['native']['sha256'];model=Path(bind['model']['path']);assert sha(model)==bind['model']['sha256']
 run=ROOT/('installed-public-budget-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir();lib=ROOT/'public-library-budget';lib.mkdir(exist_ok=True);assert not (lib/'relm').exists(),'Fresh public library must not overwrite a prior installation.'
 st={'status':'running','pid':os.getpid(),'directory':str(run),'stages':[],'scope':'Fresh R installation with exact current accepted default F6e DLL; 27 remaining public CPU/Metal operational checks with retained four captures, not behavioral evaluation','native':bind['native']}
 def save():
  raw=json.dumps(st,indent=2)+'\n';(run/'status.json').write_text(raw);tmp=ROOT/'installed-public-status.tmp';tmp.write_text(raw);tmp.replace(ROOT/'installed-public-status.json')
 save();env=os.environ.copy();env['R_LIBS']=':'.join([str(lib),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library']);env['F6E_EXPECT_LIBRARY']=str(lib/'relm');env['F6E_PUBLIC_PARENT']=bind['parent_directory']
 for key in list(env):
  if key.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_')):env.pop(key)
 def stage(name,cmd,timeout=600):
  row={'name':name,'command':cmd,'status':'running'};st['stages'].append(row);st['stage']=name;save()
  with (run/(name+'.log')).open('w') as out:
   p=subprocess.Popen(cmd,cwd=REPO,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True);row['pid']=p.pid;save()
   try:code=p.wait(timeout=timeout)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=10);raise
  row.update(status='passed' if code==0 else 'failed',exit_code=code,log_sha256=sha(run/(name+'.log')));save();assert code==0,name+' failed; preserve and diagnose before affected-only correction'
  return (run/(name+'.log')).read_text()
 manifest={};installed={}
 try:
  assert all(sha(Path(bind['parent_directory'])/p)==h for p,h in bind['carried_files'].items())
  for path in bind['files']:shutil.copy2(path,run/Path(path).name)
  shutil.copy2(ROOT/'installed-public-budget-binding.json',run/'owner-binding.json')
  parent=ROOT/'installed-public-20261008-044755'
  previous=json.loads((parent/'source-manifest.json').read_text())
  assert sha(REPO/'rebirth/R/extendr-wrappers.R')==previous['rebirth/R/extendr-wrappers.R']
  shutil.copy2(parent/'wrappers.log',run/'carried-wrappers.log')
  shutil.copy2(parent/'owner-failure-verification.json',run/'carried-owner-failure-verification.json')
  approved=subprocess.check_output(['git','show','HEAD:rebirth/NAMESPACE'],cwd=REPO)
  assert (REPO/'rebirth/NAMESPACE').read_bytes()==approved,'Approved exports and S3 registrations must be unchanged'
  old_help=subprocess.check_output(['git','ls-tree','-r','--name-only','HEAD','rebirth/man'],cwd=REPO,text=True).splitlines()
  assert all((REPO/x).is_file() for x in old_help),'Approved help topics must remain'
  assert 'operator = "add"' in (REPO/'rebirth/man/llm_apply_direction.Rd').read_text()
  paths=[]
  for d in ['R','man','inst']:paths.extend(p for p in (REPO/'rebirth'/d).rglob('*') if p.is_file())
  paths.extend(REPO/'rebirth'/n for n in ['DESCRIPTION','NAMESPACE','LICENSE','NEWS.md'])
  manifest={str(p.relative_to(REPO)):sha(p) for p in sorted(paths)};manifest.update(bind['native_sources'])
  (run/'source-manifest.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n');st['source_manifest_sha256']=sha(run/'source-manifest.json');st['source_count']=len(manifest);save()
  with tarfile.open(run/'R-source.tar.gz','w:gz') as tar:
   for p in sorted(manifest):
    if p.startswith(('rebirth/R/','rebirth/man/')) or p in ['rebirth/DESCRIPTION','rebirth/NAMESPACE']:tar.add(REPO/p,arcname=p)
  package=run/'r-install-source';package.mkdir()
  for d in ['R','man','inst']:shutil.copytree(REPO/'rebirth'/d,package/d)
  for n in ['DESCRIPTION','NAMESPACE','LICENSE','NEWS.md']:shutil.copy2(REPO/'rebirth'/n,package/n)
  dest=package/'inst/libs';dest.mkdir();shutil.copy2(native,dest/'relm.so')
  stage('install',['R','CMD','INSTALL','--no-configure','--no-libs','--library='+str(lib),str(package)])
  assert sha(lib/'relm/libs/relm.so')==sha(native)
  # Matching-namespace documentation already passed at the parent source.
  # Neither comments/signatures nor generated docs changed in the OOM correction.
  parent_docs=Path(bind['parent_directory'])
  assert (parent_docs/'documentation-installed.log').read_bytes()==b''
  shutil.copy2(parent_docs/'documentation-installed.log',run/'carried-documentation-installed.log')
  shutil.copy2(parent_docs/'owner-partial-verification.json',run/'carried-installed-owner-verification.json')
  for name,h in bind['carried_files'].items():
   assert sha(parent_docs/name)==h,name
   shutil.copy2(parent_docs/name,run/('carried-'+name))
  assert all(sha(REPO/p)==h for p,h in manifest.items())

  installed={str(p.relative_to(lib/'relm')):sha(p) for p in sorted((lib/'relm').rglob('*')) if p.is_file()};(run/'installed-manifest.json').write_text(json.dumps(installed,indent=2)+'\n')
  check="library(relm);stopifnot(normalizePath(find.package('relm'))==normalizePath(Sys.getenv('F6E_EXPECT_LIBRARY')));e<-new.env(parent=baseenv());for(f in list.files('rebirth/R',full.names=TRUE,pattern='[.]R$')) sys.source(f,e);n<-ls(e,all.names=TRUE);for(k in n) if(is.function(e[[k]])) {a<-get(k,asNamespace('relm'),inherits=FALSE);stopifnot(identical(formals(a),formals(e[[k]])),identical(body(a),body(e[[k]])))};codetools::checkUsagePackage('relm');cat('F6E_INSTALLED_SOURCE_FORMALS_BODIES_MATCH functions=',sum(vapply(mget(n,e),is.function,logical(1))), '\\n',sep='')"
  log=stage('installed-source-usage',['Rscript','--vanilla','-e',check]);assert 'F6E_INSTALLED_SOURCE_FORMALS_BODIES_MATCH functions=' in log
  # External built-under patch warnings are retained; codetools diagnostics may
  # not be silently suppressed by this driver.
  assert not re.search(r'no visible|defined but not used|possible error|local variable.*not used',log)
  log=stage('public-model',['Rscript','--vanilla',str(ROOT/'check-installed-public-remaining.R'),str(model),str(run)],timeout=900)
  expected=(run/'expected-cases.txt').read_text().splitlines();rows=list(csv.DictReader((run/'public-cases.csv').open()));assert expected==bind['expected_cases'] and len(expected)==27 and [x['case'] for x in rows]==expected
  assert all(x['status']=='passed' for x in rows) and sum(x['refusal']=='TRUE' for x in rows)==6
  assert log.count('F6E_INSTALLED_PUBLIC_REMAINING cases=27 refusals=6 backend_handles=cpu,metal no_download=TRUE carried_parent_cases=10')==1
  assert re.findall(r'^F6E_PUBLIC_CASE (\S+) refusal=(?:TRUE|FALSE)$',log,re.M)==expected
  assert not re.search(r'^(?:Warning|warning|Error|error)',log,re.M)
  st.update(status='awaiting_owner_verification',cases=27,refusals=6,carried_parent_cases=10,new_model_loads=2,behavioral_evaluation=False)
 except Exception as e:st.update(status='failed',error=str(e),traceback=traceback.format_exc())
 finally:
  st['source_drift']=[p for p,h in manifest.items() if not (REPO/p).is_file() or sha(REPO/p)!=h]
  st['installed_drift']=[p for p,h in installed.items() if not (lib/'relm'/p).is_file() or sha(lib/'relm'/p)!=h]
  if st['source_drift'] or st['installed_drift']:st['status']='failed'
  st['finished_at']=time.time();save()
if __name__=='__main__':main()
