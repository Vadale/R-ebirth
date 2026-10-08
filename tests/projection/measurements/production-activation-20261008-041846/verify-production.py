import fcntl,hashlib,importlib.util,json,os,re,shlex,shutil,signal,subprocess,tarfile,time,traceback
from pathlib import Path
ROOT=Path('/private/tmp/relm-f6e');REPO=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');WORK=REPO/'rebirth/src/rust'
spec=importlib.util.spec_from_file_location('collector',ROOT/'production-collector.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 lock=(ROOT/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 ready=json.loads((ROOT/'production-ready.json').read_text());bind=json.loads((ROOT/'production-binding.json').read_text())
 assert ready['status']=='ready' and ready['frozen'] and ready['production_native_armed']
 for p,h in {**ready['source_hashes'],**ready['preserved_source_hashes'],**ready['untouched_build_C_classifier_hashes'],**bind['repo_sources']}.items():assert sha(REPO/p)==h,p
 for p,h in {**bind['files'],**bind['r_headers']}.items():assert sha(Path(p))==h,p
 run=ROOT/('production-activation-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
 st={'status':'running','pid':os.getpid(),'directory':str(run),'stages':[],'model_loads_planned':2,'scope':'default native activation/new worker and fresh default DLL; not installed public R/text/evaluation acceptance'}
 def save():
  raw=json.dumps(st,indent=2)+'\n';(run/'status.json').write_text(raw);tmp=ROOT/'production-status.tmp';tmp.write_text(raw);tmp.replace(ROOT/'production-status.json')
 save();env=os.environ.copy();env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip();env['RUST_TEST_THREADS']='1'
 for k in list(env):
  if k.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_','F6E_MODEL')) or k=='RELM_NATIVE_SANITIZERS':env.pop(k)
 def stage(name,cmd,cwd=WORK,extra=None,timeout=1800):
  row={'name':name,'command':cmd,'status':'running'};st['stage']=name;st['stages'].append(row);save()
  with (run/(name+'.log')).open('w') as out:
   p=subprocess.Popen(cmd,cwd=cwd,env={**env,**(extra or {})},stdout=out,stderr=subprocess.STDOUT,start_new_session=True);row['pid']=p.pid;save()
   try:code=p.wait(timeout=timeout)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=10);raise
  row.update(exit_code=code,status='passed' if code==0 else 'failed',log_sha256=sha(run/(name+'.log')));save()
  assert code==0,name+' failed; preserve and diagnose before affected-only correction'
  return (run/(name+'.log')).read_text()
 manifest={}
 try:
  paths=subprocess.check_output(['git','ls-files','-co','--exclude-standard','rebirth/src/rust','rebirth/R','rebirth/src/entrypoint.c','rebirth/src/Makevars','rebirth/tests/testthat/test-projection-application.R'],cwd=REPO,text=True).splitlines()
  paths=set(paths)|set(ready['source_hashes'])|set(ready['preserved_source_hashes'])|set(ready['untouched_build_C_classifier_hashes'])|set(bind['repo_sources'])
  manifest={p:sha(REPO/p) for p in sorted(paths) if (REPO/p).is_file()};raw=json.dumps(manifest,sort_keys=True,indent=2)+'\n';(run/'source-manifest.json').write_text(raw)
  st.update(source_manifest_sha256=hashlib.sha256(raw.encode()).hexdigest(),source_count=len(manifest));save()
  for p in bind['files']:shutil.copy2(p,run/Path(p).name)
  shutil.copy2(ROOT/'production-binding.json',run/'owner-binding.json')
  changed=set(subprocess.check_output(['git','diff','--name-only','HEAD'],cwd=REPO,text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard'],cwd=REPO,text=True).splitlines())
  with tarfile.open(run/'changed-source.tar.gz','w:gz') as tar:
   for p in sorted(changed.intersection(manifest)):tar.add(REPO/p,arcname=p)
  (run/'candidate.patch').write_bytes(subprocess.check_output(['git','diff','--binary','HEAD'],cwd=REPO))
  cmds=[('format',['cargo','fmt','--all','--','--check']),('clippy-default',['cargo','clippy','--locked','--offline','-p','rebirth-llm','-p','rebirth-ffi','--all-targets','--','-D','warnings']),('clippy-private',['cargo','clippy','--locked','--offline','-p','rebirth-llm','-p','rebirth-ffi','--all-targets','--features','projection-private','--','-D','warnings']),('no-spill-default',['cargo','check','--locked','--offline','-p','rebirth-ffi','--no-default-features','--lib']),('no-spill-private',['cargo','check','--locked','--offline','-p','rebirth-ffi','--no-default-features','--features','projection-private','--lib'])]
  for name,cmd in cmds:stage(name,cmd)
  receipts=[]
  for idx,test in enumerate(ready['tests'],1):
   assert '--features' not in test['command'] and '--all-features' not in test['command'] and test['private_feature'] is False
   receipts.append(c.native(stage('native-'+str(idx),test['command']),test));(run/'native-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
  base=ready['fresh_default_dll_contract'];log=stage('default-static-build',ready['default_build_command']+['--message-format=json']);artifacts=[];builds=[]
  for line in log.splitlines():
   if line.startswith('{'):
    r=json.loads(line)
    if r.get('reason')=='compiler-artifact' and r['target']['name']=='relm' and 'staticlib' in r['target']['crate_types']:artifacts.append(r)
    if r.get('reason')=='build-script-executed' and 'rebirth-ffi' in r.get('package_id',''):builds.append(r)
    if r.get('reason')=='compiler-message':assert r['message']['level']!='warning'
  assert len(artifacts)==len(builds)==1
  artifact=artifacts[0];assert 'projection-private' not in artifact['features'];lib=Path(base['static_archive']);assert str(lib) in artifact['filenames']
  scratch=run/'default-ffi';scratch.mkdir();shutil.copy2(base['entrypoint_source'],scratch/'entrypoint.c');assert sha(scratch/'entrypoint.c')==base['entrypoint_sha256']
  flags=shlex.split(base['link_environment']['PKG_LIBS']);assert flags[0]=='-L'+str(lib.parent);archives={}
  for flag in flags:
   if flag.startswith('-l') and flag!='-lc++':p=lib.parent/('lib'+flag[2:]+'.a');archives[str(p)]=sha(p)
  assert len(archives)==9
  c_out=Path(builds[0]['out_dir']);cfiles={str(c_out/f):sha(c_out/f) for f in ['projection_state.o','librelm-r-state.a']}
  for archive in [lib,c_out/'librelm-r-state.a']:
   assert subprocess.check_output(['ar','t',str(archive)],text=True).splitlines().count('projection_state.o')==1
   assert hashlib.sha256(subprocess.check_output(['ar','p',str(archive),'projection_state.o'])).hexdigest()==sha(c_out/'projection_state.o')
  stage('default-fresh-link',base['link_command'],cwd=scratch,extra=base['link_environment'])
  dll=scratch/'relm.so';assert dll.is_file();local=scratch/'binding-binaries';local.mkdir();copies={}
  for p in [lib,c_out/'projection_state.o',c_out/'librelm-r-state.a']:
   dest=local/p.name;shutil.copy2(p,dest);copies[str(p)]={'path':str(dest),'sha256':sha(dest)}
  binaries={'mode':'default','artifact':artifact,'cargo_build':builds[0],'static_archives':archives,'C_files':cfiles,'local_copies':copies,'entrypoint_sha256':sha(scratch/'entrypoint.c'),'dll_path':str(dll),'dll_sha256':sha(dll),'dll_bytes':dll.stat().st_size}
  (run/'binary-bindings.json').write_text(json.dumps(binaries,indent=2)+'\n')
  result=c.registration(stage('default-registration',['Rscript','--vanilla',str(ROOT/'check-production-default.R'),str(dll)],timeout=120),ready)
  (run/'default-registration-receipt.json').write_text(json.dumps(result,indent=2)+'\n')
  assert all(sha(Path(p))==h for p,h in archives.items())
  assert all(sha(Path(p))==h for p,h in bind['r_headers'].items())
  st['compiler_warnings']=[s['name'] for s in st['stages'] if re.search(r'^(?:warning(?:\[|:)|ld: warning:)',(run/(s['name']+'.log')).read_text(),re.M)]
  assert not st['compiler_warnings']
  st.update(status='awaiting_owner_verification',outcomes=3,cases=27,refusals=13,compared_values=291,model_loads_reported=2,constructor_calls_reported=3,independent_numerical_oracle=False)
 except Exception as e:st.update(status='failed',error=str(e),traceback=traceback.format_exc())
 finally:
  st['source_drift']=[p for p,h in manifest.items() if not (REPO/p).is_file() or sha(REPO/p)!=h]
  if st['source_drift']:st['status']='failed'
  st['finished_at']=time.time();save()
if __name__=='__main__':main()
