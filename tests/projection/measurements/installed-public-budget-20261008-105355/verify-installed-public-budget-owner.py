import csv,hashlib,json,math,re,shutil,subprocess,tarfile
from pathlib import Path
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');root=Path('/private/tmp/relm-f6e');run=root/'installed-public-budget-20261008-105355';lib=root/'public-library-budget/relm';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
s=json.loads((run/'status.json').read_text());b=json.loads((run/'owner-binding.json').read_text());m=json.loads((run/'source-manifest.json').read_text());im=json.loads((run/'installed-manifest.json').read_text())
assert s['status']=='awaiting_owner_verification' and s['source_drift']==s['installed_drift']==[]
assert len(m)==145 and sha(run/'source-manifest.json')==s['source_manifest_sha256']=='534785f188b08bcb39ac143f48002ebe41d6e9e6394df81c199ace5dffaf85db'
for p,h in m.items():assert sha(repo/p)==h,p
for p,h in im.items():assert sha(lib/p)==h,p
for p,h in b['files'].items():assert sha(Path(p))==h,p
for p,h in b['carried_files'].items():assert sha(Path(b['parent_directory'])/p)==sha(run/('carried-'+p))==h,p
assert sha(lib/'libs/relm.so')==b['native']['sha256']=='d7f946c23fa078a3426fc92791f9615f36a81643f18feab43741603ff42533fb'
assert (repo/'rebirth/NAMESPACE').read_bytes()==subprocess.check_output(['git','show','HEAD:rebirth/NAMESPACE'],cwd=repo)==(lib/'NAMESPACE').read_bytes()
with tarfile.open(run/'R-source.tar.gz') as t:
 members=t.getmembers()
 for row in members:assert row.isfile() and hashlib.sha256(t.extractfile(row).read()).hexdigest()==m[row.name]
assert [x['name'] for x in s['stages']]==['install','installed-source-usage','public-model']
for st in s['stages']:
 log=run/(st['name']+'.log');assert st['status']=='passed' and st['exit_code']==0 and sha(log)==st['log_sha256']
 assert not re.search(r'^(?:Warning|warning|Error|error|ld: warning:)',log.read_text(),re.M)
assert (run/'installed-source-usage.log').read_text().strip()=='F6E_INSTALLED_SOURCE_FORMALS_BODIES_MATCH functions=259'
rows=lambda name:list(csv.DictReader((run/name).open()))
cases=rows('public-cases.csv');assert [x['case'] for x in cases]==b['expected_cases'] and len(cases)==27
assert all(x['status']=='passed' for x in cases) and sum(x['refusal']=='TRUE' for x in cases)==6
log=(run/'public-model.log').read_text();assert re.findall(r'^F6E_PUBLIC_CASE (\S+) refusal=(?:TRUE|FALSE)$',log,re.M)==b['expected_cases']
assert log.splitlines()[-1]=='F6E_INSTALLED_PUBLIC_REMAINING cases=27 refusals=6 backend_handles=cpu,metal no_download=TRUE carried_parent_cases=10'
parent=rows('carried-public-cases.csv');assert len(parent)==10 and all(x['status']=='passed' for x in parent)
inspector=root/'inspect-installed-public-raw.R';shutil.copy2(inspector,run/inspector.name)
# Read-only retained-RDS analysis. No relm namespace, DLL, model or inference.
with (run/'owner-raw-inspection.log').open('w') as out:subprocess.run(['Rscript','--vanilla',str(inspector)],stdout=out,stderr=subprocess.STDOUT,check=True)
assert (run/'owner-raw-inspection.log').read_text().strip()=='F6E_PUBLIC_OWNER_RAW captures=4 width=896 pairs=2 schema=2 ledger_terms=14 structured=1 streamed_tokens=4 refusal_payloads=5 live_states=3 delivered_before_cancel=2 native_generated_tokens=3 model_calls=0'
# Independently reconstruct mean contrast/unit direction from raw four captures.
captures=rows('carried-public-captures.csv');assert len(captures)==3584
vectors=[]
for call in range(1,5):
 v=[x for x in captures if int(x['call'])==call];assert len(v)==896 and [int(x['neuron']) for x in v]==list(range(1,897))
 assert all(x['component']=='mlp_out' and int(x['layer'])==12 and int(x['token_pos'])==9 for x in v)
 vectors.append([float(x['value']) for x in v])
contrast=[((vectors[0][j]-vectors[1][j])+(vectors[2][j]-vectors[3][j]))/2 for j in range(896)]
norm=math.sqrt(sum(x*x for x in contrast));unit=[x/norm for x in contrast]
d=[float(x['value']) for x in rows('owner-direction.csv')];assert len(d)==896
direction_error=max(abs(a-z) for a,z in zip(d,unit));assert all(abs(a-z)<=1e-12*(1+abs(z)) for a,z in zip(d,unit))
v=rows('public-projection-values.csv');assert len(v)==896 and [int(x['neuron']) for x in v]==list(range(1,897))
h=[float(x['before']) for x in v];after=[float(x['after']) for x in v]
assert all(float(x['direction'])==d[j] for j,x in enumerate(v))
dot=sum(d[j]*h[j] for j in range(896));expected=[h[j]-d[j]*dot for j in range(896)]
errors=[abs(after[j]-expected[j]) for j in range(896)];assert all(errors[j]<=2e-6*(1+abs(expected[j])) for j in range(896))
# Native returned terms, recomputed in independent scalar Python for this actual
# new-site P0=0, no residual-entry case; all ownership constants are compiled.
p={x['field']:int(x['value']) for x in rows('owner-profile.csv')};i={x['field']:int(x['value']) for x in rows('owner-inputs.csv')};t={x['field']:int(x['value']) for x in rows('owner-terms.csv')}
assert len(p)==27 and len(i)==15 and len(t)==14 and i['hidden_size']==896 and i['mode']==1 and i['previous_sites']==i['steer_entries']==i['ablate_entries']==0
h=i['hidden_size'];e={'direction_bytes':8*h+p['direction_arc_header_bytes'],'plan_bytes':p['plan_arc_bytes']+p['site_bytes'],'context_bytes':p['runtime_bytes']+4*h+2*p['model_owner_bytes'],'frame_bytes':p['derive_frame_bytes']+p['callback_frame_bytes']+p['ffi_fixed_bytes']+p['error_format_bytes'],'probe_bytes':20*h+p['direction_arc_header_bytes']+p['plan_arc_bytes']+p['site_bytes']+p['runtime_bytes']+p['probe_state_bytes']+p['model_owner_bytes']+p['probe_frame_bytes']}
e['projection_bytes']=sum(e.values());e.update(residual_probe_bytes=0,adapter_data_bytes=4*i['source_baseline_values'],adapter_fixed_bytes=p['adapter_fixed_bytes'],metadata_bytes=i['metadata_bytes']+i['metadata_scratch_bytes']+p['metadata_owner_bytes'],r_projection_bytes=i['r_projection_fixed_bytes']+16*h,r_adapter_bytes=i['r_adapter_bytes'],existing_direction_estimate=i['existing_direction_estimate'])
e['total_bytes']=sum(e[k] for k in ['projection_bytes','residual_probe_bytes','adapter_data_bytes','adapter_fixed_bytes','metadata_bytes','r_projection_bytes','r_adapter_bytes','existing_direction_estimate']);assert e==t
assert p['ffi_registry_bytes']==96 and p['ffi_fixed_bytes']==p['ffi_response_bytes']+96+160 and e['total_bytes']==1520395
r={'status':'PASS','source_manifest_sha256':s['source_manifest_sha256'],'source_count':len(m),'source_archive_members':len(members),'installed_files':len(im),'stage_logs':3,'DLL_sha256':b['native']['sha256'],'installed_functions_compared':259,'codetools_diagnostics':0,'warnings':0,'new_public_cases':27,'expected_refusals':6,'parent_cases_carried_at_original_source':10,'attempt_counts':{'load':2,'trace':0,'generate':18,'logits':1,'derive':6},'raw_capture_values_carried':3584,'independent_direction_values':896,'direction_max_abs_error':direction_error,'public_same_row_values':896,'public_same_row_max_abs_error':max(errors),'public_same_row_bound':'2e-6*(1+abs(expected)) unchanged','native_ledger_terms_recomputed':14,'exact_budget':e['total_bytes'],'minus_one_actual_class':'relm_error_oom','cancel_receipt':{'states_delivered':3,'token_events_delivered':2,'error_generated_tokens_reported':3,'scope':'distinct counters retained; no equality of delivered and native-reported counts claimed'},'scope':'Installed R/public CPU/Metal text, structured, stream/live and ownership; operational prompts only, no efficacy/timing/new offload proof','driver_status_preserved':s['status']}
(run/'owner-verification.json').write_text(json.dumps(r,indent=2)+'\n')
arc=repo/'tests/projection/measurements'/run.name;assert not arc.exists();arc.mkdir()
for path in run.iterdir():
 if path.is_file() and path.suffix in ['.json','.csv','.log','.py','.R','.txt','.gz','.rds']:shutil.copy2(path,arc/path.name)
shutil.copy2(__file__,arc/Path(__file__).name)
(arc/'file-manifest.json').write_text(json.dumps({x.name:{'bytes':x.stat().st_size,'sha256':sha(x)} for x in sorted(arc.iterdir()) if x.is_file()},indent=2)+'\n')
print(json.dumps(r,indent=2))
