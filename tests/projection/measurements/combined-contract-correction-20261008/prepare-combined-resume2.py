import ast,hashlib,json,shutil,tarfile
from pathlib import Path
root=Path('/private/tmp/relm-f6e');repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');run=root/'combined-binding-resume-20261008-031932';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
st=json.loads((run/'status.json').read_text());m=json.loads((run/'source-manifest.json').read_text())
assert st['status']=='failed' and st['error']=="'base'" and st['stages']==[] and st['source_drift']==[]
assert len(m)==112 and sha(run/'source-manifest.json')=='29835e928e07da28036ae9f14fb55401dc66382913f80b3747a0c40bcbe04935'
for p,h in m.items():assert sha(repo/p)==h,p
with tarfile.open(run/'changed-source.tar.gz') as t:
 members=t.getmembers();assert len(members)==44
 for member in members:assert hashlib.sha256(t.extractfile(member).read()).hexdigest()==m[member.name]
for s in st['carried_stages']:assert sha(run/'carried'/(s['name']+'.log'))==s['log_sha256']
record={'status':'verified_collector_configuration_failure_before_new_execution','sources':112,'tar_members':44,'carried_log_hashes':6,'new_execution_stages':0,'models':0,'cause':'The actual ready fresh_dll_contract is flat; driver incorrectly indexed an absent base field. Correct one lookup, preserve the exact prepared link/build contract.','source_manifest_sha256':sha(run/'source-manifest.json')}
(run/'partial-verification.json').write_text(json.dumps(record,indent=2)+'\n')
arc=repo/'tests/projection/measurements'/run.name;arc.mkdir(exist_ok=True)
for p in run.rglob('*'):
 if p.is_file():
  dest=arc/p.relative_to(run);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
p=root/'verify-combined-resume.py';old=p.read_text();assert old.count("base=ready['fresh_dll_contract']['base']")==1
new=old.replace("base=ready['fresh_dll_contract']['base']", "base=ready['fresh_dll_contract']")
assert new.replace("base=ready['fresh_dll_contract'];", "base=ready['fresh_dll_contract']['base'];")==old
new=new.replace("ROOT/'combined-resume-binding.json'", "ROOT/'combined-resume2-binding.json'")
# Only the binding-file selector and invalid extra dictionary lookup differ.
assert new.replace("ROOT/'combined-resume2-binding.json'", "ROOT/'combined-resume-binding.json'").replace("base=ready['fresh_dll_contract'];", "base=ready['fresh_dll_contract']['base'];")==old
ast.parse(new);(root/'verify-combined-resume2.py').write_text(new)
bind=json.loads((root/'combined-resume-binding.json').read_text());bind['files'].pop(str(p));bind['files'][str(root/'verify-combined-resume2.py')]=sha(root/'verify-combined-resume2.py')
bind['configuration_correction']={'previous_run':str(run),'new_execution':0,'correction':'flat ready fresh_dll_contract, no base field'}
(root/'combined-resume2-binding.json').write_text(json.dumps(bind,indent=2)+'\n')
ready=json.loads((root/'combined-boundary-ready.json').read_text());base=ready['fresh_dll_contract']
required=['static_archive','entrypoint_source','entrypoint_sha256','link_environment','link_command']
assert all(k in base for k in required) and 'base' not in base
assert sha(Path(base['entrypoint_source']))==base['entrypoint_sha256']
assert base['link_command']==['R','CMD','SHLIB','-o','relm.so','entrypoint.c']
assert base['link_environment']['PKG_LIBS'].split()[0]=='-L'+str(Path(base['static_archive']).parent)
assert ready['default_build_command']==['cargo','build','--locked','--offline','-p','rebirth-ffi','--lib']
assert ready['private_build_command']==ready['default_build_command']+['--features','projection-private']
for p,h in {**bind['files'],**bind['r_headers']}.items():assert sha(Path(p))==h,p
# Static check every direct base[...] access in the complete remaining driver.
keys={n.slice.value for n in ast.walk(ast.parse(new)) if isinstance(n,ast.Subscript) and isinstance(n.value,ast.Name) and n.value.id=='base' and isinstance(n.slice,ast.Constant)}
assert keys==set(required),keys
out={'status':'ready','only_changes':['binding-file selector','remove nonexistent nested base key'],'validated_all_five_base_keys':sorted(keys),'entrypoint_and_42_header_hashes_verified':True,'default_and_private_commands_verified':True,'sources':112,'new_native_or_model_execution':0,'driver_sha256':sha(root/'verify-combined-resume2.py'),'binding_sha256':sha(root/'combined-resume2-binding.json')}
(root/'combined-resume2-preflight.json').write_text(json.dumps(out,indent=2)+'\n')
arc2=repo/'tests/projection/measurements/combined-contract-correction-20261008';arc2.mkdir(exist_ok=True)
for name in ['prepare-combined-resume2.py','combined-resume2-preflight.json','combined-resume2-binding.json','verify-combined-resume2.py']:shutil.copyfile(root/name,arc2/name)
print(json.dumps(out,indent=2))
