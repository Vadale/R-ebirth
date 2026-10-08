from pathlib import Path
import csv, json, hashlib, shutil
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); base=Path('/private/tmp/relm-f6e')
run=base/'evaluation-tokenizer-20261008-120800'; dest=repo/'tests/projection/measurements'/run.name
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
original=json.loads((run/'partial-file-manifest.json').read_text())
for n,h in original.items(): assert sha(run/n)==h,n
cfg=json.loads((run/'config.json').read_text())
for n,h in cfg['source_hashes'].items(): assert sha(Path(n) if Path(n).is_absolute() else repo/n)==h,n
for n,h in cfg['installed_hashes'].items(): assert sha(Path(cfg['library'])/n)==h,n
assert (run/'sources-before.csv').read_bytes()==(run/'sources-after.csv').read_bytes()
rows=list(csv.DictReader((run/'selection.csv').open()))
assert len(rows)==72 and [r['run_id'] for r in rows]==[f's{i:03}' for i in range(1,73)]
assert all(r['status']=='error' and not r['text_file'] for r in rows)
for r in rows:
 for kind in ('events','error'):
  assert sha(run/r[kind+'_file'])==r[kind+'_sha256']
 assert not list(csv.DictReader((run/r['events_file']).open()))
 errors=list(csv.DictReader((run/r['error_file']).open()))
 assert len(errors)==1 and errors[0]['reason']=='async_dependency'
for n in ('selection-lock.json','evaluation.csv','views.csv'): assert not (run/n).exists()
counts=json.loads((run/'attempt-counts.json').read_text())
assert counts==dict(load=1,trace=24,derive=66,generate=72,tokenize=0)
construction=list(csv.DictReader((run/'construction.csv').open()))
assert len(construction)==24
for row in construction: assert sha(run/row['capture_file'])==row['capture_sha256']
for n in ('dependency-original.json','dependency-corrected.json','construction-owner.json'):
 assert (run/n).is_file()
native=(run/'native-placement.log').read_text()
warnings=[x for x in native.splitlines() if x.startswith('[3]')]
assert len(warnings)==1 and not any(x.startswith('[4]') for x in native.splitlines())
owner=dict(status='FAILED', diagnosis='Runner R_LIBS_USER excluded existing optional async dependencies. All 72 selection calls refused by the unchanged R dependency gate before rebirth_async_ready or native submission.',
 source_count=len(cfg['source_hashes']),installed_count=len(cfg['installed_hashes']),original_file_hashes_verified=len(original),
 source_and_installed_drift=False,attempt_counts=counts,selection_generation_submissions=0,
 construction_captures=24,capture_matrix_values=43008,direction_values=2688,
 construction_evidence_status='PASS independently checked from retained RDS; no capture repeated',
 selection_settings_failed=72,selection_or_final_quality_accepted=False,final_settings_attempted=0,
 native_warnings=warnings,native_errors=0,dependency_installations=0,
 original_driver_status_preserved=True,
 diagnosis_scripts_note='Retained initial model-free inspector failures: qualified/unqualified call comparison, S3 JSON serialization, and assumed service-library path. Actual installed versions and user-library paths independently read; no product, model, bounds, or verifier changes.',
 scope='No generation output or sampled token was produced for selection. Constructor attempts and construction traces are separate executed scopes, not zero total native activity.')
(run/'owner-partial-verification.json').write_text(json.dumps(owner,indent=2)+'\n')
dest.mkdir(exist_ok=False)
for p in run.rglob('*'):
 if p.is_file() and p.suffix not in ('.dylib','.so','.a'):
  q=dest/p.relative_to(run);q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
for name in ['run-evaluation-tokenizer.py','evaluation-status.json','evaluation-tokenizer-launch.json','inspect-evaluation-construction.R','inspect-evaluation-dependency.R','inspect-evaluation-dependency-draft.R','inspect-evaluation-dependency-call-draft.R','inspect-evaluation-dependency-path-draft.R','archive-evaluation-dependency-failure.py']:
 shutil.copy2(base/name,dest/name)
(dest/'local-binary-hashes.json').write_text(json.dumps({str(p):sha(p) for p in run.rglob('*') if p.is_file() and p.suffix in ('.dylib','.so','.a')},indent=2)+'\n')
files={str(p.relative_to(dest)):sha(p) for p in dest.rglob('*') if p.is_file() and p.name!='archive-manifest.json'}
(dest/'archive-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print(json.dumps(dict(archive_files=len(files),manifest_sha256=sha(dest/'archive-manifest.json'),owner=owner)))
