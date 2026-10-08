import ast,csv,hashlib,json,shutil,tarfile
from pathlib import Path
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');root=Path('/private/tmp/relm-f6e');prior=root/'private-constructor-20261008-024059'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
changed='rebirth/src/rust/rebirth-ffi/src/projection_constructor_boundary.rs'
ready=json.loads((prior/'ready.json').read_text());manifest=json.loads((prior/'source-manifest.json').read_text())
assert [p for p,h in manifest.items() if sha(repo/p)!=h]==[changed]
ready['source_hashes'][changed]=sha(repo/changed)
ready['parent_attempt']={'directory':str(prior),'status':'failed_before_native_cases','diagnosis':'FFI twin JSON format brace and redundant outer validation called private methods. Authoritative native borrowed validation before five copies is unchanged.','changed_path':changed,'previous_sha256':manifest[changed]}
revision=root/'constructor-revision-ready.json';revision.write_text(json.dumps(ready,indent=2)+'\n')
src=(prior/'verify-constructor.py').read_text()
src=src.replace("ROOT/'constructor-ready.json'","ROOT/'constructor-revision-ready.json'").replace("ROOT/'constructor-owner-binding.json'","ROOT/'constructor-resume-binding.json'").replace("'private-constructor-'+","'private-constructor-resume-'+")
old="""  rlog=stage('r-source',['Rscript','--vanilla',str(ROOT/'check-constructor-source.R')],180,cwd=REPO)
  assert rlog.count('F6E_CONSTRUCTOR_R_SOURCE cases=3 expectations=61 failures=0 errors=0 skips=0 warnings=0 models=0')==1
  for n,cmd in enumerate(ready['compile_commands']):
   stage(['format','clippy-llm','clippy-ffi-private','no-spill-default','no-spill-private'][n],cmd)
"""
new="""  prior=ROOT/'private-constructor-20261008-024059'
  previous=json.loads((prior/'status.json').read_text())
  previous_manifest=json.loads((prior/'source-manifest.json').read_text())
  changed='rebirth/src/rust/rebirth-ffi/src/projection_constructor_boundary.rs'
  assert previous['status']=='failed' and previous['stage']=='clippy-ffi-private'
  assert digest(prior/'source-manifest.json')==previous['source_manifest_sha256']
  assert [p for p,h in previous_manifest.items() if digest(REPO/p)!=h]==[changed]
  carried=[]
  for name in ['r-source','clippy-llm']:
   record=next(s for s in previous['stages'] if s['name']==name)
   assert record['status']=='passed' and record['exit_code']==0
   assert digest(prior/(name+'.log'))==record['log_sha256']
   shutil.copyfile(prior/(name+'.log'),run/('carried-'+name+'.log'))
   carried.append({'stage':name,'execution_source':str(prior),'record':record})
  with (prior/'r-source-results.csv').open() as f:rows=list(csv.DictReader(f))
  assert [int(r['passed']) for r in rows]==[9,48,4]
  assert all(r['failed']=='0' and r['warning']=='0' and r['error']=='FALSE' and r['skipped']=='FALSE' for r in rows)
  shutil.copyfile(prior/'r-source-results.csv',run/'carried-r-source-results.csv')
  (run/'carried-scopes.json').write_text(json.dumps(carried,indent=2)+'\\n')
  state['carried_source_manifest_sha256']=previous['source_manifest_sha256'];save()
  for n,cmd in enumerate(ready['compile_commands']):
   if n==1:continue  # unchanged engine clippy is bound above, not reexecuted
   stage(['format','clippy-llm','clippy-ffi-private','no-spill-default','no-spill-private'][n],cmd)
"""
assert src.count(old)==1;src=src.replace(old,new)
ast.parse(src)
driver=root/'verify-constructor-resume.py';driver.write_text(src)
# Remaining execution and collection blocks are byte-identical.
assert src.split("  stage('clippy-ffi-default'",1)[1]==(prior/'verify-constructor.py').read_text().split("  stage('clippy-ffi-default'",1)[1]
binding=json.loads((prior/'owner-binding.json').read_text())
del binding['files'][str(root/'verify-constructor.py')];del binding['files'][str(root/'constructor-ready.json')]
binding['files'][str(driver)]=sha(driver);binding['files'][str(revision)]=sha(revision)
binding['carried_source_scope']={'R_cases':3,'R_expectations':61,'llm_clippy':'passed','execution':str(prior),'source_manifest_sha256':sha(prior/'source-manifest.json')}
for p,h in binding['files'].items():assert sha(Path(p))==h,p
for p,h in {**ready['source_hashes'],**ready['reference_hashes'],**ready['preserved_parent_abi_hash']}.items():assert sha(repo/p)==h,p
(root/'constructor-resume-binding.json').write_text(json.dumps(binding,indent=2)+'\n')
archive=repo/'tests/projection/measurements/constructor-correction-preflight-20261008';archive.mkdir()
for p in [driver,revision,root/'constructor-resume-binding.json',Path(__file__)]:shutil.copyfile(p,archive/p.name)
shutil.copyfile(repo/changed,archive/'projection_constructor_boundary.rs')
(archive/'verification.json').write_text(json.dumps({'status':'source_preflight_passed_not_execution','changed_native_paths':[changed],'new_sha256':sha(repo/changed),'native_source_hashes':20,'reference_hashes':4,'collector_controls_carried':56,'collector_sha256':sha(root/'constructor-collector.py'),'remaining_driver_tail_byte_identical':True,'carried_R_cases':3,'carried_R_expectations':61,'carried_llm_clippy':True,'R_tests_repeated':0,'native_cases_previously_executed':0},indent=2)+'\n')
print(json.dumps({'driver_sha256':sha(driver),'revision_sha256':sha(revision),'new_boundary_sha256':sha(repo/changed),'archive':str(archive)}))
