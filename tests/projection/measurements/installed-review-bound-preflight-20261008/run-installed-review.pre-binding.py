"""Affected installed review gate; bind only after independent native acceptance."""
import csv,fcntl,hashlib,importlib.util,json,os,re,shutil,signal,subprocess,tarfile,time,traceback
from pathlib import Path
ROOT=Path('/private/tmp/relm-f6e');REPO=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 lock=(ROOT/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 bind=json.loads((ROOT/'installed-review-binding.json').read_text())
 for p,h in {**bind['files'],**bind['dependency_files']}.items():assert sha(Path(p))==h,p
 for p,h in bind['source_hashes'].items():assert sha(REPO/p)==h,p
 owner=json.loads(Path(bind['native_owner']['path']).read_text())
 assert sha(Path(bind['native_owner']['path']))==bind['native_owner']['sha256'] and owner['status']=='passed'
 native=Path(bind['native']['path']);assert sha(native)==bind['native']['sha256']
 run=ROOT/('installed-review-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
 lib=ROOT/'public-library-review';lib.mkdir(exist_ok=True);assert not (lib/'relm').exists()
 st={'status':'running','pid':os.getpid(),'directory':str(run),'stages':[],
     'scope':'Fresh corrected installed library: zero/live capture and real R GC registry reuse only; no efficacy or old public suite'}
 def save():
  raw=json.dumps(st,indent=2)+'\n';(run/'status.json').write_text(raw)
  temp=ROOT/'installed-review-status.tmp';temp.write_text(raw);temp.replace(ROOT/'installed-review-status.json')
 save();env=os.environ.copy();env['R_LIBS']=':'.join([str(lib),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
 for k in list(env):
  if k.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_','F6E_MODEL')):env.pop(k)
 def stage(name,cmd,timeout=600):
  row={'name':name,'command':cmd,'status':'running'};st['stage']=name;st['stages'].append(row);save()
  with (run/(name+'.log')).open('w') as out:
   p=subprocess.Popen(cmd,cwd=REPO,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True);row['pid']=p.pid;save()
   try:code=p.wait(timeout=timeout)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=10);raise
  row.update(exit_code=code,status='passed' if code==0 else 'failed',log_sha256=sha(run/(name+'.log')));save()
  assert code==0,name+' failed; preserve and diagnose before any affected correction'
  return (run/(name+'.log')).read_text()
 sources={};installed={}
 try:
  sources=dict(bind['source_hashes'])
  for directory in ['R','man','inst']:
   for p in (REPO/'rebirth'/directory).rglob('*'):
    if p.is_file():sources[str(p.relative_to(REPO))]=sha(p)
  for n in ['DESCRIPTION','NAMESPACE','LICENSE','NEWS.md']:sources['rebirth/'+n]=sha(REPO/'rebirth'/n)
  (run/'source-manifest.json').write_text(json.dumps(sources,indent=2)+'\n')
  shutil.copy2(ROOT/'installed-review-binding.json',run/'owner-binding.json')
  for p in bind['files']:shutil.copy2(p,run/Path(p).name)
  with tarfile.open(run/'source.tar.gz','w:gz') as tar:
   for p in sources:
    if not p.startswith(('rebirth/src/llama.cpp/','tests/llm-golden/')):tar.add(REPO/p,arcname=p)
  package=run/'package-source';package.mkdir()
  for d in ['R','man','inst']:shutil.copytree(REPO/'rebirth'/d,package/d)
  for n in ['DESCRIPTION','NAMESPACE','LICENSE','NEWS.md']:shutil.copy2(REPO/'rebirth'/n,package/n)
  dest=package/'inst/libs';dest.mkdir();shutil.copy2(native,dest/'relm.so')
  stage('install',['R','CMD','INSTALL','--no-configure','--no-libs','--library='+str(lib),str(package)])
  assert sha(lib/'relm/libs/relm.so')==sha(native)
  installed={str(p.relative_to(lib/'relm')):sha(p) for p in (lib/'relm').rglob('*') if p.is_file()}
  (run/'installed-manifest.json').write_text(json.dumps(installed,indent=2)+'\n')
  code="library(relm);stopifnot(normalizePath(find.package('relm'))==normalizePath('"+str(lib/'relm')+"'));e<-new.env(parent=baseenv());for(f in list.files('rebirth/R',full.names=TRUE,pattern='[.]R$')) sys.source(f,e);n<-ls(e,all.names=TRUE);for(k in n) if(is.function(e[[k]])) {a<-get(k,asNamespace('relm'),inherits=FALSE);stopifnot(identical(formals(a),formals(e[[k]])),identical(body(a),body(e[[k]])))};stopifnot(packageVersion('later')=='1.4.8',packageVersion('promises')=='1.5.0');codetools::checkUsagePackage('relm');cat('F6E_INSTALLED_REVIEW_SOURCE functions=',sum(vapply(mget(n,e),is.function,logical(1))),'\\n',sep='')"
  text=stage('installed-source',['Rscript','--vanilla','-e',code]);assert text.strip()=='F6E_INSTALLED_REVIEW_SOURCE functions=259'
  config=dict(bind['config']);config.update(library=str(lib/'relm'),dll_sha256=sha(native))
  (run/'config.json').write_text(json.dumps(config,indent=2)+'\n')
  text=stage('installed-affected',['Rscript','--vanilla',str(REPO/'tests/projection/installed_review.R'),str(run/'config.json'),str(run)],timeout=900)
  receipt=json.loads((run/'receipt.json').read_text());assert receipt['status']=='awaiting_owner_verification'
  assert receipt['cases']==10 and receipt['coordinates']==1792 and receipt['attempts']==dict(load=1,derive=13,generate=3,trace=0,logits=0,tokenize=0)
  rows=list(csv.DictReader((run/'cases.csv').open()));assert [r['case'] for r in rows]==bind['expected_cases'] and all(r['status']=='passed' for r in rows)
  assert re.findall(r'^F6E_INSTALLED_REVIEW_CASE (\S+)$',text,re.M)==bind['expected_cases']
  assert text.splitlines().count('F6E_INSTALLED_REVIEW_COMPLETE cases=10 coordinates=1792 load_attempts=1 derive_attempts=13 generation_attempts=3')==1
  assert not re.search(r'^(?:Warning|warning|Error|error)',text,re.M)
  spec=importlib.util.spec_from_file_location('evaluation_collector',REPO/'tests/projection/evaluation/collect_run.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
  cpu=c.cpu_receipt((run/'native-placement.log').read_bytes(),bind['tokenizer_diagnosis'])
  (run/'cpu-receipt.json').write_text(json.dumps(cpu,indent=2)+'\n')
  st.update(status='awaiting_owner_verification',receipt=receipt,native_sha256=sha(native))
 except Exception as error:st.update(status='failed',error=str(error),traceback=traceback.format_exc())
 finally:
  st['source_drift']=[p for p,h in sources.items() if not (REPO/p).is_file() or sha(REPO/p)!=h]
  st['installed_drift']=[p for p,h in installed.items() if not (lib/'relm'/p).is_file() or sha(lib/'relm'/p)!=h]
  st['dependency_drift']=[p for p,h in bind['dependency_files'].items() if not Path(p).is_file() or sha(Path(p))!=h]
  if any(st[k] for k in ['source_drift','installed_drift','dependency_drift']):st['status']='failed'
  st['finished_at']=time.time();save()
if __name__=='__main__':main()
