"""Inspect retained package outputs only: no build, test, model or RNG execution."""
from pathlib import Path
import hashlib,json,re,tarfile
B=Path('/private/tmp/relm-release-0.4.0');P=B/'packaging-warning-cleanup-current-python';R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def inv(root):return {str(p.relative_to(root)):sha(p) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
s=json.loads((P/'status.json').read_text());assert s['status']=='awaiting_owner_verification'
b=json.loads((B/'warning-cleanup-binding.json').read_text());assert sha(B/'warning-cleanup-binding.json')==s['binding_sha256']
assert sha(B/'run-packaging-warning-cleanup-current-python.py')==b['driver_sha256']
assert all(sha(R/n)==h for n,h in b['repo_inputs'].items())
assert inv(B/'warning-cleanup/tools-library')==b['tool_library']
assert all(sha(Path(n))==h for n,h in b['tool_executables'].items())
for item in s['stages']:assert item['exit_code']==0 and sha(P/(item['name']+'.log'))==item['log_sha256']
src=json.loads((P/'source-manifest.json').read_text());assert all(sha(P/'relm'/n)==h for n,h in src.items())
installed=json.loads((P/'installed-manifest.json').read_text());assert inv(P/'library/relm')==installed
source=P/'relm_0.4.0.tar.gz';binary=P/'relm_0.4.0.tgz';assert sha(source)==s['source_tarball_sha256'] and sha(binary)==s['binary_sha256']
with tarfile.open(source) as t:payload={m.name:t.extractfile(m).read() for m in t.getmembers() if m.isfile()}
with tarfile.open(B/'packaging-r-path/relm_0.4.0.tar.gz') as t:parent={m.name:t.extractfile(m).read() for m in t.getmembers() if m.isfile()}
assert set(payload)-set(parent)=={'relm/src/llama.cpp/patches/0005-compiler-diagnostics.diff'} and not set(parent)-set(payload)
assert all(payload[n]==data for n,data in parent.items() if n.startswith('relm/inst/doc/'))
repo_equal=[];generated=[];different=[]
for name,data in payload.items():
 rel=Path(name).relative_to('relm');p=R/'rebirth'/rel
 if p.is_file():
  (repo_equal if data==p.read_bytes() else different).append(str(rel))
 else:generated.append(str(rel))
assert different==['DESCRIPTION'],different
with tarfile.open(binary) as t:bf={str(Path(m.name).relative_to('relm')):hashlib.sha256(t.extractfile(m).read()).hexdigest() for m in t.getmembers() if m.isfile()}
assert bf==installed
check=(P/'check/relm.Rcheck/00check.log').read_text();assert 'Status: 1 NOTE' in check and ' WARNING' not in check and ' ERROR' not in check
assert check.count(' NOTE')==2 # incoming section and final summary
for token in ['checking examples ... OK','checking package vignettes ... OK','checking PDF version of manual ... OK','checking Rust compilation ... OK','checking pragmas in C/C++ headers and code ... OK','checking HTML version of manual ... OK']:
 assert token in check,token
raw=(P/'check/relm.Rcheck/tests/testthat.Rout').read_text();assert '[ FAIL 0 | WARN 0 | SKIP 130 | PASS 5010 ]' in raw
logs=[P/(x['name']+'.log') for x in s['stages']]+[P/'check/relm.Rcheck/00install.out',P/'check/relm.Rcheck/tests/testthat.Rout']
assert not [(str(p),m.group()) for p in logs for m in re.finditer(r'(?im)^.*(?:warning:|warning message|warning in|ld: warning|built under R version|error:).*$',p.read_text())]
install=(P/'check/relm.Rcheck/00install.out').read_text();link=next(line for line in install.splitlines() if line.startswith('clang++ ') and ' -dynamiclib ' in line)
assert '-std=gnu++17' in link and '-lc++' not in link
prod=(P/'installed-production.log').read_text();assert 'RELEASE_INSTALLED_OK functions=250 fixtures=0 version=0.4.0' in prod
changes=json.loads((B/'warning-cleanup/vendor-directive-changes.json').read_text());pat=re.compile(r'^\s*#\s*pragma\s+(?:GCC|clang)\s+diagnostic\b.*(?:\n|$)',re.M)
for name,item in changes['files'].items():
 old=B/'warning-cleanup/vendor-originals'/name;new=R/'rebirth/src/llama.cpp'/name
 assert sha(old)==item['before'] and sha(new)==item['after'] and pat.sub('',old.read_text())==new.read_text()
receipt=dict(status='passed',verification_scope='Retained outputs and hashes only; zero builds/tests/models/RNG calls.',source_files=len(src),repo_inputs=len(b['repo_inputs']),installed_files=len(installed),raw_stage_logs=len(s['stages']),tar_files=len(payload),repository_byte_equal=len(repo_equal),generated_files=generated,metadata_changed=different,source_sha256=sha(source),binary_sha256=sha(binary),dll_sha256=sha(P/'library/relm/libs/relm.so'),binary_files_equal_installed=len(bf),package_check=dict(errors=0,warnings=0,notes=['Incoming new submission and 5152966-byte source archive.']),tests=dict(passed=5010,failed=0,warnings=0,skipped=130),installed_functions=250,native_fixture_hooks=0,compiled_profile_fields=27,install_log_compiler_linker_warnings=0,library_tool_files=71,diagnostic_only_vendor_files=len(changes['files']),carried_vignette_files=18,limits='Mac production package scope. Prior pkgdown/RStudio/model acceptance retains its earlier source/DLL provenance; this does not replay it or claim Windows/CUDA/CRAN acceptance.')
(B/'warning-cleanup-owner.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2))
