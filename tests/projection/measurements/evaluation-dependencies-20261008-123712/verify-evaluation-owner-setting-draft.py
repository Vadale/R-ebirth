"""Retained-output owner audit; no producer, inference, build or RNG replay."""
from pathlib import Path
import csv, hashlib, json, re, shutil
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');base=Path('/private/tmp/relm-f6e')
root=base/'evaluation-dependencies-20261008-123712'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
read=lambda p:json.loads(Path(p).read_text())
original=read(root/'raw-manifest.json')
for n,h in original.items(): assert sha(root/n)==h,n
cfg=read(root/'config.json')
for n,h in cfg['source_hashes'].items(): assert sha(Path(n) if Path(n).is_absolute() else repo/n)==h,n
for n,h in cfg['installed_hashes'].items(): assert sha(Path(cfg['library'])/n)==h,n
for n in ['sources-after.csv','sources-final.csv']: assert (root/n).read_bytes()==(root/'sources-before.csv').read_bytes()
for row in csv.DictReader((root/'sources-before.csv').open()): assert sha(root/row['snapshot_file'])==row['sha256']
dependencies=read(cfg['dependency_manifest']);assert sha(cfg['dependency_manifest'])==cfg['dependency_manifest_sha256']
for p in dependencies:
 for name,h in p['files'].items(): assert sha(Path(p['path'])/name)==h
parent=Path(cfg['construction_parent']['directory'])
for n,h in cfg['construction_files'].items(): assert sha(parent/n)==sha(root/n)==h,n
assert sha(parent/'owner-partial-verification.json')==cfg['construction_parent']['owner_sha256']
assert sha(cfg['model'])==cfg['model_sha256']
assert sha(Path(cfg['library'])/'libs/relm.so')==cfg['dll_sha256']
assert sha(root/'f6e_log_capture.dylib')==cfg['logger_sha256']
counts=read(root/'attempt-counts.json');assert counts==dict(load=1,trace=0,derive=107,generate=122,tokenize=1)
report=read(root/'complete-report.json');lock=read(root/'selection-lock.json')
rows={k:list(csv.DictReader((root/(k+'.csv')).open())) for k in ('selection','evaluation','views')}
assert [len(rows[k]) for k in rows]==[72,48,2]
assert all(r['status']=='ok' for k in ('selection','evaluation') for r in rows[k])
assert all(r['status']=='cancelled' for r in rows['views'])
assert max(float(r['ended_unix']) for r in rows['selection'])<=lock['locked_at_unix']<=min(float(r['started_unix']) for r in rows['evaluation'])
assert sha(root/'selection-report.json')==lock['selection_report']['sha256']
assert report['selection']==read(root/'selection-report.json')['selection']
assert report['selected']==dict(add=lock['selected_add'],project=lock['selected_project'])
assert all(r['selection_lock_sha256']==sha(root/'selection-lock.json') for k in ('evaluation','views') for r in rows[k])
baseline={r['item_id']:r['metrics'] for r in report['selection'] if r['setting']=='baseline'}
eligible=[]
for e in report['eligibility']:
 selected=[r for r in report['selection'] if r['operator']==e['operator'] and r['coefficient']==e['coefficient']]
 assert len(selected)==6
 quality=all(r['metrics']['required']>=baseline[r['item_id']]['required'] and all(r['metrics'][k]<=baseline[r['item_id']][k] for k in ('empty','truncated','repeated')) for r in selected)
 chars=sum(r['metrics']['characters'] for r in selected)
 assert quality==e['quality_preserved'] and chars==e['total_characters']
 admitted=quality and chars<sum(r['characters'] for r in baseline.values());assert admitted==e['eligible']
 if admitted:eligible.append((e['operator'],chars,abs(e['coefficient']),e['coefficient']))
assert {op:min((c,a,s) for o,c,a,s in eligible if o==op)[2] for op in ('add','project')}==report['selected']
log=(root/'experiment.log').read_text()
actual=re.findall(r'^F6E_EVALUATION_RUN (\S+) (\S+)$',log,re.M)
assert actual==[(r['run_id'],r['status']) for k in rows for r in rows[k]]
assert log.count('F6E_EVALUATION_PRODUCER_COMPLETE setting_attempts=122 generation_attempts=122 construction_captures=24 new_trace_attempts=0 model_load_attempts=1 tokenizer_attempts=1')==1
assert not (root/'warnings.json').exists()
native=(root/'native-placement.log').read_text();native_warnings=[x for x in native.splitlines() if x.startswith('[3]')]
assert native_warnings==read(root/'cpu-evidence.json')['retained_warnings'] and len(native_warnings)==1
assert not any(x.startswith('[4]') for x in native.splitlines())
cpu=read(root/'cpu-evidence.json');assert cpu['actual_offload_layers']==0 and cpu['actual_total_layers']==25
assert 'offloaded 0/25 layers to GPU' in (root/'placement-load.log').read_text()
assert sha(root/'placement-load.log')==cpu['raw_log']['sha256']
assert sha(root/'token-warning-diagnosis.json')==cpu['tokenizer_diagnosis']['sha256']
assert read(root/'owner-rds-verification.json')['status']=='PASS'
result=dict(status='PASS',source_count=len(cfg['source_hashes']),installed_count=len(cfg['installed_hashes']),
 original_file_hashes_verified=len(original),dependency_packages=len(dependencies),dependency_file_hashes=sum(len(p['files']) for p in dependencies),
 source_installed_dependency_drift=False,attempt_counts=counts,successful_generations=120,expected_cancelled_views=2,
 carried_construction_files=40,carried_captures=24,selected=report['selected'],selection_locked_before_final=True,
 zero_identity_pairs=28,independent_R_metric_values=720,independent_R_intervals=36,retained_state_values=3584,
 native_warning=native_warnings[0],native_errors=0,R_warnings=0,models_rerun_for_verification=0,
 exact_DLL=cfg['dll_sha256'],scientific_scope='Valid fixed-corpus experiment; no population, pure-operator or general efficacy claim. All 8 baseline and 7 selected projection final outputs hit the 256-token cap.',
 original_driver_status_preserved='awaiting_owner_verification',
 audit_note='Initial independent RDS inspector read empty generated-prefix CSV fields as numeric NA. Original script/log retained; explicit character parsing preserves actual empty fields. No producer, report, metric, data or model rerun.')
(root/'owner-verification.json').write_text(json.dumps(result,indent=2)+'\n')
dest=repo/'tests/projection/measurements'/root.name;dest.mkdir(exist_ok=False)
for p in root.rglob('*'):
 if p.is_file() and p.suffix not in ('.dylib','.so','.a'):
  q=dest/p.relative_to(root);q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
for n in ['verify-evaluation-owner.py','verify-evaluation-rds-owner.R','verify-evaluation-rds-owner-csv-draft.R','evaluation-status.json','evaluation-dependencies-launch.json']:
 shutil.copy2(base/n,dest/n)
(dest/'local-binary-hashes.json').write_text(json.dumps({str(p):sha(p) for p in root.rglob('*') if p.is_file() and p.suffix in ('.dylib','.so','.a')},indent=2)+'\n')
files={str(p.relative_to(dest)):sha(p) for p in dest.rglob('*') if p.is_file() and p.name!='archive-manifest.json'}
(dest/'archive-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print(json.dumps(dict(result=result,archive_files=len(files),manifest_sha256=sha(dest/'archive-manifest.json'))))
