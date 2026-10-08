import csv,hashlib,json,math,re,shutil,subprocess,tarfile
from pathlib import Path
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');root=Path('/private/tmp/relm-f6e');run=root/'combined-token-binding-20261008-033744';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
st=json.loads((run/'status.json').read_text());manifest=json.loads((run/'source-manifest.json').read_text());bind=json.loads((run/'owner-binding.json').read_text());binary=json.loads((run/'binary-bindings.json').read_text())
assert st['status']=='awaiting_owner_verification' and st['source_drift']==[] and st['public_operator_enabled'] is False
assert len(manifest)==114 and sha(run/'source-manifest.json')==st['source_manifest_sha256']
for p,h in manifest.items():assert sha(repo/p)==h,p
for p,h in {**bind['files'],**bind['r_headers']}.items():assert sha(Path(p))==h,p
assert len(bind['r_headers'])==42
with tarfile.open(run/'changed-source.tar.gz') as t:
 members=t.getmembers();assert len(members)==46
 for member in members:assert hashlib.sha256(t.extractfile(member).read()).hexdigest()==manifest[member.name]
assert len(st['stages'])==13
for s in st['stages']:
 assert s['status']=='passed' and s['exit_code']==0
 log=run/(s['name']+'.log');assert sha(log)==s['log_sha256']
 assert not re.search(r'^warning(?:\[|:)|^Warning|^Error|^error:',log.read_text(),re.M)
 for line in log.read_text().splitlines():
  if line.startswith('{'):
   j=json.loads(line)
   if j.get('reason')=='compiler-message':assert j['message']['level']!='warning'
raw=(run/'native-token-shape.log').read_text()
assert 'projection_combined_test::tests::fixed_fixture_shape' in raw and re.search(r'test result: ok\. 1 passed; 0 failed; 0 ignored; 0 measured;',raw)
records=re.findall(r'F6E_PROJECTION_COMBINED_TOKEN_TEST (\{[^\n]*\})',raw);assert len(records)==1
shape=json.loads(records[0]);assert shape==dict(test='fixed_fixture_shape',status='passed',expected_cases=6,executed_cases=6,expected_rejections=4,rejected_cases=4,model_count=0)
assert shape==json.loads((run/'native-token-receipt.json').read_text())
mode_records=[]
for mode in ['default','private']:
 b=binary[mode];assert ('projection-private' in b['artifact']['features'])==(mode=='private')
 assert len(b['static_archives'])==9 and 'staticlib' in b['artifact']['target']['crate_types']
 assert str(repo/'rebirth/src/rust/target/debug/librelm.a') in b['artifact']['filenames']
 for path,h in {**b['static_archives'],**b['C_files']}.items():
  copy=b['local_copies'].get(path);actual=Path(copy['path']) if copy else Path(path)
  assert sha(actual)==h,path
  if copy:assert copy['sha256']==h
 assert sha(Path(b['dll_path']))==b['dll_sha256'] and Path(b['dll_path']).stat().st_size==b['dll_bytes']
 assert sha(run/(mode+'-ffi')/'entrypoint.c')==b['entrypoint_sha256']==sha(repo/'rebirth/src/entrypoint.c')
 copies={Path(k).name:Path(v['path']) for k,v in b['local_copies'].items()}
 for archive in ['librelm.a','librelm-r-state.a']:
  assert subprocess.check_output(['ar','t',str(copies[archive])],text=True).splitlines().count('projection_state.o')==1
  assert hashlib.sha256(subprocess.check_output(['ar','p',str(copies[archive]),'projection_state.o'])).hexdigest()==sha(copies['projection_state.o'])
 rr=re.findall(r'^F6E_PROJECTION_COMBINED_TOKEN_R (\{[^\n]*\})$',(run/(mode+'-registration.log')).read_text(),re.M);assert len(rr)==1
 row=json.loads(rr[0]);assert row==dict(mode=mode,status='passed',expected_cases=2,executed_cases=2,expected_rejections=1,rejected_cases=1,model_count=0);mode_records.append(row)
assert mode_records==json.loads((run/'registration-receipts.json').read_text())
with (run/'combined-cases.csv').open() as f:rows=list(csv.DictReader(f))
expected=['actual_model_shape','actual_budget_above_public_minimum','combined_R_charge','all_native_R_terms','combined_budget_minus_one','minus_one_before_constructor','source_unchanged_after_refusal','combined_exact_budget_constructed','actual_candidate_metadata','actual_unhashed_candidate_state','actual_R_materialization_within_bound','five_array_bytes','exact_candidate_closed','projected_handle_configured','duplicate_site_before_transfer','duplicate_never_constructed','steering_inherits_static_projection','new_residual_probe_charged','mixed_accumulated_entries','mixed_five_arrays_measured','descendant_survives_parent_close','closed_source_refused','delivered_handle_R_failure','delivered_native_owner_closed','original_reset_exact','derived_close_idempotent','original_closed']
refusals={'combined_budget_minus_one','duplicate_site_before_transfer','closed_source_refused','delivered_handle_R_failure'}
assert [r['case'] for r in rows]==expected
for r in rows:assert r['status']=='passed' and r['refusal']==str(r['case'] in refusals).upper()
text=(run/'combined-R-binding.log').read_text();assert re.findall(r'^F6E_BINDING_CASE (\S+) refusal=(?:TRUE|FALSE)$',text,re.M)==expected
assert text.count('F6E_COMBINED_R_BINDING cases=27 refusals=4 constructor_calls=5 model_loads=1 source_reset=TRUE closed=TRUE')==1
assert text.count('F6E_COMBINED_TOKEN_LOGITS calls=5 values=240 fixed_tokens=1,7,13 numerical_oracle=FALSE')==1
with (run/'combined-raw-token-logits.csv').open() as f:raw=list(csv.DictReader(f))
assert len(raw)==240
for n,r in enumerate(raw):assert r['call']==str(n//48+1) and r['vocab']==str(n%48) and math.isfinite(float(r['value']))
values=[[r['value'] for r in raw[k*48:(k+1)*48]] for k in range(5)]
assert values[0]==values[1]==values[4] and values[2]==values[3]
# Independent integer recomputation of every ledger term; no product import.
profiles={};totals={};registry={}
for name,mode,S,A,old,B in [('exact',1,0,0,0,0),('steer',0,1,0,1,0),('mixed',0,1,2,1,96)]:
 with (run/f'combined-{name}-terms.csv').open() as f:raw=list(csv.DictReader(f))
 sections={s:{r['field']:int(r['value']) for r in raw if r['section']==s} for s in ['profile','inputs','terms']};p,i,e=(sections[s] for s in sections)
 assert (len(p),len(i),len(e))==(27,15,14)
 assert (i['mode'],i['hidden_size'],i['layers'],i['previous_sites'],i['steer_entries'],i['ablate_entries'],i['source_baseline_values'],i['production_armed'])==(mode,32,3,old,S,A,B,0)
 assert p['version']==2 and p['ffi_command_bytes']==744 and p['derive_frame_bytes']==11959 and p['residual_probe_fixed_bytes']==522
 H,D=32,3;sites=old+mode;plans=1 if mode==0 else 1+int(old>0);entries=old if mode==0 else old+sites;runtimes=2 if mode==0 else plans
 x={}
 x['direction_bytes']=sites*(8*H+p['direction_arc_header_bytes'])
 x['plan_bytes']=plans*p['plan_arc_bytes']+entries*p['site_bytes']
 x['context_bytes']=runtimes*(p['runtime_bytes']+4*H)+2*p['model_owner_bytes']
 x['frame_bytes']=p['derive_frame_bytes']+p['callback_frame_bytes']+p['ffi_fixed_bytes']+p['error_format_bytes']
 x['probe_bytes']=20*H+sum(p[k] for k in ['direction_arc_header_bytes','plan_arc_bytes','site_bytes','runtime_bytes','probe_state_bytes','model_owner_bytes','probe_frame_bytes'])
 x['projection_bytes']=sum(x.values())
 x['residual_probe_bytes']=8*H*D+4*H+p['residual_probe_fixed_bytes'] if S or A else 0
 x['adapter_data_bytes']=4*B+(8*H*D+4*H+8*H*S+4*S if S else 0)+(8*H*D+16*A if A else 0)
 x['adapter_fixed_bytes']=p['adapter_fixed_bytes'];x['metadata_bytes']=i['metadata_bytes']+i['metadata_scratch_bytes']+p['metadata_owner_bytes']
 # For H32, R double[32] is 48+256; removing empty-vector48 leaves256.
 x['r_projection_bytes']=i['r_projection_fixed_bytes']+(old+2*mode)*256
 x['r_adapter_bytes']=i['r_adapter_bytes'];x['existing_direction_estimate']=i['existing_direction_estimate']
 x['total_bytes']=sum(x[k] for k in ['projection_bytes','residual_probe_bytes','adapter_data_bytes','adapter_fixed_bytes','metadata_bytes','r_projection_bytes','r_adapter_bytes','existing_direction_estimate'])
 assert x==e,(name,x,e)
 assert p['ffi_fixed_bytes']==p['ffi_response_bytes']+p['ffi_registry_bytes']+160
 cap=(p['ffi_registry_bytes']-32)//16;assert 16*cap+32==p['ffi_registry_bytes'];registry[name]={'capacity':cap,'bytes':p['ffi_registry_bytes']}
 profiles[name]=p;totals[name]=e['total_bytes']
fixed={k:v for k,v in profiles['exact'].items() if k not in ['ffi_registry_bytes','ffi_fixed_bytes']}
for p in profiles.values():assert {k:v for k,v in p.items() if k not in ['ffi_registry_bytes','ffi_fixed_bytes']}==fixed
with (run/'combined-materialization.csv').open() as f:raw=list(csv.DictReader(f))
assert len(raw)==1;mat={k:int(v) for k,v in raw[0].items()}
assert mat==dict(exact_budget=1273947,actual_R_bytes=1210312,R_bound_bytes=1245080,workspace_bytes=12432,model_skeleton_bytes=1206688,state_extra_bytes=1272,flat_bytes=864,mixed_flat_bytes=1160,construct_calls=5,model_loads=1)
assert mat['actual_R_bytes']<=mat['R_bound_bytes']<mat['exact_budget']==totals['exact']
report={'status':'passed','source_manifest_sha256':st['source_manifest_sha256'],'source_count':114,'source_archive_members':46,'stage_logs':13,'R_headers':42,'new_outcomes':4,'new_cases':37,'new_refusals':10,'combined_R_cases':27,'combined_R_refusals':4,'model_loads':1,'constructor_calls':5,'independent_integer_terms':42,'raw_token_calls':5,'raw_token_values':240,'raw_values_scope':'fixed-token source/refusal/reset and parent-close equality, NOT new numerical golden accuracy','original_reset_equal':True,'child_survives_parent_close':True,'forced_R_wrap_failure_closes_delivered_handle':True,'materialization':mat,'totals':totals,'dynamic_registry':registry,'compiled_fixed_profile':fixed,'DLL_hashes':{mode:binary[mode]['dll_sha256'] for mode in binary},'C_bytes_bound_to_both_archives_in_both_modes':True,'compiler_linker_warnings':0,'carried_parent_scope':'bridge plus registration3outcomes6cases2refusals at29835e92, separate from these new helper executions','scope':'Actual private constructor through R ownership/inventory, configured exact/minus-one budget, inheritance and cleanup. Default public activation/installed/resource/evaluation/instrumented acceptance still pending.'}
(run/'owner-verification.json').write_text(json.dumps(report,indent=2)+'\n')
arc=repo/'tests/projection/measurements'/run.name;arc.mkdir(exist_ok=True)
for p in run.rglob('*'):
 if p.is_file() and 'binding-binaries' not in p.parts and p.suffix in ['.json','.csv','.log','.py','.R','.c','.patch','.gz']:
  dst=arc/p.relative_to(run);dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dst)
shutil.copyfile(__file__,arc/Path(__file__).name)
files={str(p.relative_to(arc)):{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(arc.rglob('*')) if p.is_file() and p.name!='file-manifest.json'}
(arc/'file-manifest.json').write_text(json.dumps(files,indent=2)+'\n');print(json.dumps(report,indent=2))
