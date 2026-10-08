import csv,hashlib,json,re,shutil,tarfile
from pathlib import Path
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');root=Path('/private/tmp/relm-f6e');run=root/'installed-review-resume-20261008-151830';sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
st=json.loads((run/'status.json').read_text());bind=json.loads((run/'owner-binding.json').read_text());source=json.loads((run/'source-manifest.json').read_text());installed=json.loads((run/'installed-manifest.json').read_text());lib=root/'public-library-review/relm'
assert st['status']=='awaiting_owner_verification' and not any(st[k] for k in ['source_drift','installed_drift','dependency_drift','input_drift'])
for p,h in source.items():assert sha(repo/p)==h,p
for p,h in installed.items():assert sha(lib/p)==h,p
for p,h in {**bind['files'],**bind['external_files'],**bind['dependency_files']}.items():assert sha(p)==h,p
with tarfile.open(run/'source.tar.gz') as t:
 members=[m for m in t if m.isfile()]
 for m in members:assert hashlib.sha256(t.extractfile(m).read()).hexdigest()==source[m.name]
rows=list(csv.DictReader((run/'cases.csv').open()));assert [r['case'] for r in rows]==bind['expected_cases'] and all(r['status']=='passed' for r in rows)
row=st['stages'][0];assert len(st['stages'])==1 and row['status']=='passed' and row['exit_code']==0 and sha(run/'installed-affected.log')==row['log_sha256']
log=(run/'installed-affected.log').read_text();assert re.findall(r'^F6E_INSTALLED_REVIEW_CASE (\S+)$',log,re.M)==bind['expected_cases'];assert not re.search(r'^(Warning|Error|warning:|error:)',log,re.M)
assert log.count('F6E_INSTALLED_REVIEW_COMPLETE cases=10 coordinates=1792 load_attempts=1 derive_attempts=13 generation_attempts=3')==1
raw=(run/'native-placement.log').read_text();warning="[3] load: control-looking token: 128247 '</s>' was not control-type; this is probably a bug in the model. its type will be overridden"
assert [l for l in raw.splitlines() if l.startswith('[3]')]==[warning] and not re.search(r'^\[4\]',raw,re.M)
assert 'offloaded 0/25 layers to GPU' in raw
assert all(re.search('CPU[^\n]*'+kind+' buffer size',raw) for kind in ['model','KV','compute'])
obs=json.loads((run/'owner-observation-verification.json').read_text());assert obs['status']=='passed' and obs['bitwise_coordinate_pairs']==1792 and obs['registry_profiles']==13 and obs['model_calls_during_verification']==0
native=json.loads(Path(bind['native_owner']['path']).read_text());assert native['status']=='passed' and sha(lib/'libs/relm.so')==native['dll_sha256']==bind['native']['sha256']
receipt=json.loads((run/'receipt.json').read_text());assert receipt['actual_gc_calls']==11 and receipt['gc_finalized_open_candidates']==4 and receipt['max_simultaneous_derived']==3
assert (run/'runtime-preflight-carried.log').read_text()=='F6E_INSTALLED_REVIEW_RUNTIME dependencies=2 usage=ok\n'
report={'status':'passed','source_hashes':len(source),'source_archive_members':len(members),'installed_hashes':len(installed),'dependency_hashes':len(bind['dependency_files']),'exact_named_cases':10,'bitwise_coordinate_pairs':1792,'registry_profiles':13,'actual_gc_calls':11,'open_candidates_finalized_by_gc':4,'max_simultaneous_derived':3,'attempts':receipt['attempts'],'dll_sha256':native['dll_sha256'],'CPU_offload_layers':'0/25','known_tokenizer_warning':1,'new_R_native_errors_warnings':0,'source_body_formals':'Carried fresh-install loop completed before parent metadata failure; previous259-function source contract unchanged','codetools':'New runtime preflight silent after existing namespaces loaded','scope':'Installed review corrections only. Timing fields are finite but differ, and are retained rather than used as an identity requirement. No efficacy/timing/independent-golden claim.','model_calls_during_owner_verification':0,'original_driver_status':'awaiting_owner_verification'}
(run/'owner-verification.json').write_text(json.dumps(report,indent=2)+'\n')
for p in [Path(__file__),root/'verify-installed-review-observations.R',root/'verify-installed-review-observations.parse-draft.R',root/'verify-installed-review-observations.elapsed-draft.R']:shutil.copy2(p,run/p.name)
(run/'owner-inspector-notes.txt').write_text('Two owner-only drafts are retained: a missing closing parenthesis prevented parsing; an overly broad step equality also compared elapsed times. Actual step payload differs only in elapsed time, which is not part of zero-projection numerical/token identity. All other step fields, retained vectors, sampled token events and text match. Corrections use saved RDS only; no model replay.\n')
dest=repo/'tests/projection/measurements'/run.name;shutil.copytree(run,dest)
manifest={str(p.relative_to(dest)):sha(p) for p in dest.rglob('*') if p.is_file()};(dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'archive':str(dest),'manifest_sha256':sha(dest/'manifest.json'),**report},indent=2))
