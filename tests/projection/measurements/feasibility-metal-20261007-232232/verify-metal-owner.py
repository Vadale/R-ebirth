"""Independent owner audit of retained output; no native/model rerun."""
from pathlib import Path
import hashlib,json,re,statistics,tarfile
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
run=Path('/private/tmp/relm-f6e/feasibility-metal-20261007-232232')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
s=json.loads((run/'status.json').read_text());assert s['status']=='awaiting_owner_verification'
assert s['source_drift']==s['ready_source_drift']==[]
manifest=json.loads((run/'source-manifest.json').read_text());assert sha(run/'source-manifest.json')==s['source_manifest_sha256']
for p,h in manifest.items():assert sha(repo/p)==h,p
ready=json.loads((run/'metal-ready-owner.json').read_text())
for p,h in ready['source_hashes'].items():assert sha(repo/p)==h,p
for p in ('verify-feasibility-metal.py','metal-collector.py'):assert sha(run/p)==ready['driver_hashes'][p]
with tarfile.open(run/'changed-source.tar.gz') as archive:
 for member in archive.getmembers():
  assert member.isfile()
  assert hashlib.sha256(archive.extractfile(member).read()).hexdigest()==manifest[member.name]
 archived_sources=len(archive.getmembers())
assert len(s['stages'])==7
logs={}
for stage in s['stages']:
 assert stage['status']=='passed' and stage['exit_code']==0
 log=run/(stage['name']+'.log');assert sha(log)==stage['log_sha256']
 logs[stage['name']]=log.read_text()
assert not any(re.search(r'(?im)^\s*warning(?:\[|:)',log) for log in logs.values())
def markers(log,prefix):return [json.loads(line.split(prefix+' ',1)[1]) for line in log.splitlines() if prefix+' ' in line]
expected=[('projection_buffer_identity_accepts_only_host_or_default_shared',21,17),('projection_capacity_ledger_matches_owned_buffers',8,1),('projection_classifier_accepts_only_declared_dense_sites',12,8)]
for i,(name,cases,neg) in enumerate(expected,1):
 log=logs[f'affected-{i:02}'];assert 'test projection::tests::'+name+' ... ' in log
 assert re.findall(r'test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored;',log)==[('1','0','0')]
 rows=markers(log,'F6E_PROJECTION_TEST');assert len(rows)==1;r=rows[0]
 assert r['test_id']=='projection::tests::'+name and r['status']=='passed'
 assert r['executed_cases']==r['expected_cases']==cases and r['negative_controls_rejected']==r['negative_controls_expected']==neg
 assert r['compared_values']==r['expected_values']==0
 assert r['source_manifest_sha256']==s['source_manifest_sha256'] and r['reference_manifest_sha256']==s['reference_manifest_sha256']
log=logs['benchmark-metal'];assert re.findall(r'test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored;',log)==[('1','0','0')]
b=markers(log,'F6E_PROJECTION_BENCH');assert b==json.loads((run/'benchmark-metal.json').read_text()) and len(b)==1;b=b[0]
assert b['source_manifest_sha256']==s['source_manifest_sha256'] and b['model_sha256']==s['model_sha256']
samples=markers(log,'F6E_PROJECTION_SAMPLE');assert samples==b['samples'] and len(samples)==20
names=['callback_free','dormant','zero','active_one','active_multi']
orders=[names,names,['active_multi','zero','callback_free','active_one','dormant'],['active_one','dormant','active_multi','zero','callback_free']]
for rnd,order in enumerate(orders):
 assert [x['mode'] for x in samples[5*rnd:5*rnd+5]]==order
 for x in samples[5*rnd:5*rnd+5]:assert x['round']==rnd and x['warmup']==(rnd==0) and x['decoded_tokens']==128
med=[statistics.median(x['elapsed_seconds'] for x in samples if not x['warmup'] and x['mode']==name) for name in names]
assert med==b['median_elapsed_seconds'];ratio=med[1]/med[0];assert abs(ratio-b['dormant_ratio'])<1e-12 and ratio<=1.05
assert b['dormant_limit']==1.05 and b['active_limit'] is None
for role,depth in (('hooked_backend',24),('callback_free_backend',24)):
 r=b[role];assert r['offloaded_layers']==[[depth+1,depth+1]] and r['resolved_backend']=='metal'
 assert 'MTL0' in r['selected_devices'][0] and any(n=='MTL0' and m>0 for n,m in r['compute_buffers_mib'])
 assert f': offloaded {depth+1}/{depth+1} layers to GPU' in r['native_load_log']
t=b['tiny_forward'];assert t==markers(log,'F6E_PROJECTION_METAL_FORWARD')[0]
assert t['executed_cases']==t['expected_cases']==15 and t['compared_values']==t['expected_values']==34748 and t['max_abs_error']<=.01
assert t['backend']['offloaded_layers']==[[4,4]]
same=markers(log,'F6E_PROJECTION_SAME_ROW');assert same==[t['same_row']] and same[0]['compared_values']==same[0]['expected_values']==2944 and same[0]['max_scaled_error']<=2e-6
buffers=markers(log,'F6E_PROJECTION_BUFFER');assert buffers==json.loads((run/'metal-buffer-receipts.json').read_text()) and len(buffers)==71
assert sum(r['width']==32 for r in buffers)==57 and sum(r['width']==896 for r in buffers)==14
for r in buffers:
 assert (r['kind'],r['is_host'],r['flags'],r['device_type'],r['view_offset'])==(2,0,255,1,0)
 assert r['usage'] in (0,2) and r['bytes']==4*r['width']*r['rows'] and r['rows']>0
 assert all(r[k] is True for k in ('dtype_f32','data_nonnull','contiguous','no_staging_supported')) and r['decode_failed'] is False
 for key,want in [('type_name_bytes','MTL0'),('device_name_bytes','MTL0'),('registry_name_bytes','MTL')]:
  vals=r[key];end=vals.index(0);assert bytes(vals[:end]).decode()==want and not any(vals[end:])
ledger=markers(logs['affected-02'],'F6E_PROJECTION_LEDGER')[0]
assert ledger==json.loads((run/'ledger-verification.json').read_text())['compiled']
assert (ledger['buffer_info_size'],ledger['projection_info_size'],ledger['proof_slots'],ledger['total'])==(104,128,32,18633740)
assert ledger['total']==sum(ledger[k] for k in ('direction_bytes','plan_bytes','runtime_bytes','probe_bytes','frame_bytes'))<64*1024**2
result={'status':'verified','run_overall_status_preserved':s['status'],'source_manifest_sha256':s['source_manifest_sha256'],'source_files':len(manifest),'archived_sources':archived_sources,'stage_logs':len(logs),'warnings':0,'affected_outcomes':3,'guard_capacity_classifier_cases':[21,8,12],'negative_controls':[17,1,8],'metal_forward':{'cases':15,'values':34748,'max_abs_error':t['max_abs_error'],'same_row_values':2944,'same_row_max_error':same[0]['max_abs_error']},'buffer_receipts':71,'actual_shared_device':'MTL0','samples':20,'tokens_per_sample':128,'medians':med,'dormant_ratio':ratio,'dormant_limit':1.05,'active_limit':None,'private_max_ledger_bytes':ledger['total'],'public_feature_acceptance':False,'scope':'scoped private Metal correction; earlier CPU/native gates retain exact source scopes; no public R/FFI/resource/UB acceptance'}
(run/'owner-verification.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
