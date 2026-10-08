from pathlib import Path
import ast,hashlib,json,shutil
r=Path('/private/tmp/relm-f6e');repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
p=(r/'verify-installed-public-docs.py').read_text()
for old,new in {
 "'installed-public-docs-binding.json'":"'installed-public-budget-binding.json'",
 "'installed-public-docs-'":"'installed-public-budget-'",
 "'public-library-corrected'":"'public-library-budget'",
 "new public CPU/Metal operational checks, not behavioral evaluation":"27 remaining public CPU/Metal operational checks with retained four captures, not behavioral evaluation",
 "env['F6E_EXPECT_LIBRARY']=str(lib/'relm')":"env['F6E_EXPECT_LIBRARY']=str(lib/'relm');env['F6E_PUBLIC_PARENT']=bind['parent_directory']",
 "str(ROOT/'check-installed-public.R')":"str(ROOT/'check-installed-public-remaining.R')",
 "len(expected)==37":"expected==bind['expected_cases'] and len(expected)==27",
 "F6E_INSTALLED_PUBLIC cases=37 refusals=6 backend_handles=cpu,metal no_download=TRUE":"F6E_INSTALLED_PUBLIC_REMAINING cases=27 refusals=6 backend_handles=cpu,metal no_download=TRUE carried_parent_cases=10",
 "cases=37,refusals=6":"cases=27,refusals=6,carried_parent_cases=10"
}.items():
 assert old in p,old;p=p.replace(old,new)
start=p.index("  log=stage('documentation-installed'");end=p.index("  installed={",start)
p=p[:start]+'''  # Matching-namespace documentation already passed at the parent source.
  # Neither comments/signatures nor generated docs changed in the OOM correction.
  parent_docs=Path(bind['parent_directory'])
  assert (parent_docs/'documentation-installed.log').read_bytes()==b''
  shutil.copy2(parent_docs/'documentation-installed.log',run/'carried-documentation-installed.log')
  shutil.copy2(parent_docs/'owner-partial-verification.json',run/'carried-installed-owner-verification.json')
  for name,h in bind['carried_files'].items():
   assert sha(parent_docs/name)==h,name
   shutil.copy2(parent_docs/name,run/('carried-'+name))
  assert all(sha(REPO/p)==h for p,h in manifest.items())

'''+p[end:]
# Bind every raw parent input before any execution; preserve original archived scope.
needle="  for path in bind['files']:shutil.copy2(path,run/Path(path).name)"
p=p.replace(needle,"  assert all(sha(Path(bind['parent_directory'])/p)==h for p,h in bind['carried_files'].items())\n"+needle)
(r/'verify-installed-public-budget.py').write_text(p);ast.parse(p)
owner=r/'budget-class-20261008-104809';b=json.loads((owner/'binary-bindings.json').read_text());verification=json.loads((owner/'owner-verification.json').read_text());assert verification['status']=='PASS'
native=Path(b['dll_path']);assert sha(native)==verification['DLL_sha256']==b['dll_sha256']
sm=json.loads((owner/'source-manifest.json').read_text());native_sources={p:h for p,h in sm.items() if p.startswith('rebirth/src/')}
assert all(sha(repo/p)==h for p,h in native_sources.items())
parent=r/'installed-public-docs-20261008-101706'
carried=['public-captures.rds','public-captures.csv','public-direction.rds','original-logits.rds','public-budget.rds','public-cases.csv','public-call-counts.R','owner-partial-verification.json']
expected=['minus_one_refused','project_public_constructed','project_public_logits','duplicate_refused','trace_refused','embed_refused','images_refused','static_sync_seeded_reset','chat_text_route','structured_text_route','async_stream_text_route','live_original_state','live_projected_state','public_same_row_projection','mixed_inheritance','live_reply_applied','live_cancel_before_token','mixed_seeded_restore','original_seeded_reset','child_survives_parent_close','cpu_closed','metal_loaded','metal_public_constructed','metal_zero_identity','metal_active_text_route','metal_original_reset','metal_closed']
model=Path('/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf')
assert sha(model)=='ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e'
files=[r/'verify-installed-public-budget.py',r/'check-installed-public-remaining.R',Path(__file__),owner/'owner-verification.json',owner/'binary-bindings.json']
bind={'files':{str(p):sha(p) for p in files},'native_sources':native_sources,'native':{'path':str(native),'sha256':sha(native)},'model':{'path':str(model),'sha256':sha(model)},'parent_directory':str(parent),'carried_files':{p:sha(parent/p) for p in carried},'expected_cases':expected,'scope':'one fresh affected R install/new DLL, 27 remaining public cases/6 refusals/2 cached loads; old 10 cases and captures carried at their parent source'}
(r/'installed-public-budget-binding.json').write_text(json.dumps(bind,indent=2)+'\n')
out=repo/'tests/projection/measurements/installed-public-budget-preflight-20261008';out.mkdir(exist_ok=False)
for p in [*files,r/'installed-public-budget-binding.json']:
 shutil.copy2(p,out/p.name)
(out/'manifest.json').write_text(json.dumps({p.name:sha(p) for p in sorted(out.iterdir()) if p.is_file()},indent=2)+'\n')
print(json.dumps({'driver':sha(r/'verify-installed-public-budget.py'),'binding':sha(r/'installed-public-budget-binding.json'),'native_sources':len(native_sources),'expected_cases':len(expected),'native_DLL':sha(native),'model_downloads':0}))
