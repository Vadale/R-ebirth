from pathlib import Path
import ast,hashlib,json
r=Path('/private/tmp/relm-f6e');p=(r/'verify-production.py').read_text()
changes={
 "ROOT/'production-collector.py'":"ROOT/'budget-class-collector.py'",
 "ROOT/'production-ready.json'":"ROOT/'budget-class-ready.json'",
 "ROOT/'production-binding.json'":"ROOT/'budget-class-binding.json'",
 "ready['status']=='ready' and ready['frozen'] and ready['production_native_armed']":"ready['status']=='ready' and ready['frozen']",
 "{**ready['source_hashes'],**ready['preserved_source_hashes'],**ready['untouched_build_C_classifier_hashes'],**bind['repo_sources']}":"{**ready['source_hashes'],**bind['repo_sources']}",
 "'production-activation-'":"'budget-class-'",
 "'model_loads_planned':2":"'model_loads_planned':0",
 "'scope':'default native activation/new worker and fresh default DLL; not installed public R/text/evaluation acceptance'":"'scope':'affected model-free OOM class/R transport/native twin and fresh default DLL only; installed continuation is separate'",
 "'production-status.tmp'":"'budget-class-status.tmp'",
 "'production-status.json'":"'budget-class-status.json'",
 "|set(ready['preserved_source_hashes'])|set(ready['untouched_build_C_classifier_hashes'])":"",
 "shutil.copy2(ROOT/'production-binding.json',run/'owner-binding.json')":"shutil.copy2(ROOT/'budget-class-binding.json',run/'owner-binding.json')",
 "  cmds=[":"  rlog=stage('r-source',['Rscript','--vanilla',str(ROOT/'check-budget-class-source.R')],cwd=REPO,extra={'F6E_BUDGET_RUN':str(run)},timeout=120)\n  assert rlog.count('F6E_BUDGET_R_SOURCE cases=1 expectations=12 failures=0 errors=0 skips=0 warnings=0')==1\n  cmds=[",
 "for idx,test in enumerate(ready['tests'],1):":"for idx,test in enumerate([ready['native_test']],1):",
 " and test['private_feature'] is False":"",
 "base=ready['fresh_default_dll_contract'];log=stage('default-static-build',ready['default_build_command']+['--message-format=json'])":"base=bind['fresh_default_dll_contract'];log=stage('default-static-build',bind['default_build_command']+['--message-format=json'])",
 "str(ROOT/'check-production-default.R'),str(dll)":"str(ROOT/'check-budget-class-hosted.R'),str(dll),str(run)",
 "outcomes=3,cases=27,refusals=13,compared_values=291,model_loads_reported=2,constructor_calls_reported=3,independent_numerical_oracle=False":"outcomes=2,cases=19,refusals=10,r_source_cases=1,r_source_expectations=12,native_R_terms=14,model_loads_reported=0,inference_calls_reported=0,independent_numerical_oracle=False"
}
# One replacement is subsumed by the path-key replacement above.
changes.pop("shutil.copy2(ROOT/'production-binding.json',run/'owner-binding.json')")
for old,new in changes.items():
 assert old in p,old
 p=p.replace(old,new)
# Retain exact observed term/transport files before owner inspection.
needle="  assert all(sha(Path(p))==h for p,h in archives.items())"
insert="""  import csv
  terms=list(csv.DictReader((run/'budget-terms.csv').open()))
  assert len(terms)==14 and len({row['field'] for row in terms})==14
  assert all(float(row['native'])==float(row['R']) for row in terms)
  errors=list(csv.DictReader((run/'budget-errors.csv').open()))
  assert [row['payload'] for row in errors]==['oom','malformed','overflow']
  assert all(0<float(row['actual'])<=float(row['charged']) for row in errors)
  profile={row['field']:int(row['value']) for row in csv.DictReader((run/'budget-profile.csv').open())}
  assert len(profile)==27 and profile['derive_frame_bytes']==11959 and profile['ffi_command_bytes']==744
  assert profile['runtime_bytes']==5072 and profile['ffi_response_bytes']==1512 and profile['error_format_bytes']==150
  assert profile['ffi_registry_bytes']>=32 and (profile['ffi_registry_bytes']-32)%16==0
  assert profile['ffi_fixed_bytes']==profile['ffi_response_bytes']+profile['ffi_registry_bytes']+160
"""
assert needle in p;p=p.replace(needle,insert+needle)
(r/'verify-budget-class.py').write_text(p);ast.parse(p)
print('Prepared affected driver with six literal build/source stages, one new exact native loop, one current static build/link and one new R-hosted gate. No models or installs.')
