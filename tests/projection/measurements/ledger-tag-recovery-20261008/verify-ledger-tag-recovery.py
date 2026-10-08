from pathlib import Path
import ast, copy, csv, hashlib, importlib.util, json, re, shutil

root=Path('/private/tmp/relm-f6e')
run=root/'public-ledger-resume-20261008-010121'
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
out=root/'ledger-tag-recovery-20261008'
out.mkdir(exist_ok=True)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def functions(p):
 return {n.name:ast.dump(n,include_attributes=False) for n in ast.parse(p.read_text()).body if isinstance(n,ast.FunctionDef)}
old=functions(run/'ledger-collector.py'); new=functions(root/'ledger-collector.py')
assert set(old)==set(new)
assert [k for k in old if old[k]!=new[k]]==['verify_tag']
spec=importlib.util.spec_from_file_location('collector',root/'ledger-collector.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
tag=json.loads((run/'native-r-tag.json').read_text())
profile=json.loads((run/'native-profile.json').read_text())
assert c.verify_tag(tag,profile)==tag
refusals=0
for key in ['tag_utf8_bytes','pointer_pair_bytes','tag_pair_bytes','combined_bytes','empty_pair_bytes','empty_quad_bytes','charged_tag_bytes']:
 for change in [-1,1]:
  bad=copy.deepcopy(tag);bad[key]+=change
  try:c.verify_tag(bad,profile)
  except AssertionError:refusals+=1
  else:raise AssertionError(key)
for key in ['externalptr_bytes','tag_bytes']:
 for index in range(2):
  for change in [-1,1]:
   bad=copy.deepcopy(tag);bad[key][index]+=change
   try:c.verify_tag(bad,profile)
   except AssertionError:refusals+=1
   else:raise AssertionError((key,index))
for key,value in [('model_count',1),('protected_is_null',False),('shared_character_payload',False),('tag_length',2),('externalptr_bytes',[64,64])]:
 bad=copy.deepcopy(tag);bad[key]=value
 try:c.verify_tag(bad,profile)
 except AssertionError:refusals+=1
 else:raise AssertionError(key)
assert refusals==27
log=(run/'r-native-twins.log').read_text()
marker='F6E_LEDGER_R_TWIN cases=12 compared_terms=156 exact_budgets=12 rejected_budget_minus_one=12 differences=0 models=0'
assert log.strip()==marker,log
rows=list(csv.DictReader((run/'r-native-parity.csv').open()))
assert len(rows)==156 and len({x['case'] for x in rows})==12
assert all(float(x['native'])==float(x['R']) and float(x['difference'])==0 for x in rows)
source=json.loads((run/'source-manifest.json').read_text())
assert all(sha(repo/p)==h for p,h in source.items())
partial=json.loads((run/'owner-native-verification.json').read_text())
assert partial['native_outcomes']==7 and partial['native_cases']==95 and partial['native_rejections']==40
for name in ['ledger-collector.py','check-ledger-twins.R','verify-ledger-tag-recovery.py','verify-ledger-native-owner.py']:
 shutil.copy2(root/name,out/name)
for name in ['native-r-tag.json','native-profile.json','native-twins.csv','r-native-twins.log','r-native-parity.csv','r-allocation-prototype.rds','owner-native-verification.json']:
 shutil.copy2(run/name,out/name)
result={'status':'verified','original_attempt_status':'failed_collector','original_native_run':str(run),
 'libtest_outcomes':6,'R_hosted_outcomes':1,'native_cases':95,'native_rejections':40,
 'new_collector_controls':28,'negative_controls':27,'unchanged_parser_functions':len(old)-1,
 'R_twin_cases':12,'R_terms':156,'exact_budgets':12,'budget_minus_one_refusals':12,
 'source_hashes_verified':len(source),'source_manifest_sha256':sha(run/'source-manifest.json'),
 'new_native_runs':0,'new_model_runs':0,'R_twin_log_sha256':sha(run/'r-native-twins.log'),
 'tag_collector_sha256':sha(root/'ledger-collector.py'),
 'scope':'Compiled admission arithmetic and boundary/tag prototypes; full public constructor ownership remains pending.',
 'diagnosis':'Tagged external pointers include their tags in object.size; the old collector assumed empty-pointer size. Each tagged pointer is 184 bytes, with 120 tag bytes. Shared CHARSXP identity permits a separate unique tag charge of 176 bytes over two empty 64-byte pointer skeletons.'}
(out/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
