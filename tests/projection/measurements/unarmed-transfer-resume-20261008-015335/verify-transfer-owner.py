from pathlib import Path
import csv,hashlib,json,re,tarfile,subprocess,shutil
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');run=Path('/private/tmp/relm-f6e/unarmed-transfer-resume-20261008-015335')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
st=json.loads((run/'status.json').read_text());manifest=json.loads((run/'source-manifest.json').read_text());binding=json.loads((run/'owner-binding.json').read_text());ready=json.loads((run/'ready.json').read_text())
assert st['status']=='awaiting_owner_verification' and st['models']==0 and st['production_armed'] is False and st['source_drift']==[]
assert len(manifest)==107 and sha(run/'source-manifest.json')==st['source_manifest_sha256']
assert all(sha(repo/p)==h for p,h in manifest.items())
for p,h in {**binding['files'],**binding['r_headers']}.items():assert sha(Path(p))==h,p
assert len(binding['r_headers'])==42
with tarfile.open(run/'changed-source.tar.gz') as t:
 members=[m for m in t.getmembers() if m.isfile()]
 for m in members:assert hashlib.sha256(t.extractfile(m).read()).hexdigest()==manifest[m.name]
assert len(members)==36
for stage in st['stages']:
 assert stage['status']=='passed' and stage['exit_code']==0
 log=run/(stage['name']+'.log');assert sha(log)==stage['log_sha256']
 assert not re.search(r'^warning(?:\[|:)|^Error|^error:',log.read_text(),re.M)
assert len(st['stages'])==9 and st['compiler_warnings']==st['link_warnings']==[]
expected=[('projection_transfer_residual_shapes_and_values',17,14),('projection_transfer_residual_exact_capacities',5,4),('projection_transfer_requires_cached_residual_capabilities',14,6),('projection_transfer_source_registry_and_payload',14,10),('projection_transfer_borrowed_residual_inputs',12,9),('projection_transfer_r_state_facts',16,12)]
raw=[]
for n in range(1,4):
 text=(run/f'native-{n:02}.log').read_text()
 assert re.search(r'test result: ok\. 1 passed; 0 failed; 0 ignored; 0 measured;',text)
 assert ready['tests'][n-1]['id'] in text
 rows=re.findall(r'F6E_PROJECTION_TRANSFER_TEST (\{[^\n]*\})',text);assert len(rows)==1
 raw.append(json.loads(rows[0]))
hosted=(run/'ffi-r-hosted.log').read_text()
raw.extend(json.loads(s) for s in re.findall(r'F6E_PROJECTION_TRANSFER_TEST (\{[^\n]*\})',hosted))
assert len(raw)==6
for row,(name,n,bad) in zip(raw,expected):assert row==dict(test=name,status='passed',expected_cases=n,executed_cases=n,expected_rejections=bad,rejected_cases=bad)
assert raw==json.loads((run/'native-test-receipts.json').read_text())
assert sum(x['executed_cases'] for x in raw)==78 and sum(x['rejected_cases'] for x in raw)==55
assert hosted.count('F6E_TRANSFER_R_HOSTED_SUCCESS outcomes=3 cases=42 rejections=31 models=0')==1
assert hosted.count('F6E_TRANSFER_R_BINDING states=2 candidate_queries=2 close_checks=2 models=0 armed=FALSE')==1
facts=[json.loads(s) for s in re.findall(r'F6E_PROJECTION_STATE_FACTS (\{[^\n]*\})',hosted)]
for row,name,slots in zip(facts,['compiled_scalar','unhashed','hashed'],[0,0,29]):assert row==dict(fixture=name,hash_slots=slots,bindings=2,c_finalizer_bytes=8,query_workspace_bytes=264,ffi_response_bytes=1464)
assert len(facts)==3 and facts==json.loads((run/'state-facts.json').read_text())
with (run/'r-state-binding.csv').open() as f:rr=list(csv.DictReader(f))
assert len(rr)==2
for row,slots,extra,fixed in zip(rr,[0,29],[992,1272],[30328,30608]):
 assert int(row['hash_slots'])==slots and int(row['state_extra_bytes'])==extra
 assert int(row['r_projection_fixed_bytes'])==fixed and int(row['r_adapter_bytes'])==864
 assert row['query_roundtrip']==row['close_state']=='TRUE' and row['models']=='0'
with (run/'actual-profile.csv').open() as f:profile={r['field']:int(r['value']) for r in csv.DictReader(f)}
assert len(profile)==26 and profile['ffi_response_bytes']==1464 and profile['ffi_registry_bytes']==160 and profile['ffi_fixed_bytes']==1784
assert st['profile_changes']=={'ffi_fixed_bytes':{'before':1720,'after':1784},'ffi_registry_bytes':{'before':96,'after':160}}
# The exact compiled registry term is (old capacity + replacement capacity)*8
# plus its 24-byte Vec descriptor. New fixtures increase retained registry capacity.
assert (2*4+1)*8+24==96 and (2*8+1)*8+24==160
assert 1784-160==1720-96 and facts[0]['query_workspace_bytes']<profile['ffi_response_bytes']
c=json.loads((run/'r-accessor-build-binding.json').read_text());b=json.loads((run/'fresh-ffi-binding.json').read_text());cargo=json.loads((run/'cargo-static-artifact.json').read_text())
assert len(b['static_archives'])==9 and not b['old_library_reused']
for p,h in {**b['static_archives'],**c['files']}.items():assert sha(Path(p))==h,p
assert sha(Path(b['dll_path']))==b['dll_sha256'] and Path(b['dll_path']).stat().st_size==b['dll_bytes']
assert sha(run/'ffi-hosted/entrypoint.c')==b['entrypoint_sha256']==sha(repo/'rebirth/src/entrypoint.c')
lib=repo/'rebirth/src/rust/target/debug/librelm.a';assert str(lib) in cargo['filenames'] and cargo['target']['crate_types']==['rlib','staticlib']
assert 'static=relm-r-state' in c['cargo_record']['linked_libs']
object_path=Path(c['cargo_record']['out_dir'])/'projection_state.o'
for archive in [lib,object_path.parent/'librelm-r-state.a']:
 names=subprocess.check_output(['ar','t',str(archive)],text=True).splitlines();assert names.count('projection_state.o')==1
 assert hashlib.sha256(subprocess.check_output(['ar','p',str(archive),'projection_state.o'])).hexdigest()==sha(object_path)
report={'status':'passed','source_manifest_sha256':st['source_manifest_sha256'],'source_count':107,'source_archive_members':36,'R_headers':42,'stage_logs':9,'native_outcomes':6,'cases':78,'refusals':55,'state_facts':facts,'R_closed_fixture_bindings':2,'models':0,'production_armed':False,'compiler_warnings':0,'link_warnings':0,'dll_sha256':b['dll_sha256'],'C_object_sha256':sha(object_path),'C_object_bytes_bound_to_both_archives':True,'profile_delta_diagnosis':'Only dynamic registry96->160 and containing ffi_fixed1720->1784 differ. Compiled equation binds capacity4->8; the new selftest registers more empty handles. Query264 remains below unchanged1464 response workspace; no layout/formula change or hidden reserve. Actual constructor admission and dynamic source/registry revalidation remain pending.','scope':'Unarmed helpers and R closed-empty-handle binding only; not loaded model or public memory acceptance'}
(run/'owner-verification.json').write_text(json.dumps(report,indent=2)+'\n')
a=repo/'tests/projection/measurements'/run.name;a.mkdir(exist_ok=True)
for p in run.iterdir():
 if p.is_file():shutil.copyfile(p,a/p.name)
shutil.copyfile(__file__,a/Path(__file__).name)
shutil.copyfile(Path(__file__).with_name('verify-transfer-owner-initial.py'),a/'verify-transfer-owner-initial.py')
(a/'collector-correction.txt').write_text('Initial owner verifier expected staticlib as the sole Cargo crate type. Actual Cargo.toml/output declare rlib and staticlib; exact both-kind check and archive filename binding correct this collector assumption. Native work was not rerun.\n')
files={p.name:{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(a.iterdir()) if p.is_file()}
(a/'file-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
print(json.dumps(report))
