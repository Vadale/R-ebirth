import csv,hashlib,json,re,shutil,subprocess,tarfile
from pathlib import Path
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');P=Path('/private/tmp/relm-f6e/review-fix-counter-20261008-150046');sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
s=json.loads((P/'status.json').read_text());b=json.loads((P/'owner-binding.json').read_text());m=json.loads((P/'source-manifest.json').read_text())
assert s['status']=='awaiting_owner_verification' and s['source_drift']==[] and len(m)==194
assert sha(P/'source-manifest.json')==s['source_manifest_sha256'];assert sha(P/'owner-binding.json')=='a101e5169b16a31006b81ac1a5d0ec7d2a812b6148994732246a8f86fe5ca9aa'
for p,h in m.items():assert sha(R/p)==h,p
for p,h in {**b['files'],**b['r_headers']}.items():assert sha(Path(p))==h,p
assert len(b['r_headers'])==42
with tarfile.open(P/'changed-source.tar.gz') as t:
 members=t.getmembers()
 for member in members:assert member.isfile() and hashlib.sha256(t.extractfile(member).read()).hexdigest()==m[member.name],member.name
stages=['format','clippy-default','clippy-private','native-1','native-2','default-static-build','default-fresh-link','compiled-profile'];assert [r['name'] for r in s['stages']]==stages
for row in s['stages']:
 p=P/(row['name']+'.log');assert row['exit_code']==0 and row['status']=='passed' and sha(p)==row['log_sha256']
 assert not re.search(r'^(?:warning(?:\[|:)|ld: warning:|Warning|Error|error(?:\[|:))',p.read_text(),re.M)
records=[]
for i,t in enumerate(b['tests'],1):
 raw=(P/f'native-{i}.log').read_text();assert re.findall(r'^test ([^ ]+) \.\.\. ',raw,re.M)==[t['id']]
 assert re.findall(r'^running (\d+) tests?$',raw,re.M)==['1']
 assert re.findall(r'^test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured;',raw,re.M)==[('1','0','0','0')]
 markers=re.findall(r'F6E_PROJECTION_REVIEW_TEST (\{[^\n]*\})',raw);assert len(markers)==1
 result=json.loads(markers[0]);expected=t['expected_marker'];assert result.keys()==expected.keys()
 for k,v in expected.items():assert type(result[k]) is type(v) and result[k]==v,k
 assert '--features' not in s['stages'][i+2]['command'];records.append(result)
assert records==json.loads((P/'native-receipts.json').read_text())==s['native_receipts']
assert tuple(sum(r[k] for r in records) for k in ['executed_cases','rejected_cases','compared_values'])==(86,7,224)
assert all(records[0][k]==0 for k in ['zero_rows','zero_read_bytes','zero_write_bytes','zero_barriers','refused_deliveries'])
assert records[1]['actual_r_gc_executed'] is False
parent=Path(b['parent_run']);pm=json.loads((parent/'source-manifest.json').read_text());assert [p for p,h in pm.items() if m[p]!=h]==['rebirth/src/rust/rebirth-llm/src/projection_review_tests.rs']
carry=json.loads((P/'carried-no-spill.json').read_text());assert len(carry['stages'])==2
for r in carry['stages']:assert r['exit_code']==0 and sha(P/('carried-'+r['name']+'.log'))==sha(parent/(r['name']+'.log'))==r['log_sha256']
profile={r['field']:int(r['value']) for r in csv.DictReader((P/'compiled-profile.csv').open())};assert len(profile)==27
old=json.loads(Path('/private/tmp/relm-f6e/production-activation-20261008-041846/default-registration-receipt.json').read_text())['profile'];assert profile==old
assert profile['ffi_registry_bytes']==32 and profile['ffi_fixed_bytes']==profile['ffi_response_bytes']+profile['ffi_registry_bytes']+160==1704
assert (P/'compiled-profile.log').read_text().strip()=='F6E_REVIEW_FIX_PROFILE fields=27 models=0 inference=0 fixed_profile_preserved=1'
x=json.loads((P/'binary-bindings.json').read_text());assert x['mode']=='default' and x['artifact']['features']==['default','spill'] and x['artifact']['profile']['test'] is False and x['artifact']['fresh'] is False
cargo=[json.loads(line) for line in (P/'default-static-build.log').read_text().splitlines() if line.startswith('{')]
assert [r for r in cargo if r.get('reason')=='compiler-artifact' and r['target']['name']=='relm']==[x['artifact']]
assert [r for r in cargo if r.get('reason')=='build-script-executed' and 'rebirth-ffi' in r.get('package_id','')]==[x['cargo_build']]
for r in cargo:
 if r.get('reason')=='compiler-message':assert r['message']['level']!='warning'
assert len(x['static_archives'])==9
for path,h in {**x['static_archives'],**x['C_files']}.items():
 assert sha(Path(path))==h
 if path in x['local_copies']:assert sha(Path(x['local_copies'][path]['path']))==h
copies={Path(k).name:Path(v['path']) for k,v in x['local_copies'].items()}
for name in ['librelm.a','librelm-r-state.a']:
 assert subprocess.check_output(['ar','t',str(copies[name])],text=True).splitlines().count('projection_state.o')==1
 assert hashlib.sha256(subprocess.check_output(['ar','p',str(copies[name]),'projection_state.o'])).hexdigest()==sha(copies['projection_state.o'])
link=(P/'default-fresh-link.log').read_text();assert '-lrelm -lrelm-grammar -lmtmd -lvendor-hash -lllama -lggml -lggml-cpu -lggml-metal -lggml-base' in link
assert sha(P/'default-ffi/entrypoint.c')==sha(R/'rebirth/src/entrypoint.c')==x['entrypoint_sha256']
assert sha(Path(x['dll_path']))==x['dll_sha256']=='e3182fb2260256afb95d15a6c7019b6285a251ff6a045fe7150b07a872e9f07d'
report={'status':'passed','source_manifest_sha256':s['source_manifest_sha256'],'source_count':len(m),'source_archive_members':len(members),'stage_logs':8,'carried_no_spill_logs':2,'R_headers':42,'native_outcomes':2,'cases':86,'refusals':7,'compared_values':224,'value_scope':'Exact live/logit/audit identity, not independent golden accuracy','model_loads_reported':1,'constructor_calls_reported':1,'probe_decodes_reported':2,'actual_r_gc_executed':False,'compiled_profile':profile,'profile_numeric_matches_prior_default':True,'compiler_linker_warnings':0,'default_features':x['artifact']['features'],'C_bytes_bound_to_own_and_bundled_archive':True,'linked_archives':9,'dll_sha256':x['dll_sha256'],'driver_status_preserved':s['status'],'scope':'Local review corrections and fresh default DLL/profile only; affected installed and Linux execution still pending; no model/native replay during owner verification'}
(P/'owner-verification.json').write_text(json.dumps(report,indent=2)+'\n')
A=R/'tests/projection/measurements'/P.name;assert not A.exists();A.mkdir();local={}
for p in P.rglob('*'):
 if not p.is_file():continue
 relative=p.relative_to(P)
 if 'default-ffi' in relative.parts and p.name!='entrypoint.c':local[str(relative)]={'bytes':p.stat().st_size,'sha256':sha(p)};continue
 dest=A/relative;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
(A/'local-only-binaries.json').write_text(json.dumps(local,indent=2)+'\n');shutil.copy2(__file__,A/Path(__file__).name)
(A/'manifest.json').write_text(json.dumps({str(p.relative_to(A)):sha(p) for p in A.rglob('*') if p.is_file()},indent=2)+'\n')
print(json.dumps({'status':report['status'],'cases':86,'refusals':7,'values':224,'source_hashes':len(m),'tar_members':len(members),'manifest_sha256':sha(A/'manifest.json'),'dll_sha256':x['dll_sha256']}))
