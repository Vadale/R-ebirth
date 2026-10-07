from pathlib import Path
import csv,hashlib,json,re,subprocess
root=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); base='989000e67f565121050044e93dc0ae61a143f0db'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git',*args],cwd=root).decode()
assert git('branch','--show-current').strip()=='codex/contrast-directions'
assert not git('diff',base,'--','rebirth/src','rebirth/DESCRIPTION','rebirth/Cargo.lock','rebirth/inst/models.csv')
assert not git('diff','e80166e','--','tests/llm-golden/directions')
namespace=(root/'rebirth/NAMESPACE').read_text(); old=git('show',base+':rebirth/NAMESPACE')
added=set(namespace.splitlines())-set(old.splitlines());assert added=={'export(llm_direction)','export(llm_apply_direction)','S3method(print,relm_direction)'}
assert set(old.splitlines())<=set(namespace.splitlines())
manifest=json.loads((root/'tests/directions/measurements/model-reset-20261007-181846/source-manifest.json').read_text());assert all(sha(root/p)==h for p,h in manifest.items())
# Confirm the archived captured fixture, not an independently generated model golden.
assert sha(root/'rebirth/tests/testthat/fixtures/direction-qwen.rds')==sha(root/'tests/directions/measurements/model-evaluation-20261007-175741/direction.rds')
# Byte identity only; no model/reference/test execution in this final audit.
fixture=root/'rebirth/tests/testthat/fixtures/directions'; oracle=root/'tests/llm-golden/directions/goldens'
mirrored=[p for p in fixture.rglob('*') if p.is_file()]
assert mirrored and all((oracle/p.relative_to(fixture)).is_file() and sha(p)==sha(oracle/p.relative_to(fixture)) for p in mirrored)
docs=['docs/f6d-direction-contract.md','docs/f6d-implementation.md','docs/f6d-evaluation-protocol.md','docs/phase6-visual-steering-plan.md','docs/validation-status.md']
links=[]
for rel in docs:
 p=root/rel
 for target in re.findall(r'\]\(([^)\s]+)\)',p.read_text()):
  if target.startswith(('https:','http:','#','mailto:')):continue
  dest=(p.parent/target.split('#')[0]).resolve();assert dest.exists(),(rel,target);links.append([rel,target])
records={}
for p in sorted((root/'tests/directions/measurements').rglob('*')):
 if p.is_file():
  assert p.suffix not in {'.so','.dylib','.gguf','.RData','.pyc'},p
  assert '__pycache__' not in p.parts,p
  records[str(p.relative_to(root))]={'sha256':sha(p),'bytes':p.stat().st_size}
# Preserve original run status; successful subsets do not turn failures into passes.
expected={'boundaries-20261007-174433':'failed','corrected-boundaries-20261007-175129':'passed','model-evaluation-20261007-175741':'failed','evaluation-resume-20261007-180201':'failed','evaluation-recovery-20261007-180659':'passed','docs-check-20261007-181054':'failed','docs-check-20261007-181311':'passed','model-reset-20261007-181846':'passed'}
for run,status in expected.items():assert json.loads((root/'tests/directions/measurements'/run/'status.json').read_text())['status']==status
out=Path('/private/tmp/relm-f6d/final-audit');out.mkdir(exist_ok=True)
(out/'evidence-manifest.json').write_text(json.dumps(records,indent=2)+'\n')
result={'status':'passed','scope':'Static final source/evidence audit; no accepted numerical/model/runtime tests rerun.','native_dependency_model_inputs_unchanged':True,'independent_goldens_unchanged_since_separate_commit':True,'approved_namespace_additions':sorted(added),'final_runtime_and_model_case_hashes_matched':len(manifest),'mirrored_fixture_files':len(mirrored),'relative_documentation_links_checked':len(links),'archived_files':len(records),'archived_bytes':sum(v['bytes'] for v in records.values()),'retained_run_status':expected,'evidence_manifest_sha256':sha(out/'evidence-manifest.json')}
(out/'verification.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
