from pathlib import Path
import csv,hashlib,json,re,tarfile,subprocess,shutil
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');run=Path('/private/tmp/relm-f6e/private-constructor-resume-20261008-024551')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
st=json.loads((run/'status.json').read_text());manifest=json.loads((run/'source-manifest.json').read_text());binding=json.loads((run/'owner-binding.json').read_text());ready=json.loads((run/'ready.json').read_text())
assert st['status']=='awaiting_owner_verification' and st['production_armed'] is False and st['source_drift']==[]
assert len(manifest)==115 and sha(run/'source-manifest.json')==st['source_manifest_sha256']
assert all(sha(repo/p)==h for p,h in manifest.items())
for p,h in {**binding['files'],**binding['r_headers']}.items():assert sha(Path(p))==h,p
assert len(binding['r_headers'])==42
with tarfile.open(run/'changed-source.tar.gz') as t:
 members=[m for m in t.getmembers() if m.isfile()]
 for m in members:assert hashlib.sha256(t.extractfile(m).read()).hexdigest()==manifest[m.name]
assert len(members)==43
for stage in st['stages']:
 assert stage['status']=='passed' and stage['exit_code']==0
 log=run/(stage['name']+'.log');assert sha(log)==stage['log_sha256']
 assert not re.search(r'^warning(?:\[|:)|^Error|^error:',log.read_text(),re.M)
assert len(st['stages'])==12 and st['compiler_warnings']==st['link_warnings']==[]
expected=[('constructor_residual_probe_and_frame_equations',12,12,0,0),('constructor_source_budget_inheritance_and_failure_ownership',15,12,0,1),('constructor_composition_matches_frozen_reference',4,1,240,1),('projection_constructor_rhost_transfer',18,10,0,1)]
raw=[]
for n in range(1,4):
 text=(run/f'native-{n:02}.log').read_text()
 assert re.search(r'test result: ok\. 1 passed; 0 failed; 0 ignored; 0 measured;',text)
 assert ready['tests'][n-1]['id'] in text
 rows=re.findall(r'F6E_PROJECTION_CONSTRUCTOR_TEST (\{[^\n]*\})',text);assert len(rows)==1
 row=json.loads(rows[0]);assert row['source']==st['source_manifest_sha256'];raw.append(row)
hosted=(run/'ffi-r-hosted.log').read_text()
raw.extend(json.loads(s) for s in re.findall(r'F6E_PROJECTION_CONSTRUCTOR_TEST (\{[^\n]*\})',hosted));assert len(raw)==4
for row,(name,n,bad,values,models) in zip(raw,expected):
 assert row['test']==name and row['status']=='passed' and row['expected_cases']==row['executed_cases']==n
 assert row['expected_rejections']==row['rejected_cases']==bad and row['expected_values']==row['compared_values']==values and row['model_loads']==models
 assert 0<=row['max_abs_error']<=0.01
 assert (values!=0) or row['max_abs_error']==0
assert raw==json.loads((run/'native-test-receipts.json').read_text())
assert hosted.count('F6E_CONSTRUCTOR_R_HOSTED_SUCCESS outcomes=1 cases=18 rejections=10 model_loads=1')==1
assert raw[-1]['twin_cases']==4
twins=[json.loads(s) for s in re.findall(r'F6E_PROJECTION_CONSTRUCTOR_TWIN (\{[^\n]*\})',hosted)]
assert twins==json.loads((run/'native-twin-receipts.json').read_text()) and len(twins)==4
assert [x['case'] for x in twins]==['s0a0','s1a0','s0a1','s1a1']
for r,(s,a),total in zip(twins,[(0,0),(1,0),(0,1),(1,1)],[39027,41601,41229,42385]):
 p,i,e=r['profile'],r['inputs'],r['terms'];assert (len(p),len(i),len(e))==(27,15,14)
 assert p['version']==2 and (i['hidden_size'],i['layers'],i['previous_sites'])==(32,3,1)
 assert (i['steer_entries'],i['ablate_entries'],i['r_projection_fixed_bytes'],i['production_armed'])==(s,a,4096,0)
 assert p==twins[0]['profile'] and p['residual_probe_fixed_bytes']==522
 assert e['residual_probe_bytes']==(8*32*3+4*32+522 if s or a else 0)
 assert e['total_bytes']==total==sum(e[k] for k in ['projection_bytes','residual_probe_bytes','adapter_data_bytes','adapter_fixed_bytes','metadata_bytes','r_projection_bytes','r_adapter_bytes','existing_direction_estimate'])
 assert e['projection_bytes']==sum(e[k] for k in ['direction_bytes','plan_bytes','context_bytes','frame_bytes','probe_bytes'])
# Diagnose actual compiled v2 frame changes; the registry term is dynamic.
p=twins[0]['profile'];assert p['derive_frame_bytes']==11639 and p['ffi_command_bytes']==424 and p['ffi_response_bytes']==1512 and p['ffi_registry_bytes']==128 and p['ffi_fixed_bytes']==1800
assert (2*6+1)*8+24==128
assert p['ffi_fixed_bytes']-p['ffi_response_bytes']-p['ffi_registry_bytes']==160
with (run/'r-native-parity.csv').open() as f:rr=list(csv.DictReader(f))
assert len(rr)==56 and all(float(r['difference'])==0 for r in rr)
assert (run/'r-compiled-twins.log').read_text().count('F6E_CONSTRUCTOR_R_TWIN cases=4 compared_terms=56 exact_budgets=4 rejected_budget_minus_one=4 differences=0 models=0')==1
carried=json.loads((run/'carried-scopes.json').read_text());assert [r['stage'] for r in carried]==['r-source','clippy-llm']
for r in carried:assert sha(run/('carried-'+r['stage']+'.log'))==r['record']['log_sha256']
with (run/'carried-r-source-results.csv').open() as f:rrows=list(csv.DictReader(f))
assert [int(x['passed']) for x in rrows]==[9,48,4]
assert all(r['failed']=='0' and r['error']=='FALSE' and r['skipped']=='FALSE' and r['warning']=='0' for r in rrows)
c=json.loads((run/'r-accessor-build-binding.json').read_text());b=json.loads((run/'fresh-ffi-binding.json').read_text());cargo=json.loads((run/'cargo-static-artifact.json').read_text())
assert len(b['static_archives'])==9 and not b['old_library_reused']
for pth,h in {**b['static_archives'],**c['files']}.items():assert sha(Path(pth))==h,pth
assert sha(Path(b['dll_path']))==b['dll_sha256'] and Path(b['dll_path']).stat().st_size==b['dll_bytes']
assert sha(run/'ffi-hosted/entrypoint.c')==b['entrypoint_sha256']==sha(repo/'rebirth/src/entrypoint.c')
lib=repo/'rebirth/src/rust/target/debug/librelm.a';assert str(lib) in cargo['filenames'] and cargo['target']['crate_types']==['rlib','staticlib']
assert cargo['features']==['default','projection-private','spill']
assert 'static=relm-r-state' in c['cargo_record']['linked_libs']
object_path=Path(c['cargo_record']['out_dir'])/'projection_state.o'
for archive in [lib,object_path.parent/'librelm-r-state.a']:
 names=subprocess.check_output(['ar','t',str(archive)],text=True).splitlines();assert names.count('projection_state.o')==1
 assert hashlib.sha256(subprocess.check_output(['ar','p',str(archive),'projection_state.o'])).hexdigest()==sha(object_path)
report={'status':'passed','source_manifest_sha256':st['source_manifest_sha256'],'source_count':115,'source_archive_members':43,'R_headers':42,'stage_logs':12,'native_outcomes':4,'cases':49,'refusals':35,'compared_logits':240,'max_abs_error':raw[2]['max_abs_error'],'bound':0.01,'reported_tiny_model_loads':3,'decode_calls_measured':False,'R_native_twins':4,'R_native_terms':56,'R_exact_budgets':4,'R_budget_minus_one_refusals':4,'carried_R_cases':3,'carried_R_expectations':61,'carried_engine_clippy':True,'production_armed':False,'compiler_warnings':0,'link_warnings':0,'external_carried_warning':'testthat built under R4.5.2','dll_sha256':b['dll_sha256'],'C_object_sha256':sha(object_path),'C_object_bytes_bound_to_both_archives':True,'compiled_profile':p,'profile_scope':'v2 explicit residual fixed522/frame11639/FFIcommand424/response1512; registry capacity6 gives128 and ffi_fixed1800; separate from prior v1. R-host input4096 is a fixture, not actual full R owner inventory.','scope':'Private loaded-model constructor and R-host transfer with compiled twin only. Full configurable public R inventory binding, activation and installed acceptance remain pending.'}
(run/'owner-verification.json').write_text(json.dumps(report,indent=2)+'\n')
a=repo/'tests/projection/measurements'/run.name;a.mkdir(exist_ok=True)
for file in run.iterdir():
 if file.is_file():shutil.copyfile(file,a/file.name)
shutil.copyfile(__file__,a/Path(__file__).name)
files={file.name:{'bytes':file.stat().st_size,'sha256':sha(file)} for file in sorted(a.iterdir()) if file.is_file()}
(a/'file-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print(json.dumps(report))
