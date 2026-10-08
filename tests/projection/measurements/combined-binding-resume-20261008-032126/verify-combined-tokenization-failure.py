from pathlib import Path
import csv,hashlib,json,re,shutil,subprocess,tarfile
root=Path('/private/tmp/relm-f6e');repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');run=root/'combined-binding-resume-20261008-032126';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
st=json.loads((run/'status.json').read_text());manifest=json.loads((run/'source-manifest.json').read_text());bind=json.loads((run/'owner-binding.json').read_text());bindings=json.loads((run/'binary-bindings.json').read_text())
assert st['status']=='failed' and st['stage']=='combined-R-binding' and st['source_drift']==[]
assert len(manifest)==112 and sha(run/'source-manifest.json')==st['source_manifest_sha256']
for p,h in manifest.items():assert sha(repo/p)==h,p
with tarfile.open(run/'changed-source.tar.gz') as t:
 members=t.getmembers();assert len(members)==44
 for member in members:assert hashlib.sha256(t.extractfile(member).read()).hexdigest()==manifest[member.name]
assert len(bind['r_headers'])==42
for p,h in bind['r_headers'].items():assert sha(Path(p))==h
assert len(st['stages'])==7
assert all(s['status']=='passed' and s['exit_code']==0 for s in st['stages'][:6])
assert st['stages'][-1]['status']=='failed' and st['stages'][-1]['exit_code']==1
for s in st['stages']:
 log=run/(s['name']+'.log');assert sha(log)==s['log_sha256'];assert not re.search(r'^warning(?:\[|:)|^Warning',log.read_text(),re.M)
for s in st['carried_stages']:assert sha(run/'carried'/(s['name']+'.log'))==s['log_sha256']
registered=[]
for mode in ['default','private']:
 b=bindings[mode];assert ('projection-private' in b['artifact']['features'])==(mode=='private')
 assert len(b['static_archives'])==9
 for path,h in {**b['static_archives'],**b['C_files']}.items():
  copy=b['local_copies'].get(path);actual=Path(copy['path']) if copy else Path(path)
  assert sha(actual)==h,path
  if copy:assert copy['sha256']==h
 assert sha(Path(b['dll_path']))==b['dll_sha256'] and Path(b['dll_path']).stat().st_size==b['dll_bytes']
 assert sha(run/(mode+'-ffi')/'entrypoint.c')==b['entrypoint_sha256']==sha(repo/'rebirth/src/entrypoint.c')
 copies={Path(k).name:Path(v['path']) for k,v in b['local_copies'].items()}
 for archive in ['librelm.a','librelm-r-state.a']:
  assert subprocess.check_output(['ar','t',str(copies[archive])],text=True).splitlines().count('projection_state.o')==1
  assert hashlib.sha256(subprocess.check_output(['ar','p',str(copies[archive]),'projection_state.o'])).hexdigest()==sha(copies['projection_state.o'])
 text=(run/(mode+'-registration.log')).read_text();raw=re.findall(r'^F6E_PROJECTION_BRIDGE_R (\{[^\n]*\})$',text,re.M);assert len(raw)==1
 rr=json.loads(raw[0]);assert rr==dict(mode=mode,status='passed',expected_cases=2,executed_cases=2,expected_rejections=1,rejected_cases=1,model_count=0);registered.append(rr)
 with (run/(mode+'-profile.csv')).open() as f:p={x['field']:int(x['value']) for x in csv.DictReader(f)}
 assert len(p)==27 and p['version']==2 and p['ffi_command_bytes']==744 and p['derive_frame_bytes']==11959
assert registered==json.loads((run/'registration-receipts.json').read_text())
with (run/'combined-cases.csv').open() as f:rows=list(csv.DictReader(f))
assert rows==[dict(case='actual_model_shape',status='passed',refusal='FALSE')]
text=(run/'combined-R-binding.log').read_text();assert text.count('F6E_BINDING_CASE ')==1 and 'model carries no tokenizer (no_vocab)' in text and 'Execution halted' in text
assert 'F6E_COMBINED_R_BINDING' not in text
script=(run/'check-combined-binding.R').read_text();assert script.index('baseline <- logits(m)')<script.index('e$projection_derive(')
report={'status':'verified_partial_scope_original_combined_run_failed','source_count':112,'tar_members':44,'R_headers':42,'new_logs':7,'carried_logs':6,'complete_native_registration_outcomes':3,'complete_cases':6,'complete_refusals':2,'partial_R_cases':1,'tiny_model_loads':1,'constructor_calls':0,'compiler_linker_warnings':0,'source_manifest_sha256':st['source_manifest_sha256'],'C_bytes_bound_to_both_feature_archives':True,'fresh_default_private_DLL_hashes':{m:bindings[m]['dll_sha256'] for m in bindings},'cause':'Fixture invoked text logits on a frozen no_vocab synthetic model. Tokenizer refusal occurred before baseline logits/any constructor. Correct private test adapter to fixed raw-token logits on same tiny model; do not regenerate model/reference or weaken remaining cases.','next':'Narrow private-only fixed-token R-host helper; preserve successful registration/source scopes. No unchanged native/constructor/CPU/Metal/reference rerun.'}
(run/'partial-verification.json').write_text(json.dumps(report,indent=2)+'\n')
arc=repo/'tests/projection/measurements'/run.name;arc.mkdir(exist_ok=True)
for p in run.rglob('*'):
 if p.is_file() and 'binding-binaries' not in p.parts and p.suffix in ['.json','.csv','.log','.py','.R','.c','.patch','.gz']:
  dest=arc/p.relative_to(run);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
shutil.copyfile(__file__,arc/Path(__file__).name)
files={str(p.relative_to(arc)):{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(arc.rglob('*')) if p.is_file() and p.name!='file-manifest.json'}
(arc/'file-manifest.json').write_text(json.dumps(files,indent=2)+'\n');print(json.dumps(report,indent=2))
