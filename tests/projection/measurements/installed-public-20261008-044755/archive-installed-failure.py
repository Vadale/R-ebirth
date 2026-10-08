from pathlib import Path
import hashlib,json,shutil,tarfile
r=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');base=Path('/private/tmp/relm-f6e');p=base/'installed-public-20261008-044755';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();s=json.loads((p/'status.json').read_text());m=json.loads((p/'source-manifest.json').read_text());i=json.loads((p/'installed-manifest.json').read_text());lib=base/'public-library/relm'
assert s['status']=='failed' and s['stage']=='public-model'
assert all(sha(r/x)==h for x,h in m.items());assert all(sha(lib/x)==h for x,h in i.items())
assert all(sha(p/(x['name']+'.log'))==x['log_sha256'] for x in s['stages'])
with tarfile.open(p/'R-source.tar.gz') as t:
 members=t.getmembers()
 for x in members:
  assert hashlib.sha256(t.extractfile(x).read()).hexdigest()==m[x.name]
assert (p/'public-model.log').read_text()=="Error in main() : object 'llm_apply_direction' not found\nCalls: main -> check -> isTRUE -> formals\nExecution halted\n"
assert not (p/'public-call-counts.R').exists() and not (p/'public-cases.csv').exists()
assert 'F6E_INSTALLED_SOURCE_FORMALS_BODIES_MATCH functions=259' in (p/'installed-source-usage.log').read_text()
assert sha(lib/'libs/relm.so')==s['native']['sha256']
d={'status':'verified_failure','source_files':len(m),'installed_files':len(i),'tar_members':len(members),'log_hashes':len(s['stages']),'source_manifest_sha256':sha(p/'source-manifest.json'),'model_loads':0,'public_cases':0,'cause':'roxygen load_installed resolved an older namespace, removing approved exports/S3 registrations and eight help topics; code bodies were installed but the public function was unavailable. Documentation exit zero was not correctness.','carried':'Wrapper generation and exact DLL/source function parity are valid at their source scope. Regenerate docs from current source and reinstall affected R package; no native rebuild or wrapper rerun.','warnings':'Documentation emitted unresolved links/missing names and deleted approved help; these are the diagnosed failure, not suppressed warnings.'}
(p/'owner-failure-verification.json').write_text(json.dumps(d,indent=2)+'\n')
out=r/'tests/projection/measurements'/p.name;out.mkdir(exist_ok=False)
for x in p.iterdir():
 if x.is_file():shutil.copy2(x,out/x.name)
shutil.copy2(__file__,out/Path(__file__).name)
print(json.dumps(d))
