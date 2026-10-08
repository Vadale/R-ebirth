import hashlib,json,re,shutil,subprocess,tarfile
from pathlib import Path
root=Path('/private/tmp/relm-f6e');repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');run=root/'production-activation-20261008-041846';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
s=json.loads((run/'status.json').read_text());m=json.loads((run/'source-manifest.json').read_text());b=json.loads((run/'owner-binding.json').read_text());ready=json.loads((run/'production-ready.json').read_text())
assert s['status']=='awaiting_owner_verification' and s['source_drift']==[] and len(m)==115
assert sha(run/'source-manifest.json')==s['source_manifest_sha256']=='18ebedbbf3469f2ae7358e8044836f51e866372c3af2e84fc9107070aa0ab31e'
for p,h in m.items():assert sha(repo/p)==h,p
for p,h in {**b['files'],**b['r_headers']}.items():assert sha(Path(p))==h,p
assert len(b['r_headers'])==42
with tarfile.open(run/'changed-source.tar.gz') as t:
 members=t.getmembers()
 for member in members:assert member.isfile() and hashlib.sha256(t.extractfile(member).read()).hexdigest()==m[member.name]
expected_stages=['format','clippy-default','clippy-private','no-spill-default','no-spill-private','native-1','native-2','default-static-build','default-fresh-link','default-registration']
assert [x['name'] for x in s['stages']]==expected_stages
for stage in s['stages']:
 assert stage['status']=='passed' and stage['exit_code']==0
 p=run/(stage['name']+'.log');assert sha(p)==stage['log_sha256']
 assert not re.search(r'^(?:warning(?:\[|:)|ld: warning:|Warning|Error|error(?:\[|:))',p.read_text(),re.M)
records=[]
for i,test in enumerate(ready['tests'],1):
 log=(run/f'native-{i}.log').read_text()
 assert re.findall(r'^test ([^ ]+) \.\.\. ',log,re.M)==[test['id']]
 assert re.findall(r'^test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured;',log,re.M)==[('1','0','0','0')]
 raw=re.findall(r'F6E_PROJECTION_PRODUCTION_TEST (\{[^\n]*\})',log);assert len(raw)==1
 r=json.loads(raw[0]);expect={'test':test['marker_test'],'status':'passed','expected_cases':test['expected_cases'],'executed_cases':test['expected_cases'],'expected_rejections':test['expected_rejections'],'rejected_cases':test['expected_rejections'],'expected_values':test['expected_values'],'compared_values':test['expected_values'],'model_loads':test['model_loads'],'constructor_calls':test['constructor_calls'],'library_cfg_test':test['library_cfg_test'],'private_feature':False};assert r==expect
 assert '--features' not in s['stages'][5+i-1]['command'];records.append(r)
assert records==json.loads((run/'native-receipts.json').read_text())
log=(run/'default-registration.log').read_text();raw=re.findall(r'^F6E_PROJECTION_PRODUCTION_R (\{[^\n]*\})$',log,re.M);assert len(raw)==1
r=json.loads(raw[0]);assert r=={'status':'passed','expected_cases':4,'executed_cases':4,'expected_rejections':2,'rejected_cases':2,'model_loads':0,'results':['constructor_registered','constructor_parses_default','fixed_helper_stays_private','compiled_profile_preserved']}
raw=re.findall(r'^F6E_PROJECTION_PRODUCTION_PROFILE (\{[^\n]*\})$',log,re.M);assert len(raw)==1
profile=json.loads(raw[0])['profile'];assert len(profile)==27
for k,v in ready['profile']['expected_host_fixed_profile'].items():assert profile[k]==v
assert profile['ffi_registry_bytes']==32 and profile['ffi_fixed_bytes']==1512+32+160==1704
assert profile==json.loads((run/'default-registration-receipt.json').read_text())['profile']
binary=json.loads((run/'binary-bindings.json').read_text());assert binary['mode']=='default' and 'projection-private' not in binary['artifact']['features'];assert 'staticlib' in binary['artifact']['target']['crate_types'] and len(binary['static_archives'])==9
cargo=[]
for line in (run/'default-static-build.log').read_text().splitlines():
 if line.startswith('{'):
  row=json.loads(line)
  if row.get('reason')=='compiler-message':assert row['message']['level']!='warning'
  if row.get('reason')=='compiler-artifact' and row['target']['name']=='relm':cargo.append(row)
assert cargo==[binary['artifact']]
for p,h in {**binary['static_archives'],**binary['C_files']}.items():
 copy=binary['local_copies'].get(p);actual=Path(copy['path']) if copy else Path(p);assert sha(actual)==h
 if copy:assert copy['sha256']==h
copies={Path(k).name:Path(v['path']) for k,v in binary['local_copies'].items()}
for arc in ['librelm.a','librelm-r-state.a']:
 assert subprocess.check_output(['ar','t',str(copies[arc])],text=True).splitlines().count('projection_state.o')==1
 assert hashlib.sha256(subprocess.check_output(['ar','p',str(copies[arc]),'projection_state.o'])).hexdigest()==sha(copies['projection_state.o'])
assert sha(Path(binary['dll_path']))==binary['dll_sha256'] and Path(binary['dll_path']).stat().st_size==binary['dll_bytes']
assert sha(run/'default-ffi/entrypoint.c')==binary['entrypoint_sha256']==sha(repo/'rebirth/src/entrypoint.c')
report={'status':'PASS','source_manifest_sha256':s['source_manifest_sha256'],'source_count':len(m),'source_archive_members':len(members),'stage_logs':10,'R_headers':42,'outcomes':3,'cases':27,'refusals':13,'compared_values':291,'value_scope':'288 exact raw-logit lifecycle equality values plus3 exact post-edit live coordinates; not new independent-golden accuracy','model_loads_reported':2,'constructor_calls_reported':3,'default_library_integration_cfg_test':False,'worker_library_cfg_test':True,'private_feature':False,'compiled_profile':profile,'compiler_linker_warnings':0,'C_bytes_bound_to_own_and_bundled_archive':True,'linked_archives':9,'DLL_sha256':binary['dll_sha256'],'scope':'Default native activation, worker/live ownership and fresh default R registration/profile. Installed public R/text/structured/evaluation/render/instrumented gates remain pending.','driver_status_preserved':s['status']}
(run/'owner-verification.json').write_text(json.dumps(report,indent=2)+'\n')
arc=repo/'tests/projection/measurements'/run.name;assert not arc.exists();arc.mkdir()
for p in run.rglob('*'):
 if p.is_file() and 'binding-binaries' not in p.parts and p.suffix in ['.json','.csv','.log','.py','.R','.c','.patch','.gz']:
  dst=arc/p.relative_to(run);dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dst)
shutil.copy2(__file__,arc/Path(__file__).name)
files={str(p.relative_to(arc)):{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(arc.rglob('*')) if p.is_file()};(arc/'file-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print(json.dumps(report,indent=2))
