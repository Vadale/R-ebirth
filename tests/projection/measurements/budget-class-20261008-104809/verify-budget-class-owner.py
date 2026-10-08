import csv,hashlib,json,re,shutil,subprocess,tarfile
from pathlib import Path
root=Path('/private/tmp/relm-f6e');repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');run=root/'budget-class-20261008-104809';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
s=json.loads((run/'status.json').read_text());m=json.loads((run/'source-manifest.json').read_text());b=json.loads((run/'owner-binding.json').read_text());ready=json.loads((run/'budget-class-ready.json').read_text())
assert s['status']=='awaiting_owner_verification' and s['source_drift']==[] and len(m)==117
assert sha(run/'source-manifest.json')==s['source_manifest_sha256']=='8e8cbead752c46f5b2f3ccc97de9ca96619ee40787501a329ebea343ad01f941'
for p,h in m.items():assert sha(repo/p)==h,p
for p,h in {**b['files'],**b['r_headers']}.items():assert sha(Path(p))==h,p
assert len(b['r_headers'])==42
with tarfile.open(run/'changed-source.tar.gz') as t:
 members=t.getmembers()
 for member in members:assert member.isfile() and hashlib.sha256(t.extractfile(member).read()).hexdigest()==m[member.name]
expected=['r-source','format','clippy-default','clippy-private','no-spill-default','no-spill-private','native-1','default-static-build','default-fresh-link','default-registration']
assert [x['name'] for x in s['stages']]==expected
for stage in s['stages']:
 assert stage['status']=='passed' and stage['exit_code']==0
 p=run/(stage['name']+'.log');assert sha(p)==stage['log_sha256']
 log=p.read_text()
 if stage['name']=='r-source':
  assert re.findall(r'^Warning.*$',log,re.M)==['Warning message:']
  assert log.count('package ‘testthat’ was built under R version 4.5.2')==1
 else:assert not re.search(r'^(?:warning(?:\[|:)|ld: warning:|Warning|Error|error(?:\[|:))',log,re.M)
log=(run/'native-1.log').read_text();test=ready['native_test']
assert re.findall(r'^test ([^ ]+) \.\.\. ',log,re.M)==[test['id']]
assert re.findall(r'^test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured;',log,re.M)==[('1','0','0','0')]
raw=re.findall(r'F6E_PROJECTION_LEDGER_TEST (\{[^\n]*\})',log);assert len(raw)==1
native=json.loads(raw[0]);assert native=={'test':test['id'].split('::')[-1],'status':'passed','expected_cases':11,'executed_cases':11,'expected_rejections':7,'rejected_cases':7}
assert [native]==json.loads((run/'native-receipts.json').read_text())
log=(run/'default-registration.log').read_text();raw=re.findall(r'^F6E_PROJECTION_BUDGET_CLASS_TEST (\{[^\n]*\})$',log,re.M);assert len(raw)==1
hosted=json.loads(raw[0]);assert hosted=={'test':'projection_budget_error_rhost','status':'passed','expected_cases':8,'executed_cases':8,'expected_rejections':3,'rejected_cases':3,'error_response_bytes':504,'ffi_response_bytes':1512,'error_format_bytes':150,'model_loads':0,'inference_calls':0}
assert hosted==json.loads((run/'default-registration-receipt.json').read_text())
assert log.splitlines()[-1]=='F6E_BUDGET_R_HOSTED_SUCCESS cases=8 refusals=3 models=0 inference=0'
assert log.splitlines()[-2]=='F6E_BUDGET_R_TWIN terms=14 exact_budget=1 minus_one_oom=1 payloads=3 models=0 inference=0'
rows=lambda name:list(csv.DictReader((run/name).open()))
f=rows('r-source-results.csv');assert len(f)==1 and int(f[0]['passed'])==12 and int(f[0]['failed'])==int(f[0]['warning'])==0 and f[0]['error']==f[0]['skipped']=='FALSE'
profile={r['field']:int(r['value']) for r in rows('budget-profile.csv')};assert len(profile)==27
assert profile['ffi_registry_bytes']==32 and profile['ffi_fixed_bytes']==1512+32+160==1704
old=json.loads((root/'production-activation-20261008-041846/default-registration-receipt.json').read_text())['profile'];assert profile==old
terms=rows('budget-terms.csv');assert len(terms)==14 and len({r['field'] for r in terms})==14 and all(int(r['native'])==int(r['R']) for r in terms)
errors=rows('budget-errors.csv');assert errors==[{'payload':'oom','actual':'1384','charged':'1480'},{'payload':'malformed','actual':'1432','charged':'1480'},{'payload':'overflow','actual':'1432','charged':'1480'}]
inputs={r['field']:int(r['value']) for r in rows('budget-inputs.csv')};total=next(int(r['native']) for r in terms if r['field']=='total_bytes');assert len(inputs)==15 and inputs['max_bytes']==total-1 and inputs['production_armed']==1
binary=json.loads((run/'binary-bindings.json').read_text());assert binary['mode']=='default' and binary['artifact']['features']==['default','spill'];assert 'staticlib' in binary['artifact']['target']['crate_types'] and len(binary['static_archives'])==9
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
report={'status':'PASS','source_manifest_sha256':s['source_manifest_sha256'],'source_count':len(m),'source_archive_members':len(members),'stage_logs':10,'R_headers':42,'outcomes':2,'cases':19,'refusals':10,'R_source_cases':1,'R_source_expectations':12,'native_R_terms':14,'model_loads_reported':0,'inference_calls_reported':0,'private_feature':False,'compiled_profile':profile,'profile_delta_vs_accepted_production':{},'compiled_error_response_bytes':504,'measured_error_payloads':errors,'compiler_linker_warnings':0,'retained_external_warning':'testthat built under R4.5.2; executing R4.5.1','C_bytes_bound_to_own_and_bundled_archive':True,'linked_archives':9,'DLL_sha256':binary['dll_sha256'],'scope':'Focused OOM class/fields/exact budget, malformed/overflow distinction, native/R envelope and fresh default DLL. No model or installed continuation acceptance.','driver_status_preserved':s['status']}
(run/'owner-verification.json').write_text(json.dumps(report,indent=2)+'\n')
arc=repo/'tests/projection/measurements'/run.name;assert not arc.exists();arc.mkdir()
for p in run.rglob('*'):
 if p.is_file() and 'binding-binaries' not in p.parts and p.suffix in ['.json','.csv','.log','.py','.R','.c','.patch','.gz','.rds']:
  dst=arc/p.relative_to(run);dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dst)
shutil.copy2(__file__,arc/Path(__file__).name)
files={str(p.relative_to(arc)):{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(arc.rglob('*')) if p.is_file()};(arc/'file-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print(json.dumps(report,indent=2))
