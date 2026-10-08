"""Owner-only detached private F6e gate; inspect final native-ready schema first.

No execution occurs on import. One lock covers all native/model stages. Each
attempt retains source, partial receipts and failure before reporting status.
"""
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import tarfile
import time
import traceback

REPO = Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
ROOT = Path('/private/tmp/relm-f6e')
WORK = REPO / 'rebirth/src/rust'
MODEL = Path('/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf')
MODEL_HASH = 'ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e'
REFERENCE = REPO / 'tests/llm-golden/projection/goldens/manifest.csv'
REFERENCE_HASH = '78729e5fe710e30dffa83e76a9d084ee15091a0ef7074230172c3293f2463959'
MODES = ['callback_free', 'dormant', 'zero', 'active_one', 'active_multi']
ORDERS = [MODES, ['active_multi', 'zero', 'callback_free', 'active_one', 'dormant'],
          ['active_one', 'dormant', 'active_multi', 'zero', 'callback_free']]
TEST_IDS = [
 'projection::tests::projection_row_matches_independent_reference',
 'projection::tests::projection_boundary_rejects_invalid_inputs',
 'projection::tests::projection_capacity_ledger_matches_owned_buffers',
 'projection::tests::projection_classifier_accepts_only_declared_dense_sites',
 'projection::tests::projection_probe_rejects_missing_noop_and_wrong_site',
 'projection::tests::projection_forward_matches_independent_reference',
 'projection::tests::projection_microbatches_pruning_and_graph_reuse',
 'projection::tests::projection_capture_and_static_additive_composition',
 'projection::tests::projection_cancel_fault_and_owner_cleanup']
BENCH_ID = 'projection::tests::projection_feasibility_model'
TINY_HASH = 'e255ed5db07f318cbc3bd1d4d5a5a261bdef0867b3bbd1e26228f015b872bd05'
EXPECTED = dict(zip(TEST_IDS, [(13,52,0),(17,0,17),(8,0,1),(12,0,8),(6,0,6),
                              (15,34748,0),(3,10042,0),(6,0,1),(3,0,3)]))


def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()


def integer(x, minimum=0):
 assert type(x) is int and x >= minimum
 return x


def number(x, minimum=0):
 assert type(x) in (int,float) and math.isfinite(x) and x >= minimum
 return x


def markers(log, marker):
 values=[]
 for line in log.splitlines():
  if marker+' ' in line:
   value=json.loads(line.split(marker+' ',1)[1]);assert isinstance(value,dict)
   values.append(value)
 return values


def test_result(log, expected):
 rows=re.findall(r'test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored;',log)
 assert len(rows)==1 and tuple(map(int,rows[0]))==(expected,0,0),rows


def test_receipt(row, test_id, source):
 assert row['schema']==1 and row['model_sha256']==TINY_HASH
 assert row['test_id']==test_id and row['status']=='passed'
 assert row['source_manifest_sha256']==source and row['reference_manifest_sha256']==REFERENCE_HASH
 assert integer(row['executed_cases'],1)==integer(row['expected_cases'],1)
 assert integer(row['compared_values'])==integer(row['expected_values'])
 assert integer(row['negative_controls_rejected'])==integer(row['negative_controls_expected'])
 number(row['max_abs_error']);number(row['max_rel_error'])
 assert tuple(row[k] for k in ('executed_cases','compared_values','negative_controls_rejected'))==EXPECTED[test_id]
 if test_id.endswith(('forward_matches_independent_reference','microbatches_pruning_and_graph_reuse')):
  assert row['max_abs_error']<=0.01
 if test_id.endswith(('row_matches_independent_reference','forward_matches_independent_reference')):
  integer(row['compared_values'],1)
 if test_id.endswith('row_matches_independent_reference'):
  assert row['executed_cases']==13 and row['compared_values']==52
 if test_id.endswith('forward_matches_independent_reference'):
  assert row['executed_cases']==15
 if test_id.endswith(('boundary_rejects_invalid_inputs','classifier_accepts_only_declared_dense_sites','probe_rejects_missing_noop_and_wrong_site','cancel_fault_and_owner_cleanup')):
  integer(row['negative_controls_rejected'],1)


def main():
 ROOT.mkdir(exist_ok=True)
 lock=(ROOT/'verify.lock').open('a+')
 fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 ready=json.loads((ROOT/'native-ready.json').read_text())
 assert ready['status']=='ready'
 # The owner must bind final implementation field names/CLI before this gate.
 assert ready.get('owner_driver_contract_verified') is True
 assert ready['reference_commit'].startswith('d8a4800')
 for name,sha in ready['source_hashes'].items():assert digest(REPO/name)==sha,name
 assert digest(REFERENCE)==REFERENCE_HASH
 assert MODEL.is_file() and digest(MODEL)==MODEL_HASH
 run=ROOT/('feasibility-resume-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
 state={'status':'running','pid':os.getpid(),'directory':str(run),'started_at':time.time(),'stages':[],'model_sha256':MODEL_HASH,'reference_manifest_sha256':REFERENCE_HASH,'public_feature_acceptance':False}
 env=os.environ.copy();env['RUST_TEST_THREADS']='1'
 env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip()
 for key in list(env):
  if key.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_')) or key=='RELM_NATIVE_SANITIZERS':env.pop(key)
 def save():
  raw=json.dumps(state,indent=2)+'\n';(run/'status.json').write_text(raw)
  tmp=ROOT/'active-status.tmp';tmp.write_text(raw);tmp.replace(ROOT/'active-status.json')
 def stage(name,command,timeout=1800,overrides=None,allow_failure=False):
  item={'name':name,'command':command,'status':'running','started_at':time.time()};state['stages'].append(item);state['stage']=name;save()
  with (run/(name+'.log')).open('w') as out:
   child=subprocess.Popen(command,cwd=WORK,env={**env,**(overrides or {})},stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
   item['pid']=child.pid;save()
   try:rc=child.wait(timeout=timeout)
   except subprocess.TimeoutExpired:
    os.killpg(child.pid,signal.SIGTERM)
    try:child.wait(timeout=10)
    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
    item.update(status='failed',reason='stage timeout',finished_at=time.time());save();raise
  item.update(status='passed' if rc==0 else 'failed',exit_code=rc,finished_at=time.time(),log_sha256=digest(run/(name+'.log')));save()
  if rc and not allow_failure:raise RuntimeError(name+' failed; inspect retained source/log before any correction or retry')
  return (run/(name+'.log')).read_text()
 save()
 try:
  paths=subprocess.check_output(['git','ls-files','-co','--exclude-standard','rebirth/src/rust','rebirth/src/llama.cpp','tests/llm-golden/projection','tests/llm-golden/synthetic','tests/llm-golden/live-state/f6b'],cwd=REPO,text=True).splitlines()
  paths=sorted({p for p in paths if (REPO/p).is_file()})
  manifest={p:digest(REPO/p) for p in paths};raw=(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode();source=hashlib.sha256(raw).hexdigest()
  (run/'source-manifest.json').write_bytes(raw);(run/'verify-feasibility.py').write_bytes(Path(__file__).read_bytes())
  (run/'native-ready.json').write_text(json.dumps(ready,indent=2)+'\n')
  (run/'candidate.patch').write_bytes(subprocess.check_output(['git','diff','--binary','HEAD'],cwd=REPO))
  changed=set(subprocess.check_output(['git','diff','--name-only','HEAD'],cwd=REPO,text=True).splitlines())
  changed.update(subprocess.check_output(['git','ls-files','--others','--exclude-standard'],cwd=REPO,text=True).splitlines())
  with tarfile.open(run/'changed-source.tar.gz','w:gz') as archive:
   for p in sorted(changed.intersection(paths)):archive.add(REPO/p,arcname=p)
  state['carried_parent_verification']='/private/tmp/relm-f6e/feasibility-20261007-212937/owner-verification.json'
  state['executed_scope']='affected native6-9 plus previously unrun CPU/Metal benchmark'
  state['source_manifest_sha256']=source
  env.update(F6E_MODEL=str(MODEL),F6E_MODEL_SHA256=MODEL_HASH,F6E_SOURCE=source,F6E_REFERENCE_MANIFEST_SHA256=REFERENCE_HASH)
  save()
  stage('format',['cargo','fmt','--all','--check'])
  stage('clippy',['cargo','clippy','--locked','--offline','-p','rebirth-llm','--all-targets','--','-D','warnings'])
  stage('no-spill-compile',['cargo','test','--locked','--offline','-p','rebirth-llm','--no-default-features','--lib','--no-run'])
  receipts=[]
  for index,test_id in enumerate(TEST_IDS[5:],6):
   log=stage(f'native-{index:02}', ['cargo','test','--locked','--offline','-p','rebirth-llm','--lib',test_id,'--','--exact','--nocapture','--test-threads=1'])
   test_result(log,1);rows=markers(log,'F6E_PROJECTION_TEST')
   assert len(rows)==1
   receipts.extend(rows);(run/'native-receipts.json').write_text(json.dumps(receipts,indent=2)+'\n')
   test_receipt(rows[0],test_id,source)
   same=markers(log,'F6E_PROJECTION_SAME_ROW')
   if test_id in TEST_IDS[5:7]:
    assert len(same)==1
    verify_same_row(same[0],test_id,'cpu',source)
   else:assert not same
  for backend in ('cpu','metal'):
   log=stage('benchmark-'+backend,['cargo','test','--locked','--offline','-p','rebirth-llm','--release','--lib',BENCH_ID,'--','--exact','--ignored','--nocapture','--test-threads=1'],overrides={'F6E_BACKEND':backend},allow_failure=True)
   rows=markers(log,'F6E_PROJECTION_BENCH');(run/('benchmark-'+backend+'.json')).write_text(json.dumps(rows,indent=2)+'\n')
   # Exact sample/order/backend proof verifier is finalized against native-ready
   # before the owner enables owner_driver_contract_verified; no guessed shape.
   verify_benchmark(rows,backend,source,log)
   test_result(log,1)
  state['source_drift']=[p for p,h in manifest.items() if not (REPO/p).is_file() or digest(REPO/p)!=h]
  assert not state['source_drift'],'source changed during attempt'
  assert all(s['status']=='passed' for s in state['stages'])
  state['status']='awaiting_owner_verification'
 except Exception as error:
  state.update(status='failed',error=str(error),traceback=traceback.format_exc())
 finally:
  if 'manifest' in locals():
   state['source_drift']=[p for p,h in manifest.items() if not (REPO/p).is_file() or digest(REPO/p)!=h]
  state['finished_at']=time.time();save()


def verify_same_row(row,test_id,backend,source):
 assert row['schema']==1 and row['status']=='passed'
 assert row['source_manifest_sha256']==source and row['reference_manifest_sha256']==REFERENCE_HASH
 assert row['test_id']==test_id and row['requested_backend']==backend
 want={TEST_IDS[5]:2944,TEST_IDS[6]:704}[test_id]
 assert integer(row['expected_values'],1)==integer(row['compared_values'],1)==want
 assert row['scaled_error_definition']=='abs(actual-expected_f32)/(1+abs(expected_f32))'
 assert row['scaled_error_limit']==2e-6
 number(row['max_abs_error']);assert number(row['max_scaled_error'])<=2e-6


def verify_backend(row, backend, layers):
 assert row['resolved_backend']==backend
 log=row['native_load_log'];assert isinstance(log,str) and log
 offload=[];devices=[];compute=[]
 for line in log.splitlines():
  if ': offloaded ' in line:
   counts=line.split(': offloaded ',1)[1].split()[0].split('/')
   assert len(counts)==2
   offload.append([int(n) for n in counts])
  if ': using device ' in line:devices.append(line.split(': using device ',1)[1])
  if ' compute buffer size = ' in line:
   prefix,suffix=line.split(' compute buffer size = ',1)
   compute.append([prefix.split(':',1)[1].strip(),float(suffix.split()[0])])
 assert offload==row['offloaded_layers'] and devices==row['selected_devices'] and compute==row['compute_buffers_mib']
 assert compute
 for name,mib in compute:
  assert isinstance(name,str) and name
  number(mib)
 if backend=='cpu':
  assert integer(row['gpu_layer_policy'])==0 and devices==[]
  assert all(integer(a)==0 and integer(b)>=0 for a,b in offload)
  assert all(name=='CPU' for name,_ in compute) and any(mib>0 for _,mib in compute)
 else:
  assert backend=='metal' and integer(row['gpu_layer_policy'],1)>0
  assert offload==[[layers+1,layers+1]]
  selected=[d.split()[0] for d in devices]
  assert any(re.fullmatch(r'(?:Metal\d*|MTL\d+)',d) and any(name==d and mib>0 for name,mib in compute) for d in selected)


def verify_benchmark(rows,backend,source,log):
 assert len(rows)==1
 r=rows[0]
 assert r['schema']==1 and r['status']=='passed'
 assert r['source_manifest_sha256']==source and r['reference_manifest_sha256']==REFERENCE_HASH
 assert r['model_sha256']==MODEL_HASH and r['model']==str(MODEL)
 assert r['build_profile']=='release' and r['debug_assertions'] is False
 assert r['requested_backend']==backend and r['resolved_backend']==backend
 for key in ('callback_free_backend','hooked_backend'):verify_backend(r[key],backend,24)
 settings=r['settings']
 wanted={'n_batch':512,'n_ubatch':128,'context_length':768,'max_tokens':128,'seed':42,
         'temperature':0.8,'top_p':0.95,'warmups_per_mode':1,'measured_rounds':3,
         'component':'mlp_out','single_layer_native':12,'multi_layers_native':[0,12,23],
         'direction':'unit axis at native coordinate 1','coefficient':1.0}
 assert all(settings[k]==v and type(settings[k]) is type(v) for k,v in wanted.items())
 integer(settings['prompt_tokens'],1)
 assert r['mode_order']==MODES
 samples=r['samples'];assert len(samples)==20
 assert markers(log,'F6E_PROJECTION_SAMPLE')==samples
 expected=[(0,True,m) for m in MODES]+[(i+1,False,m) for i,order in enumerate(ORDERS) for m in order]
 times={m:[] for m in MODES}
 for s,(rnd,warm,mode) in zip(samples,expected):
  assert integer(s['round'])==rnd and s['warmup'] is warm and s['mode']==mode
  assert integer(s['decoded_tokens'],1)==128
  pre=number(s['prefill_seconds']);dec=number(s['decode_seconds']);elapsed=number(s['elapsed_seconds'])
  assert pre>0 and dec>0 and elapsed>0 and pre+dec<=elapsed
  counts=[integer(s[k]) for k in ('site_rows','read_bytes','write_bytes','barriers')]
  if mode in MODES[:3]:assert counts==[0,0,0,0]
  else:
   n,read,write,barriers=counts
   assert n>0 and read>=write>0 and barriers>0
   assert write==n*896*4 and read%(896*4)==0
  if not warm:times[mode].append(elapsed)
 medians=[statistics.median(times[m]) for m in MODES]
 assert len(r['median_elapsed_seconds'])==5
 assert all(math.isclose(number(x),y,rel_tol=1e-12,abs_tol=0) for x,y in zip(r['median_elapsed_seconds'],medians))
 ratio=medians[1]/medians[0]
 assert math.isclose(number(r['dormant_ratio']),ratio,rel_tol=1e-12,abs_tol=0)
 assert r['dormant_limit']==1.05 and ratio<=1.05 and r['active_limit'] is None
 timing=markers(log,'F6E_PROJECTION_TIMING');assert len(timing)==1
 assert timing[0]=={'medians':r['median_elapsed_seconds'],'dormant_ratio':r['dormant_ratio'],'dormant_limit':1.05,'active_limit':None}
 tiny=r['tiny_forward'];raw_tiny=markers(log,'F6E_PROJECTION_METAL_FORWARD')
 if backend=='cpu':assert tiny is None and raw_tiny==[] and markers(log,'F6E_PROJECTION_SAME_ROW')==[]
 else:
  assert raw_tiny==[tiny] and tiny['status']=='passed' and tiny['model_sha256']==TINY_HASH
  assert integer(tiny['expected_cases'],1)==integer(tiny['executed_cases'],1)==15
  assert integer(tiny['expected_values'],1)==integer(tiny['compared_values'],1)==34748
  assert number(tiny['max_abs_error'])<=0.01
  number(tiny['max_rel_error']);verify_backend(tiny['backend'],'metal',3)
  verify_same_row(tiny['same_row'],TEST_IDS[5],'metal',source)
  assert markers(log,'F6E_PROJECTION_SAME_ROW')==[tiny['same_row']]


if __name__=='__main__':main()
