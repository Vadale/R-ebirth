from pathlib import Path
import hashlib,json,re,tarfile,shutil,subprocess,datetime
ROOT=Path('/home/grauk/Documents/Codex/Recupero-Mac-2026-10-13/DOCUDESK/R-ebirth')
BASE=Path('/home/grauk/Work/relm-phase9'); OUT=BASE/'readiness-fixtures'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
binding=json.loads((BASE/'readiness-fixtures-binding.json').read_text());sources=binding['sources']
assert all(sha(ROOT/n)==h for n,h in sources.items())
assert sources==json.loads((OUT/'source-after.json').read_text())
status=json.loads((BASE/'readiness-fixtures-status.json').read_text())
assert status['status']=='awaiting_owner_verification'
for r in status['stages']:assert r['returncode']==0 and sha(OUT/(r['name']+'.log'))==r['log_sha256']
parent=json.loads((BASE/'readiness-build-status.json').read_text());assert parent['status']=='failed'
for r in parent['stages']:assert sha(BASE/'readiness-build'/(r['name']+'.log'))==r['log_sha256']
reuse=json.loads((OUT/'native-reuse.json').read_text());assert reuse==json.loads((OUT/'parent-diagnosis.json').read_text())['native_files']
tarinfo=json.loads((OUT/'source-tar.json').read_text());tarpath=BASE/'readiness-build/relm_0.4.0.tar.gz';assert sha(tarpath)==tarinfo['sha256']
with tarfile.open(tarpath) as tar:actual={m.name:hashlib.sha256(tar.extractfile(m).read()).hexdigest() for m in tar if m.isfile()}
assert actual==tarinfo['files'] and all(len(n.encode())<=100 for n in actual)
assert [n for n,h in actual.items() if sources.get('rebirth/'+n.removeprefix('relm/'))!=h]==['relm/DESCRIPTION']
installed=json.loads((OUT/'installed-hashes.json').read_text());assert installed=={str(p.relative_to(OUT/'library')):sha(p) for p in sorted((OUT/'library').rglob('*')) if p.is_file()}
dll=OUT/'library/relm/libs/relm.so';assert sha(dll)==status['dll_sha256']
for name in ['AUTHORS','RUST-NOTICES','THIRD-PARTY-NOTICES']:assert (OUT/'library/relm'/name).read_bytes()==(ROOT/'rebirth/inst'/name).read_bytes()
log=(OUT/'context-budget.log').read_text()
for n in [2,4]:assert log.count(f'CRAN_CONTEXT_THREADS_OK threads={n} contexts=4 text_fields=8 vision_parameter=1 loads=1 decodes=0')==1
assert log.count('1 passed; 0 failed; 0 ignored')==3
assert 'RAW_RDS_OK functions=250 registered=33 hooks=0 profile=27 loads=0 inference=0' in (OUT/'owner-rds.log').read_text()
commands=json.loads(next((OUT/'native-build').rglob('compile_commands.json')).read_text());assert len(commands)==266
for row in commands:assert all(f not in row['command'] for f in ['-march=native','-mcpu=native','-mavx','-mfma'])
install=(OUT/'install.log').read_text();warnings=[l for l in install.splitlines() if 'warning:' in l];assert len(warnings)==1 and 'stringop-overread' in warnings[0]
assert '* DONE (relm)' in install
elf=(OUT/'elf.log').read_text();assert not any(t in elf for t in ['TEXTREL','libcudart','libcublas'])
owner=dict(status='passed_scoped_with_open_compiler_warning',verified_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),source_files=len(sources),tar=dict(sha256=sha(tarpath),bytes=tarpath.stat().st_size,files=len(actual),exact_repo_files=325,description_fields=19,build_fields=4,vignettes=False,manual=False),installed_files=len(installed),dll_sha256=sha(dll),functions=250,registered=33,hooks=0,profile_fields=27,notices=3,loads=2,decodes=0,installed_inspector_model_calls=0,thread_getters=16,text_contexts=8,vision_parameter_values=2,retained_native_artifacts=len(reuse),native_compile_commands=len(commands),warnings=warnings,limits=['No full as-cran/manual/R-devel/current Windows/macOS acceptance yet.','No actual vision-model execution, process-wide CPU utilization or new inference/numerical/performance acceptance.','307 native artifact hashes/bytes/mtimes prove reuse through the resumed test only. R installation compiled again after effective flag whitespace differed; its native target was normally cleaned, so pre-install archive hashes are not a final DLL archive identity claim.','GCC16 LTO stringop-overread warning in pinned llama-model-loader.cpp:249 remains OPEN. Source has a null guard; false-positive/harmlessness not proven. No suppression/vendor modification.','Original CMake ccache-not-found warning retained; first missing-fixture failure and metadata-whitespace inspector draft remain failed.'],raw_sha256={p.name:sha(p) for p in OUT.iterdir() if p.is_file()})
(OUT/'owner.json').write_text(json.dumps(owner,indent=2)+'\n')
archive=ROOT/'tests/cran/evidence/readiness-20261019';archive.mkdir(exist_ok=False)
def copy(src,rel):
 dst=archive/rel;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst);assert sha(src)==sha(dst)
for folder in ['readiness-build','readiness-fixtures']:
 for p in (BASE/folder).iterdir():
  if p.is_file() and p.suffix in ['.json','.log','.txt','.py','.rds']:copy(p,Path(folder)/p.name)
for p in (OUT/'native-build').rglob('*'):
 if p.is_file():copy(p,Path('readiness-fixtures/native-build')/p.relative_to(OUT/'native-build'))
for name in ['readiness-build-status.json','readiness-build-launch.json','readiness-build-binding.json','readiness-fixtures-status.json','readiness-fixtures-launch.json','readiness-fixtures-binding.json','inspect-readiness.R','inspect-readiness-original.R','verify-readiness.py']:copy(BASE/name,Path('recipes')/name)
changes=subprocess.check_output(['git','diff','--name-only'],cwd=ROOT,text=True).splitlines()
extra=['rebirth/src/rust/rebirth-llm/src/check_resources.rs','tests/cran/installed-readiness.R','tests/cran/native-build.R','tests/cran/test_notices.py','tools/cran-notices.py','rebirth/inst/RUST-NOTICES']
for name in sorted(set(changes+extra)):
 if name in sources:copy(ROOT/name,Path('source')/name)
manifest={str(p.relative_to(archive)):sha(p) for p in sorted(archive.rglob('*')) if p.is_file()}
(archive/'manifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
print(json.dumps(dict(owner_sha256=sha(OUT/'owner.json'),archive=str(archive),files=len(manifest),bytes=sum(p.stat().st_size for p in archive.rglob('*') if p.is_file()),manifest_sha256=sha(archive/'manifest.json')),indent=2))
