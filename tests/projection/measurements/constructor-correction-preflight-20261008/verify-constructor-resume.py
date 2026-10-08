"""One private constructor run; production projection remains unavailable."""
import csv,fcntl,hashlib,importlib.util,json,os,re,signal,subprocess,tarfile,time,traceback,shlex,shutil
from pathlib import Path
ROOT=Path('/private/tmp/relm-f6e');REPO=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');WORK=REPO/'rebirth/src/rust'
spec=importlib.util.spec_from_file_location('collector',ROOT/'constructor-collector.py');collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 lock=(ROOT/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 ready=json.loads((ROOT/'constructor-revision-ready.json').read_text());assert ready['status']=='ready'
 for path,sha in {**ready['source_hashes'],**ready['reference_hashes'],**ready['preserved_parent_abi_hash']}.items():assert digest(REPO/path)==sha,path
 revision=ready
 binding=json.loads((ROOT/'constructor-resume-binding.json').read_text())
 assert binding['collector_verified'] is True and binding['model_loads']==3
 for path,sha in {**binding['files'],**binding['r_headers']}.items():assert digest(Path(path))==sha,path
 run=ROOT/('private-constructor-resume-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
 state={'status':'running','pid':os.getpid(),'directory':str(run),'started_at':time.time(),'stages':[],
  'planned_model_loads':3,'production_armed':False,'scope':'private loaded-model constructor/native FFI; full R public inventory binding and activation still pending'}
 def save():
  raw=json.dumps(state,indent=2)+'\n';(run/'status.json').write_text(raw)
  tmp=ROOT/'constructor-status.tmp';tmp.write_text(raw);tmp.replace(ROOT/'constructor-status.json')
 env=os.environ.copy();env['RUST_TEST_THREADS']='1';env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip()
 for key in list(env):
  if key.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_','F6E_MODEL')) or key=='RELM_NATIVE_SANITIZERS':env.pop(key)
 env['F6E_CONSTRUCTOR_RUN']=str(run)
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
  paths=subprocess.check_output(['git','ls-files','-co','--exclude-standard','rebirth/src/rust','rebirth/src/entrypoint.c','rebirth/src/Makevars','rebirth/R','rebirth/tests/testthat/test-projection-memory.R','rebirth/tests/testthat/test-projection-constructor-memory.R','rebirth/tests/testthat/test-projection-owners.R','rebirth/tests/testthat/test-directions-boundaries.R','rebirth/tests/testthat/helper-directions.R'],cwd=REPO,text=True).splitlines()
  paths=sorted({p for p in paths if (REPO/p).is_file()}|set(ready['source_hashes'])|set(ready['reference_hashes']))
  manifest={p:digest(REPO/p) for p in paths};raw=json.dumps(manifest,sort_keys=True,indent=2)+'\n';(run/'source-manifest.json').write_text(raw)
  state['source_manifest_sha256']=hashlib.sha256(raw.encode()).hexdigest();state['source_count']=len(manifest);env['F6E_SOURCE']=state['source_manifest_sha256']
  (run/'revision-ready.json').write_text(json.dumps(revision,indent=2)+'\n');(run/'ready.json').write_text(json.dumps(ready,indent=2)+'\n');(run/'owner-binding.json').write_text(json.dumps(binding,indent=2)+'\n')
  for p in binding['files']:(run/Path(p).name).write_bytes(Path(p).read_bytes())
  changed=set(subprocess.check_output(['git','diff','--name-only','HEAD'],cwd=REPO,text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard'],cwd=REPO,text=True).splitlines())
  with tarfile.open(run/'changed-source.tar.gz','w:gz') as tar:
   for p in sorted(changed.intersection(manifest)):tar.add(REPO/p,arcname=p)
  (run/'candidate.patch').write_bytes(subprocess.check_output(['git','diff','--binary','HEAD'],cwd=REPO))
  save()
  state['accepted_prior_scopes_not_reexecuted']=['native ledger95/40','unarmed transfer78/55','R ledger7/229','R owners7/70','private1-9/CPU/Metal/diagnostic/reference'];save()
  prior=ROOT/'private-constructor-20261008-024059'
  previous=json.loads((prior/'status.json').read_text())
  previous_manifest=json.loads((prior/'source-manifest.json').read_text())
  changed='rebirth/src/rust/rebirth-ffi/src/projection_constructor_boundary.rs'
  assert previous['status']=='failed' and previous['stage']=='clippy-ffi-private'
  assert digest(prior/'source-manifest.json')==previous['source_manifest_sha256']
  assert [p for p,h in previous_manifest.items() if digest(REPO/p)!=h]==[changed]
  carried=[]
  for name in ['r-source','clippy-llm']:
   record=next(s for s in previous['stages'] if s['name']==name)
   assert record['status']=='passed' and record['exit_code']==0
   assert digest(prior/(name+'.log'))==record['log_sha256']
   shutil.copyfile(prior/(name+'.log'),run/('carried-'+name+'.log'))
   carried.append({'stage':name,'execution_source':str(prior),'record':record})
  with (prior/'r-source-results.csv').open() as f:rows=list(csv.DictReader(f))
  assert [int(r['passed']) for r in rows]==[9,48,4]
  assert all(r['failed']=='0' and r['warning']=='0' and r['error']=='FALSE' and r['skipped']=='FALSE' for r in rows)
  shutil.copyfile(prior/'r-source-results.csv',run/'carried-r-source-results.csv')
  (run/'carried-scopes.json').write_text(json.dumps(carried,indent=2)+'\n')
  state['carried_source_manifest_sha256']=previous['source_manifest_sha256'];save()
  for n,cmd in enumerate(ready['compile_commands']):
   if n==1:continue  # unchanged engine clippy is bound above, not reexecuted
   stage(['format','clippy-llm','clippy-ffi-private','no-spill-default','no-spill-private'][n],cmd)
  stage('clippy-ffi-default',['cargo','clippy','--locked','--offline','-p','rebirth-ffi','--all-targets','--','-D','warnings'])
  receipts=[]
  native=ready['tests'][:3]; assert len(native)==3 and all(t['execution']=='cargo_libtest' for t in native)
  for n,test in enumerate(native,1):
   assert test['crate']=='rebirth-llm'
   log=stage(f'native-{n:02d}',test['command'])
   receipts.append(collector.native(log,test,state['source_manifest_sha256']));(run/'native-test-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
  contract=ready['r_hosted_contract']
  assert contract['models']==1 and digest(Path(contract['entrypoint_source']))==contract['entrypoint_sha256']
  build=contract['build_command']+['--message-format=json']
  log=stage('ffi-static-build',build)
  records=[];c_build=[]
  for line in log.splitlines():
   if line.startswith('{'):
    row=json.loads(line)
    if row.get('reason')=='compiler-artifact' and row['target']['name']=='relm' and 'staticlib' in row['target']['crate_types']:records.append(row)
    if row.get('reason')=='build-script-executed' and 'rebirth-ffi' in row.get('package_id',''):c_build.append(row)
    if row.get('reason')=='compiler-message':assert row['message']['level']!='warning',row['message']
  assert len(records)==1,records
  archive=Path(contract['static_archive']);assert str(archive) in records[0]['filenames'] and archive.is_file()
  assert len(c_build)==1,c_build
  c_out=Path(c_build[0]['out_dir']);c_hashes={str(c_out/f):digest(c_out/f) for f in ['projection_state.o','librelm-r-state.a']}
  (run/'r-accessor-build-binding.json').write_text(json.dumps({'cargo_record':c_build[0],'files':c_hashes},indent=2)+'\n')
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
  model=REPO/'tests/llm-golden/live-state/f6b/synthetic-llama-3l.gguf'
  log=stage('ffi-r-hosted',['Rscript','--vanilla',str(ROOT/'check-constructor-hosted.R'),str(dll),str(model)],300)
  assert digest(dll)==binary['dll_sha256']
  for f,h in archives.items():assert digest(Path(f))==h,f
  receipts.append(collector.hosted(log,ready['tests'][3]))
  (run/'native-test-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
  twins=collector.twins(log,ready);(run/'native-twin-receipts.json').write_text(json.dumps(twins,indent=2)+'\n')
  with (run/'native-twins.csv').open('w',newline='') as f:
   writer=csv.writer(f);writer.writerow(['case','section','field','value'])
   for twin in twins:
    for section in ['profile','inputs','terms']:
     for key,value in twin[section].items():writer.writerow([twin['case'],section,key,value])
  rlog=stage('r-compiled-twins',['Rscript','--vanilla',str(ROOT/'check-constructor-twins.R')],180,cwd=REPO)
  assert rlog.count('F6E_CONSTRUCTOR_R_TWIN cases=4 compared_terms=56 exact_budgets=4 rejected_budget_minus_one=4 differences=0 models=0')==1
  with (run/'r-native-parity.csv').open() as f:parity=list(csv.DictReader(f))
  assert len(parity)==56 and all(float(row['difference'])==0 for row in parity)
  state['native_outcomes']=len(receipts);state['native_cases']=sum(r['executed_cases'] for r in receipts);state['native_rejections']=sum(r['rejected_cases'] for r in receipts)
  state['compared_logits']=sum(r['compared_values'] for r in receipts);state['reported_model_loads']=sum(r['model_loads'] for r in receipts)
  assert (state['native_outcomes'],state['native_cases'],state['native_rejections'],state['compared_logits'],state['reported_model_loads'])==(4,49,35,240,3)
  state['R_twin_terms']=56;state['R_source_cases']=3;state['R_source_expectations']=61
  assert all(digest(Path(p))==h for p,h in binding['r_headers'].items())
  state['source_drift']=[p for p,h in manifest.items() if not (REPO/p).is_file() or digest(REPO/p)!=h]
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
