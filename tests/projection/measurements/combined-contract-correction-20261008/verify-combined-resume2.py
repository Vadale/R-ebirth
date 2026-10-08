import csv,fcntl,hashlib,importlib.util,json,os,re,shlex,shutil,signal,subprocess,tarfile,time,traceback
from pathlib import Path
ROOT=Path('/private/tmp/relm-f6e');REPO=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');WORK=REPO/'rebirth/src/rust'
spec=importlib.util.spec_from_file_location('c',ROOT/'combined-collector.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 lock=(ROOT/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 ready=json.loads((ROOT/'combined-boundary-ready.json').read_text());bind=json.loads((ROOT/'combined-resume2-binding.json').read_text())
 assert ready['status']=='ready' and ready['production_armed'] is False
 for path,h in {**ready['source_hashes'],**ready['preserved_native_source_hashes'],**ready['preserved_parent_constructor_helper'],**bind['repo_sources']}.items():assert sha(REPO/path)==h,path
 for path,h in {**bind['files'],**bind['r_headers']}.items():assert sha(Path(path))==h,path
 run=ROOT/('combined-binding-resume-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
 st={'status':'running','pid':os.getpid(),'directory':str(run),'stages':[],'model_loads_planned':1,'public_operator_enabled':False,'scope':'private bridge and actual R constructor combined budget; not installed package/evaluation/production activation'}
 def save():
  raw=json.dumps(st,indent=2)+'\n';(run/'status.json').write_text(raw);tmp=ROOT/'combined-status.tmp';tmp.write_text(raw);tmp.replace(ROOT/'combined-status.json')
 save();env=os.environ.copy();env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip();env['RUST_TEST_THREADS']='1';env['F6E_COMBINED_RUN']=str(run)
 for key in list(env):
  if key.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_','F6E_MODEL')) or key=='RELM_NATIVE_SANITIZERS':env.pop(key)
 def stage(name,cmd,cwd=WORK,extra=None,timeout=1800):
  row={'name':name,'command':cmd,'status':'running'};st['stages'].append(row);st['stage']=name;save()
  with (run/(name+'.log')).open('w') as out:
   p=subprocess.Popen(cmd,cwd=cwd,env={**env,**(extra or {})},stdout=out,stderr=subprocess.STDOUT,start_new_session=True);row['pid']=p.pid;save()
   try:code=p.wait(timeout=timeout)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=10);raise
  row.update(status='passed' if code==0 else 'failed',exit_code=code,log_sha256=sha(run/(name+'.log')));save()
  assert code==0,name+' failed: preserve/diagnose before affected-only correction'
  return (run/(name+'.log')).read_text()
 manifest={}
 try:
  paths=subprocess.check_output(['git','ls-files','-co','--exclude-standard','rebirth/src/rust','rebirth/R','rebirth/src/entrypoint.c','rebirth/src/Makevars','rebirth/tests/testthat/test-projection-public-binding.R'],cwd=REPO,text=True).splitlines()
  paths=set(paths)|set(ready['source_hashes'])|set(bind['repo_sources']);manifest={p:sha(REPO/p) for p in sorted(paths) if (REPO/p).is_file()}
  raw=json.dumps(manifest,sort_keys=True,indent=2)+'\n';(run/'source-manifest.json').write_text(raw);st['source_manifest_sha256']=hashlib.sha256(raw.encode()).hexdigest();st['source_count']=len(manifest)
  (run/'ready.json').write_text(json.dumps(ready,indent=2)+'\n');(run/'owner-binding.json').write_text(json.dumps(bind,indent=2)+'\n')
  for path in bind['files']:shutil.copyfile(path,run/Path(path).name)
  changed=set(subprocess.check_output(['git','diff','--name-only','HEAD'],cwd=REPO,text=True).splitlines())|set(subprocess.check_output(['git','ls-files','--others','--exclude-standard'],cwd=REPO,text=True).splitlines())
  with tarfile.open(run/'changed-source.tar.gz','w:gz') as tar:
   for path in sorted(changed.intersection(manifest)):tar.add(REPO/path,arcname=path)
  (run/'candidate.patch').write_bytes(subprocess.check_output(['git','diff','--binary','HEAD'],cwd=REPO))
  st['carried_accepted_scopes']=['private constructor49/35/240 at9cf850e8','R binding6/37 source only','R constructor3/61','all prior private/ledger/transfer/ref/model timing gates'];save()
  previous=ROOT/'combined-binding-20261008-031008'
  prior=json.loads((previous/'status.json').read_text())
  assert prior['status']=='failed' and prior['source_drift']==[]
  assert prior['source_manifest_sha256']=='29835e928e07da28036ae9f14fb55401dc66382913f80b3747a0c40bcbe04935'
  assert manifest==json.loads((previous/'source-manifest.json').read_text())
  assert st['source_manifest_sha256']==prior['source_manifest_sha256']
  assert [s['name'] for s in prior['stages']]==['format','clippy-private','clippy-default','no-spill-default','no-spill-private','native-bridge-frame']
  carried=run/'carried';carried.mkdir()
  for s in prior['stages']:
   assert s['status']=='passed' and s['exit_code']==0
   log=previous/(s['name']+'.log');assert sha(log)==s['log_sha256']
   assert not re.search(r'^warning(?:\[|:)',log.read_text(),re.M)
   shutil.copyfile(log,carried/log.name)
  for name in ['status.json','partial-verification.json','source-manifest.json']:shutil.copyfile(previous/name,carried/name)
  native=c.bridge_native((previous/'native-bridge-frame.log').read_text())
  assert native==json.loads((previous/'native-bridge-receipt-recovered.json').read_text())
  (run/'native-bridge-receipt.json').write_text(json.dumps(native,indent=2)+'\n')
  st['carried_stages']=prior['stages'];st['carried_directory']=str(previous)
  st['carried_outcomes']=1;st['carried_cases']=2;st['carried_refusals']=0
  st['collector_recovery']='Exact named libtest prefix normalized; original failed run preserved; no native rerun.';save()
  base=ready['fresh_dll_contract'];binaries={};modes=[]
  for mode in ['default','private']:
   log=stage(mode+'-static-build',ready[mode+'_build_command']+['--message-format=json'])
   artifacts=[];builds=[]
   for line in log.splitlines():
    if line.startswith('{'):
     r=json.loads(line)
     if r.get('reason')=='compiler-artifact' and r['target']['name']=='relm' and 'staticlib' in r['target']['crate_types']:artifacts.append(r)
     if r.get('reason')=='build-script-executed' and 'rebirth-ffi' in r.get('package_id',''):builds.append(r)
     if r.get('reason')=='compiler-message':assert r['message']['level']!='warning'
   assert len(artifacts)==len(builds)==1
   artifact=artifacts[0];assert ('projection-private' in artifact['features'])==(mode=='private')
   lib=Path(base['static_archive']);assert str(lib) in artifact['filenames']
   scratch=run/(mode+'-ffi');scratch.mkdir();shutil.copyfile(base['entrypoint_source'],scratch/'entrypoint.c')
   assert sha(scratch/'entrypoint.c')==base['entrypoint_sha256']
   flags=shlex.split(base['link_environment']['PKG_LIBS']);assert flags[0]=='-L'+str(lib.parent)
   archives={}
   for flag in flags:
    if flag.startswith('-l') and flag!='-lc++':
     path=lib.parent/('lib'+flag[2:]+'.a');archives[str(path)]=sha(path)
   assert len(archives)==9
   c_out=Path(builds[0]['out_dir']);cfiles={str(c_out/f):sha(c_out/f) for f in ['projection_state.o','librelm-r-state.a']}
   for archive in [lib,c_out/'librelm-r-state.a']:
    assert subprocess.check_output(['ar','t',str(archive)],text=True).splitlines().count('projection_state.o')==1
    assert hashlib.sha256(subprocess.check_output(['ar','p',str(archive),'projection_state.o'])).hexdigest()==sha(c_out/'projection_state.o')
   linklog=stage(mode+'-fresh-link',base['link_command'],cwd=scratch,extra=base['link_environment'])
   assert not re.search(r'^warning(?:\[|:)',linklog,re.M)
   dll=scratch/'relm.so';assert dll.is_file()
   # Preserve overwritten librelm/C bytes locally for independent verification
   # of both feature builds; never copy these binary files into the repository.
   local=scratch/'binding-binaries';local.mkdir()
   copies={}
   for path in [lib,c_out/'projection_state.o',c_out/'librelm-r-state.a']:
    dest=local/path.name;shutil.copyfile(path,dest);copies[str(path)]=dict(path=str(dest),sha256=sha(dest))
   receipt=dict(mode=mode,artifact=artifact,cargo_build=builds[0],static_archives=archives,C_files=cfiles,local_copies=copies,entrypoint_sha256=sha(scratch/'entrypoint.c'),dll_path=str(dll),dll_sha256=sha(dll),dll_bytes=dll.stat().st_size)
   binaries[mode]=receipt;(run/'binary-bindings.json').write_text(json.dumps(binaries,indent=2)+'\n')
   modes.append(c.mode_receipt(stage(mode+'-registration',['Rscript','--vanilla',str(ROOT/'check-bridge-mode.R'),str(dll),mode,str(run)],timeout=120),mode))
   for path,h in archives.items():assert sha(Path(path))==h
   with (run/(mode+'-profile.csv')).open() as f:profile={r['field']:int(r['value']) for r in csv.DictReader(f)}
   assert len(profile)==27 and profile['version']==2 and profile['ffi_command_bytes']==native['ffi_command_bytes'] and profile['derive_frame_bytes']==11639+native['bridge_frame_bytes']
  (run/'registration-receipts.json').write_text(json.dumps(modes,indent=2)+'\n')
  log=stage('combined-R-binding',['Rscript','--vanilla',str(ROOT/'check-combined-binding.R'),binaries['private']['dll_path'],str(REPO/bind['model_path'])],cwd=REPO,timeout=300)
  with (run/'combined-cases.csv').open() as f:result=c.combined_rows(list(csv.DictReader(f)),log)
  with (run/'combined-materialization.csv').open() as f:mat=list(csv.DictReader(f))
  assert len(mat)==1;result['materialization']=c.materialized(mat[0]);(run/'combined-owner-receipts.json').write_text(json.dumps(result,indent=2)+'\n')
  for name in ['exact','steer','mixed']:
   with (run/('combined-'+name+'-terms.csv')).open() as f:rows=list(csv.DictReader(f))
   sections={sec:{r['field']:int(r['value']) for r in rows if r['section']==sec} for sec in ['profile','inputs','terms']}
   p,i,e=(sections[sec] for sec in ['profile','inputs','terms']);assert [len(x) for x in [p,i,e]]==[27,15,14]
   assert i['hidden_size']==32 and i['layers']==3 and p['ffi_command_bytes']==native['ffi_command_bytes']
   assert e['residual_probe_bytes']==(8*32*3+4*32+p['residual_probe_fixed_bytes'] if name!='exact' else 0)
   assert e['total_bytes']==sum(e[k] for k in ['projection_bytes','residual_probe_bytes','adapter_data_bytes','adapter_fixed_bytes','metadata_bytes','r_projection_bytes','r_adapter_bytes','existing_direction_estimate'])
  st['source_drift']=[p for p,h in manifest.items() if sha(REPO/p)!=h];assert not st['source_drift']
  assert all(sha(Path(p))==h for p,h in bind['r_headers'].items())
  st['compiler_warnings']=[s['name'] for s in st['stages'] if re.search(r'^warning(?:\[|:)',(run/(s['name']+'.log')).read_text(),re.M)];assert not st['compiler_warnings']
  st.update(status='awaiting_owner_verification',outcomes=4,cases=33,refusals=6,model_loads=1,constructor_calls=5,compiled_profile_terms=3*14)
 except Exception as e:st.update(status='failed',error=str(e),traceback=traceback.format_exc())
 finally:
  st['source_drift']=[p for p,h in manifest.items() if not (REPO/p).is_file() or sha(REPO/p)!=h]
  if st['source_drift']:st['status']='failed'
  st['finished_at']=time.time();save()
if __name__=='__main__':main()
