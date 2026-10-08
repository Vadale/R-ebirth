"""One owner-controlled, model-free admission/profile run. Never arms projection."""
import csv,fcntl,hashlib,importlib.util,json,os,re,signal,subprocess,tarfile,time,traceback,shlex,shutil
from pathlib import Path
ROOT=Path('/private/tmp/relm-f6e');REPO=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');WORK=REPO/'rebirth/src/rust'
spec=importlib.util.spec_from_file_location('collector',ROOT/'ledger-collector.py');collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 lock=(ROOT/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 ready=json.loads((ROOT/'public-ledger-ready.json').read_text());assert ready['status']=='ready'
 for path,sha in ready['source_hashes'].items():assert digest(REPO/path)==sha,path
 revision=json.loads((ROOT/'ledger-revision-ready.json').read_text());assert revision['status']=='ready'
 assert ready['source_hashes']==revision['all_source_hashes']
 binding=json.loads((ROOT/'public-ledger-owner-binding.json').read_text())
 assert binding['collector_verified'] is True and binding['models']==0
 for path,sha in binding['files'].items():assert digest(Path(path))==sha,path
 run=ROOT/('public-ledger-resume-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
 state={'status':'running','pid':os.getpid(),'directory':str(run),'started_at':time.time(),'stages':[],
  'models':0,'production_armed':False,'scope':'new native admission/profile, independent R equations and strict boundary controls; constructor ownership still requires integration proof'}
 def save():
  raw=json.dumps(state,indent=2)+'\n';(run/'status.json').write_text(raw)
  tmp=ROOT/'ledger-status.tmp';tmp.write_text(raw);tmp.replace(ROOT/'ledger-status.json')
 env=os.environ.copy();env['RUST_TEST_THREADS']='1';env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip()
 for key in list(env):
  if key.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_','F6E_MODEL')) or key=='RELM_NATIVE_SANITIZERS':env.pop(key)
 env['F6E_LEDGER_RUN']=str(run)
 def stage(name,cmd,timeout=1800,cwd=WORK,extra_env=None):
  item={'name':name,'command':cmd,'status':'running','started_at':time.time()};state['stages'].append(item);state['stage']=name;save()
  path=run/(name+'.log')
  with path.open('w') as f:
   p=subprocess.Popen(cmd,cwd=cwd,env={**env,**(extra_env or {})},stdout=f,stderr=subprocess.STDOUT,start_new_session=True);item['pid']=p.pid;save()
   try:rc=p.wait(timeout=timeout)
   except subprocess.TimeoutExpired:
    os.killpg(p.pid,signal.SIGTERM)
    try:p.wait(timeout=10)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    item.update(status='failed',reason='timeout');save();raise
  item.update(status='passed' if rc==0 else 'failed',exit_code=rc,finished_at=time.time(),log_sha256=digest(path));save()
  if rc:raise RuntimeError(name+' failed; diagnose retained sources/log before an affected-only correction')
  return path.read_text()
 save();manifest={}
 try:
  paths=subprocess.check_output(['git','ls-files','-co','--exclude-standard','rebirth/src/rust','rebirth/src/entrypoint.c','rebirth/src/Makevars','rebirth/R','rebirth/tests/testthat/test-projection-memory.R','rebirth/tests/testthat/test-directions-boundaries.R','rebirth/tests/testthat/helper-directions.R'],cwd=REPO,text=True).splitlines()
  paths=sorted({p for p in paths if (REPO/p).is_file()}|set(ready['source_hashes']))
  manifest={p:digest(REPO/p) for p in paths};raw=json.dumps(manifest,sort_keys=True,indent=2)+'\n';(run/'source-manifest.json').write_text(raw)
  state['source_manifest_sha256']=hashlib.sha256(raw.encode()).hexdigest();state['source_count']=len(manifest)
  (run/'revision-ready.json').write_text(json.dumps(revision,indent=2)+'\n');(run/'ready.json').write_text(json.dumps(ready,indent=2)+'\n');(run/'owner-binding.json').write_text(json.dumps(binding,indent=2)+'\n')
  for p in binding['files']:(run/Path(p).name).write_bytes(Path(p).read_bytes())
  changed=set(subprocess.check_output(['git','diff','--name-only','HEAD'],cwd=REPO,text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard'],cwd=REPO,text=True).splitlines())
  with tarfile.open(run/'changed-source.tar.gz','w:gz') as tar:
   for p in sorted(changed.intersection(manifest)):tar.add(REPO/p,arcname=p)
  (run/'candidate.patch').write_bytes(subprocess.check_output(['git','diff','--binary','HEAD'],cwd=REPO))
  save()
  parent=ROOT/'public-ledger-20261008-003048'
  carry=json.loads((parent/'owner-partial-verification.json').read_text())
  assert carry['overall_attempt']=='failed' and carry['R_cases']==7 and carry['R_expectations']==229
  previous=json.loads((parent/'source-manifest.json').read_text())
  carried=[p for p in previous if p.startswith(('rebirth/R/','rebirth/tests/','rebirth/src/rust/rebirth-llm/'))]
  for p in carried:assert digest(REPO/p)==previous[p],p
  state['carried_R']={'source':str(parent),'cases':7,'expectations':229,'reexecuted':False}
  state['carried_llm_clippy']={'source':str(parent),'reexecuted':False}
  state['carried_source_count']=len(carried);save()
  stage('format',['cargo','fmt','--all','--check'])
  stage('clippy-ffi',['cargo','clippy','--locked','--offline','-p','rebirth-ffi','--all-targets','--','-D','warnings'])
  stage('no-spill-compile',['cargo','test','--locked','--offline','-p','rebirth-llm','--no-default-features','--lib','--no-run'])
  receipts=[]
  assert len(ready['tests'])==7
  native=[t for t in ready['tests'] if t['execution']=='cargo_libtest']
  hosted=[t for t in ready['tests'] if t['execution']=='r_hosted_internal_selftest']
  assert len(native)==6 and len(hosted)==1
  for n,test in enumerate(native,1):
   assert test['crate']=='rebirth-llm'
   log=stage(f'native-{n:02d}',['cargo','test','--locked','--offline','-p',test['crate'],'--lib',test['id'],'--','--exact','--nocapture','--test-threads=1'])
   receipts.append(collector.exact_test(log,test));(run/'native-test-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
  contract=revision['r_hosted_contract']
  assert contract['models']==0 and digest(Path(contract['entrypoint_source']))==contract['entrypoint_sha256']
  build=contract['build_command']+['--message-format=json']
  log=stage('ffi-static-build',build)
  records=[]
  for line in log.splitlines():
   if line.startswith('{'):
    row=json.loads(line)
    if row.get('reason')=='compiler-artifact' and row['target']['name']=='relm' and 'staticlib' in row['target']['crate_types']:records.append(row)
    if row.get('reason')=='compiler-message':assert row['message']['level']!='warning',row['message']
  assert len(records)==1,records
  archive=Path(contract['static_archive']);assert str(archive) in records[0]['filenames'] and archive.is_file()
  (run/'cargo-static-artifact.json').write_text(json.dumps(records[0],indent=2)+'\n')
  scratch=run/'ffi-hosted';scratch.mkdir()
  entry=scratch/'entrypoint.c';shutil.copyfile(contract['entrypoint_source'],entry)
  assert digest(entry)==contract['entrypoint_sha256']
  archives={str(archive):digest(archive)}
  flags=shlex.split(contract['link_environment']['PKG_LIBS'])
  assert flags[0]=='-L'+str(archive.parent)
  for flag in flags:
   if flag.startswith('-l') and flag!='-lc++':
    f=archive.parent/('lib'+flag[2:]+'.a');assert f.is_file(),str(f);archives[str(f)]=digest(f)
  linklog=stage('ffi-fresh-link',contract['link_command'],cwd=scratch,extra_env=contract['link_environment'])
  dll=scratch/'relm.so';assert dll.is_file()
  binary={'static_archives':archives,'entrypoint_sha256':digest(entry),'dll_path':str(dll),'dll_sha256':digest(dll),'dll_bytes':dll.stat().st_size,'old_library_reused':False}
  (run/'fresh-ffi-binding.json').write_text(json.dumps(binary,indent=2)+'\n')
  state['link_warnings']=[line for line in linklog.splitlines() if 'warning:' in line];save()
  log=stage('ffi-r-hosted',['Rscript','--vanilla',str(ROOT/'check-ledger-hosted.R'),str(dll)],180)
  assert digest(dll)==binary['dll_sha256']
  for f,h in archives.items():assert digest(Path(f))==h,f
  receipts.append(collector.hosted_test(log,hosted[0]));(run/'native-test-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
  profile,twins=collector.twins(log,ready)
  (run/'native-profile.json').write_text(json.dumps(profile,indent=2)+'\n');(run/'native-twins.json').write_text(json.dumps(twins,indent=2)+'\n')
  with (run/'native-twins.csv').open('w') as f:
   w=csv.writer(f);w.writerow(['case','section','field','value'])
   for row in twins:
    for section in ['profile','inputs','terms']:
     for field,value in row[section].items():w.writerow([row['case'],section,field,value])
  tags=collector.markers(log,'F6E_PROJECTION_R_TAG');assert len(tags)==1
  (run/'native-r-tag.json').write_text(json.dumps(tags[0],indent=2)+'\n')
  collector.verify_tag(tags[0],profile)
  log=stage('r-compiled-twins',['Rscript',str(ROOT/'check-ledger-twins.R')],180)
  assert log.count('F6E_LEDGER_R_TWIN cases=12 compared_terms=156 exact_budgets=12 rejected_budget_minus_one=12 differences=0 models=0')==1
  state['native_outcomes']=len(receipts);state['native_cases']=sum(r['executed_cases'] for r in receipts);state['native_rejections']=sum(r['rejected_cases'] for r in receipts)
  state['twin_terms']=156;state['source_drift']=[p for p,h in manifest.items() if not (REPO/p).is_file() or digest(REPO/p)!=h]
  assert not state['source_drift']
  state['compiler_warnings']=[s['name'] for s in state['stages'] if s['name'] not in ('r-source','r-compiled-twins') and re.search(r'^warning(?:\[|:)',(run/(s['name']+'.log')).read_text(),re.M)]
  assert not state['compiler_warnings'],state['compiler_warnings']
  state['status']='awaiting_owner_verification'
 except Exception as error:state.update(status='failed',error=str(error),traceback=traceback.format_exc())
 finally:
  state['source_drift']=[p for p,h in manifest.items() if not (REPO/p).is_file() or digest(REPO/p)!=h]
  if state['source_drift']:state['status']='failed'
  state['finished_at']=time.time();save()
if __name__=='__main__':main()
