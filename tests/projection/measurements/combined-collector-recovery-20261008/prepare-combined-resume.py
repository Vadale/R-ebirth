import ast,hashlib,json,shutil,subprocess
from pathlib import Path
root=Path('/private/tmp/relm-f6e');repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');oldrun=root/'combined-binding-20261008-031008'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
original=(root/'verify-combined-binding.py').read_text();resume=original
resume=resume.replace("ROOT/'combined-owner-binding.json'", "ROOT/'combined-resume-binding.json'")
resume=resume.replace("run=ROOT/('combined-binding-'+", "run=ROOT/('combined-binding-resume-'+")
a=resume.index("  commands=[('format'");b=resume.index("  base=ready['fresh_dll_contract']",a)
carry='''  previous=ROOT/'combined-binding-20261008-031008'
  prior=json.loads((previous/'status.json').read_text())
  assert prior['status']=='failed' and prior['source_drift']==[]
  assert prior['source_manifest_sha256']=='29835e928e07da28036ae9f14fb55401dc66382913f80b3747a0c40bcbe04935'
  assert manifest==json.loads((previous/'source-manifest.json').read_text())
  assert st['source_manifest_sha256']==prior['source_manifest_sha256']
  assert [s['name'] for s in prior['stages']]==['format','clippy-private','clippy-default','no-spill-default','no-spill-private','native-bridge-frame']
  carried=run/'carried';carried.mkdir()
  for s in prior['stages']:
   assert s['status']=='passed' and s['exit_code']==0
   log=previous/(s['name']+'.log');assert sha(log)==s['log_sha256']
   assert not re.search(r'^warning(?:\\[|:)',log.read_text(),re.M)
   shutil.copyfile(log,carried/log.name)
  for name in ['status.json','partial-verification.json','source-manifest.json']:shutil.copyfile(previous/name,carried/name)
  native=c.bridge_native((previous/'native-bridge-frame.log').read_text())
  assert native==json.loads((previous/'native-bridge-receipt-recovered.json').read_text())
  (run/'native-bridge-receipt.json').write_text(json.dumps(native,indent=2)+'\\n')
  st['carried_stages']=prior['stages'];st['carried_directory']=str(previous)
  st['carried_outcomes']=1;st['carried_cases']=2;st['carried_refusals']=0
  st['collector_recovery']='Exact named libtest prefix normalized; original failed run preserved; no native rerun.';save()
'''
resume=resume[:a]+carry+resume[b:]
assert resume[resume.index("  base=ready['fresh_dll_contract']"):]==original[original.index("  base=ready['fresh_dll_contract']"):]
ast.parse(resume);(root/'verify-combined-resume.py').write_text(resume)
oldbind=json.loads((root/'combined-owner-binding.json').read_text());bind=dict(oldbind)
files={p:h for p,h in oldbind['files'].items() if Path(p).name not in ['combined-collector.py','verify-combined-binding.py']}
for name in ['combined-collector.py','verify-combined-resume.py','test-combined-libtest-collector.py','test-combined-libtest-collector-initial.py','combined-collector-initial.py','verify-combined-binding.py','verify-combined-partial.py']:
 files[str(root/name)]=sha(root/name)
for name in ['source-manifest.json','status.json','partial-verification.json','native-bridge-receipt-recovered.json']:
 files[str(oldrun/name)]=sha(oldrun/name)
for s in json.loads((oldrun/'status.json').read_text())['stages']:files[str(oldrun/(s['name']+'.log'))]=s['log_sha256']
bind['files']=files;bind['collector_recovery_controls']=12;bind['collector_recovery_negatives']=10
bind['carried_execution']={'directory':str(oldrun),'stages':6,'outcomes':1,'cases':2,'refusals':0,'models':0,'manifest_sha256':sha(oldrun/'source-manifest.json')}
(root/'combined-resume-binding.json').write_text(json.dumps(bind,indent=2)+'\n')
for p,h in {**bind['files'],**bind['r_headers']}.items():assert sha(Path(p))==h,p
for p,h in json.loads((oldrun/'source-manifest.json').read_text()).items():assert sha(repo/p)==h,p
out=subprocess.run(['python3',str(root/'test-combined-libtest-collector.py')],capture_output=True,text=True,check=True)
(root/'combined-libtest-collector-controls.log').write_text(out.stdout+out.stderr)
preflight={'status':'ready','remaining_execution_block_byte_identical':True,'carried_stages':6,'carried_outcomes':1,'carried_cases':2,'source_hashes_verified':112,'no_product_source_change':True,'collector_controls':12,'collector_negatives':10,'other_collector_functions_AST_identical':4,'models_run':0,'native_tests_run':0,'driver_sha256':sha(root/'verify-combined-resume.py'),'binding_sha256':sha(root/'combined-resume-binding.json'),'collector_sha256':sha(root/'combined-collector.py'),'synthetic_fixture_correction':'Initial standalone positive omitted required exact test-name line; restored that fixture line, retained strict collector assertion and original fixture. Actual retained native log already passed corrected parser.'}
(root/'combined-resume-preflight.json').write_text(json.dumps(preflight,indent=2)+'\n')
archive=repo/'tests/projection/measurements/combined-collector-recovery-20261008';archive.mkdir(exist_ok=True)
for name in ['prepare-combined-resume.py','combined-resume-preflight.json','combined-resume-binding.json','verify-combined-resume.py','combined-collector.py','combined-collector-initial.py','test-combined-libtest-collector.py','test-combined-libtest-collector-initial.py','combined-libtest-collector-controls.log']:
 shutil.copyfile(root/name,archive/name)
(archive/'synthetic-fixture-failure.txt').write_text('The first collector-control script failed at its second positive fixture: deleting the libtest prefix also deleted the required exact test name. The raw native log positive passed. The standalone fixture now retains a separate exact-name line. No native/model execution occurred; collector name/count assertions are unchanged.\n')
print(json.dumps(preflight,indent=2))
