import ast,hashlib,json,shutil,subprocess
from pathlib import Path
root=Path('/private/tmp/relm-f6e');repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
ready=json.loads((root/'combined-token-ready.json').read_text());oldbind=json.loads((root/'combined-owner-binding.json').read_text())
assert ready['status']=='ready' and ready['production_armed'] is False
for p,h in {**ready['source_hashes'],**ready['preserved_source_hashes']}.items():assert sha(repo/p)==h,p
# Exact registration recipe with output directory/profile capture added for ledger binding.
mode=ready['r_hosted_registration_gate']['source'];mode=mode.replace('length(args)==2L','length(args)==3L')
mode+="profile <- .Call(getNativeSymbolInfo('wrap__rebirth_projection_allocation_profile',PACKAGE=dll))\nwrite.csv(data.frame(field=names(profile),value=unlist(profile,use.names=FALSE)),file.path(args[[3L]],paste0(args[[2L]],'-profile.csv')),row.names=FALSE)\n"
(root/'check-combined-token-mode.R').write_text(mode)
original=(root/'verify-combined-binding.py').read_text();s=original
s=s.replace("ROOT/'combined-collector.py'","ROOT/'combined-token-collector.py'")
s=s.replace("ROOT/'combined-boundary-ready.json'","ROOT/'combined-token-ready.json'").replace("ROOT/'combined-owner-binding.json'","ROOT/'combined-token-binding.json'")
s=s.replace("**ready['preserved_native_source_hashes'],**ready['preserved_parent_constructor_helper']", "**ready['preserved_source_hashes']")
s=s.replace("run=ROOT/('combined-binding-'+", "run=ROOT/('combined-token-binding-'+")
s=s.replace("ROOT/'combined-status.tmp'", "ROOT/'combined-token-status.tmp'").replace("ROOT/'combined-status.json'","ROOT/'combined-token-status.json'")
s=s.replace("paths=set(paths)|set(ready['source_hashes'])|set(bind['repo_sources'])", "paths=set(paths)|set(ready['source_hashes'])|set(ready['preserved_source_hashes'])|set(bind['repo_sources'])")
s=s.replace("st['carried_accepted_scopes']=['private constructor49/35/240 at9cf850e8','R binding6/37 source only','R constructor3/61','all prior private/ledger/transfer/ref/model timing gates'];save()", "st['carried_accepted_scopes']=['parent bridge1/2/0 and default-private registrations2/4/2 at29835e92; not current helper execution','private constructor49/35/240 at9cf850e8','R binding6/37 source only','R constructor3/61','all prior private/ledger/transfer/ref/model timing gates'];save()")
s=s.replace("'-p','rebirth-ffi','--all-targets'", "'-p','rebirth-llm','-p','rebirth-ffi','--all-targets'")
old="  native=c.bridge_native(stage('native-bridge-frame',ready['tests'][0]['command']));(run/'native-bridge-receipt.json').write_text(json.dumps(native,indent=2)+'\\n')"
new="""  token=c.token_native(stage('native-token-shape',ready['tests'][0]['command']));(run/'native-token-receipt.json').write_text(json.dumps(token,indent=2)+'\\n')
  # Bridge layout source is unchanged. Bind its earlier executed receipt and
  # require each fresh compiled profile to match; do not rerun its exact test.
  native=json.loads((ROOT/'combined-binding-20261008-031008/native-bridge-receipt-recovered.json').read_text())
  assert native['bridge_frame_bytes']==320 and native['ffi_command_bytes']==744
  (run/'carried-native-bridge-receipt.json').write_text(json.dumps(native,indent=2)+'\\n')"""
assert old in s;s=s.replace(old,new)
s=s.replace("base=ready['fresh_dll_contract']['base']", "base=ready['fresh_dll_contract']")
s=s.replace("ROOT/'check-bridge-mode.R'","ROOT/'check-combined-token-mode.R'")
s=s.replace("ROOT/'check-combined-binding.R'","ROOT/'check-combined-tokens.R'")
needle="  with (run/'combined-materialization.csv').open() as f:mat=list(csv.DictReader(f))"
s=s.replace(needle,"  with (run/'combined-raw-token-logits.csv').open() as f:token_values=c.token_rows(list(csv.DictReader(f)),log)\n  (run/'token-values-receipt.json').write_text(json.dumps(token_values,indent=2)+'\\n')\n"+needle)
s=s.replace("outcomes=4,cases=33,refusals=6", "outcomes=4,cases=37,refusals=10")
s=s.replace("compiled_profile_terms=3*14)", "compiled_profile_terms=3*14,raw_token_calls=5,raw_token_values=240,independent_numerical_oracle=False,carried_parent_outcomes=3,carried_parent_cases=6,carried_parent_refusals=2)")
ast.parse(s);(root/'verify-combined-tokens.py').write_text(s)
# Check ready's complete link and execution schema before any runtime invocation.
base=ready['fresh_dll_contract'];basekeys={n.slice.value for n in ast.walk(ast.parse(s)) if isinstance(n,ast.Subscript) and isinstance(n.value,ast.Name) and n.value.id=='base' and isinstance(n.slice,ast.Constant)}
assert basekeys<=base.keys();assert sha(Path(base['entrypoint_source']))==base['entrypoint_sha256']
assert ready['interface']['symbol']=='wrap__rebirth_selftest_projection_combined_logits' and ready['interface']['arity']==1
assert ready['tests'][0]['expected_cases']==6 and ready['tests'][0]['expected_rejections']==4
assert len(ready['source_hashes'])==4 and len(ready['preserved_source_hashes'])==19
# All parent sources except the two approved module/registration files are exact.
parent=json.loads((root/'combined-binding-resume-20261008-032126/source-manifest.json').read_text())
changes={p for p,h in parent.items() if sha(repo/p)!=h};assert changes=={'rebirth/src/rust/rebirth-ffi/src/lib.rs','rebirth/src/rust/rebirth-llm/src/lib.rs'}
bind={k:v for k,v in oldbind.items() if k not in ['files','collector_controls','native_frame_cases','two_registration_modes_cases']}
bind['files']={str(root/name):sha(root/name) for name in ['combined-token-ready.json','verify-combined-tokens.py','combined-token-collector.py','combined-collector.py','test-combined-token-collector.py','check-combined-tokens.R','check-combined-token-mode.R']}
for path in ['combined-binding-20261008-031008/native-bridge-receipt-recovered.json','combined-binding-resume-20261008-032126/partial-verification.json']:
 bind['files'][str(root/path)]=sha(root/path)
bind.update(collector_controls=28,collector_negative_controls=23,new_outcomes=4,new_cases=37,new_refusals=10,shape_controls=6,shape_refusals=4,raw_token_calls=5,raw_token_values=240,raw_values_numerical_oracle=False,carried_parent_outcomes=3,carried_parent_cases=6,carried_parent_refusals=2)
(root/'combined-token-binding.json').write_text(json.dumps(bind,indent=2)+'\n')
for p,h in {**bind['files'],**bind['r_headers']}.items():assert sha(Path(p))==h,p
out=subprocess.run(['python3',str(root/'test-combined-token-collector.py')],capture_output=True,text=True,check=True);(root/'combined-token-collector-controls.log').write_text(out.stdout+out.stderr)
# Parse R only; no expressions, package install, native tests or model execution.
r=subprocess.run(['Rscript','--vanilla','-e',"invisible(parse(file='/private/tmp/relm-f6e/check-combined-tokens.R')); invisible(parse(file='/private/tmp/relm-f6e/check-combined-token-mode.R')); cat('R_HARNESS_PARSE_OK expressions_executed=0\\n')"],capture_output=True,text=True,check=True)
(root/'combined-token-R-parse.log').write_text(r.stdout+r.stderr)
pre={'status':'ready','ready_sha256':sha(root/'combined-token-ready.json'),'driver_sha256':sha(root/'verify-combined-tokens.py'),'binding_sha256':sha(root/'combined-token-binding.json'),'source_hashes':4,'preserved_hashes':19,'authorized_parent_source_changes':sorted(changes),'new_execution':{'outcomes':4,'cases':37,'refusals':10,'model_loads_planned':1,'constructor_calls_planned':5,'raw_logit_calls_planned':5,'raw_logit_values_planned':240},'carried_parent':{'outcomes':3,'cases':6,'refusals':2},'collector_controls':28,'negative_controls':23,'R_scripts_parsed':2,'no_model_or_native_execution':True,'all_link_contract_keys_checked':sorted(basekeys)}
(root/'combined-token-preflight.json').write_text(json.dumps(pre,indent=2)+'\n')
arc=repo/'tests/projection/measurements/combined-token-preflight-20261008';arc.mkdir(exist_ok=True)
for name in ['prepare-combined-token-run.py','combined-token-ready.json','combined-token-binding.json','combined-token-preflight.json','verify-combined-tokens.py','combined-token-collector.py','test-combined-token-collector.py','combined-token-collector-controls.log','check-combined-tokens.R','check-combined-token-mode.R','combined-token-R-parse.log']:
 shutil.copyfile(root/name,arc/name)
print(json.dumps(pre,indent=2))
