"""Single affected diagnostic execution. Collection is never feature acceptance."""
import csv
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import tarfile
import time
import traceback

ROOT=Path('/private/tmp/relm-f6e')
REPO=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
WORK=REPO/'rebirth/src/rust'
spec=importlib.util.spec_from_file_location('prior_collector',ROOT/'verify-feasibility.py')
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
PREFIX='F6E_PROJECTION_DIAGNOSTIC_'
ID='projection::tests::projection_long_prefill_schedule_diagnostic'
VARIANTS=['split_all_audit','grouped_last_no_audit','grouped_last_repeat',
          'split_all_no_audit','grouped_last_audit','grouped_all_audit','split_last_audit']

def near(a,b):
 assert math.isfinite(a) and math.isfinite(b) and math.isclose(a,b,rel_tol=1e-12,abs_tol=1e-14),(a,b)

def delta(actual,expected):
 assert len(actual)==len(expected)==48
 values=[abs(float(a)-float(b)) for a,b in zip(actual,expected)]
 assert all(math.isfinite(x) for x in values)
 return dict(compared_values=48,max_abs_error=max(values),
             max_error_token_native=values.index(max(values)),count_above_0_01=sum(x>0.01 for x in values),
             bitwise_equal=all(struct.pack('<f',a)==struct.pack('<f',b) for a,b in zip(actual,expected)))

def collect(log,source):
 starts=gate.markers(log,PREFIX+'START');runs=gate.markers(log,PREFIX+'RUN')
 pairs=gate.markers(log,PREFIX+'PAIR');ends=gate.markers(log,PREFIX+'COMPLETE')
 assert len(starts)==len(ends)==1 and len(runs)==16 and len(pairs)==17
 start=starts[0];end=ends[0]
 assert start['schema']==1 and start['status']=='diagnostic_only'
 assert start['source_manifest_sha256']==source and start['reference_manifest_sha256']==gate.REFERENCE_HASH
 assert start['model_sha256']==gate.TINY_HASH and start['n_batch']==512 and start['n_ubatch']==128
 assert start['runs_expected']==16 and start['whole_forward_tolerance']==0.01 and start['same_row_scaled_tolerance']==2e-6
 gate.verify_backend(start['backend'],'cpu',3)
 with (REPO/'tests/llm-golden/projection/goldens/forward-tokens.csv').open() as f:
  tokens=[int(r['token_id_native']) for r in csv.DictReader(f) if r['case']=='long_prefill']
 assert start['tokens_native']==tokens and len(tokens)==514
 expected_ids=['ordinary/split_all','ordinary/grouped_last']+[m+'/'+v for m in ('zero','active') for v in VARIANTS]
 assert [r['id'] for r in runs]==expected_ids
 byid={r['id']:r for r in runs};assert len(byid)==16
 with (REPO/'tests/llm-golden/projection/goldens/forward-logits.csv').open() as f:
  golden={int(r['token_id_native']):float(r['logit']) for r in csv.DictReader(f) if r['case']=='long_prefill' and int(r['source_pos'])==514}
 assert len(golden)==48
 audited=0;summary=[]
 for r in runs:
  assert r['schema']==1 and r['status']=='collected'
  assert r['cache_cleared_before_run'] is True and r['continuation_without_cache_reset'] is True
  mode,variant=r['id'].split('/');assert r['mode']==mode
  schedule=[512,1,1] if variant.startswith('split') else [512,2]
  assert r['schedule']==schedule and r['last_only']==('last' in variant)
  audit=variant.endswith('_audit') and not variant.endswith('_no_audit')
  assert r['audit'] is audit
  assert len(r['final_logits'])==len(r['continuation_logits'])==48
  assert all(type(x) in (float,int) and math.isfinite(x) for x in r['final_logits']+r['continuation_logits'])
  assert len(r['steps'])==len(schedule)+1
  position=0
  for step,n in zip(r['steps'],schedule+[1]):
   assert step['start_native']==position and step['tokens']==n
   for key in ('cumulative_site_rows','cumulative_read_bytes','cumulative_write_bytes','cumulative_barriers'):gate.integer(step[key])
   position+=n
  assert position==515 and r['steps'][-1]['token_native']==1
  above=None
  if mode=='active':
   assert len(r['golden'])==48
   above=0
   for g in r['golden']:
    k=gate.integer(g['token_native']);assert k<48
    assert g['expected']==golden[k] and g['actual']==r['final_logits'][k]
    err=abs(g['actual']-golden[k]);near(g['abs_error'],err)
    assert g['within_0_01'] is (err<=0.01);above+=err>0.01
  else:assert r['golden'] is None
  if audit:
   audited+=1
   assert len(r['sites'])==2 and len(r['witnesses'])<=2048 and len(r['observed_rows'])<=128
   site_counts=[0,0];seen=[set(),set()];dup=0
   for w in r['witnesses']:
    assert len(w)==6
    k,pos,write,dot,before,after=w;assert k in (0,1) and type(pos) is int and 0<=pos<515 and type(write) is bool
    assert all(math.isfinite(x) for x in (dot,before,after));site_counts[k]+=1;dup+=pos in seen[k];seen[k].add(pos)
   assert r['site_counts']==site_counts and r['site_missing']==[515-len(x) for x in seen] and r['duplicate_positions']==dup
   vals=0;maximum=0.0;failures=0
   for b in r['observed_rows']:
    assert len(b['values'])==32 and all(math.isfinite(x) for x in b['values'])
    if not b['before']:continue
    site=[s for s in r['sites'] if s['layer_native']==b['layer_native'] and s['component']==b['component']];assert len(site)==1;site=site[0]
    after=[a for a in r['observed_rows'] if not a['before'] and all(a[k]==b[k] for k in ('position_native','layer_native','component'))];assert len(after)==1
    dot=0.0
    for h,v in zip(b['values'],site['direction']):dot+=h*v
    for h,v,actual in zip(b['values'],site['direction'],after[0]['values']):
     want=h if site['coefficient']==0 else h-(site['coefficient']*v)*dot
     want=struct.unpack('<f',struct.pack('<f',want))[0]
     scaled=abs(actual-want)/(1+abs(want));maximum=max(maximum,scaled);failures+=scaled>2e-6;vals+=1
   assert r['same_row']['compared_values']==vals and r['same_row']['count_above_2e_6']==failures
   near(r['same_row']['max_scaled_error'],maximum)
   # Missing rows remain a diagnostic finding, never silently called passing.
  else:
   assert r['observed_rows']==[] and r['witnesses']==[]
  summary.append(dict(id=r['id'],golden_values_above_0_01=above,site_counts=r['site_counts'] if audit else None,
                      site_missing=r['site_missing'] if audit else None,same_row=r['same_row'] if audit else None,
                      final_stats=r['steps'][-1]))
 expected_pairs=[('ordinary/split_all','ordinary/grouped_last')]
 for mode in ('zero','active'):
  a=mode+'/split_all_audit';d=mode+'/grouped_last_no_audit'
  expected_pairs += [(a,mode+'/'+v) for v in ('grouped_last_no_audit','split_all_no_audit','grouped_last_audit','grouped_all_audit','split_last_audit')]
  expected_pairs += [(d,mode+'/grouped_last_repeat'),(d,mode+'/grouped_last_audit')]
  if mode=='zero':expected_pairs += [('ordinary/split_all',mode+'/split_all_no_audit'),('ordinary/grouped_last',d)]
 assert [(p['left'],p['right']) for p in pairs]==expected_pairs
 for p in pairs:
  for field,values in [('final_logits','final_logits'),('continuation_logits','continuation_logits')]:
   want=delta(byid[p['left']][values],byid[p['right']][values]);got=p[field]
   for k in want:
    if k=='max_abs_error':near(got[k],want[k])
    else:assert got[k]==want[k]
 assert audited==8 and end==dict(schema=1,runs_expected=16,runs_collected=16,audit_runs_expected=8,
     same_row_values_per_audit_run_expected=384,witnesses_per_audit_run_expected=1030,
     status='collected',acceptance_claim=False,no_tolerance_or_golden_change=True)
 return dict(status='diagnostic_collection_verified',acceptance_claim=False,source_manifest_sha256=source,
             start=start,runs=runs,pairs=pairs,summary=summary,complete=end)

def main():
 lock=(ROOT/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 ready=json.loads((ROOT/'diagnostic-ready.json').read_text());assert ready['status']=='ready' and ready['test_id']==ID
 for n,h in ready['source_hashes'].items():assert gate.digest(REPO/n)==h,n
 assert gate.digest(gate.REFERENCE)==gate.REFERENCE_HASH
 run=ROOT/('diagnostic-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
 state=dict(status='running',pid=os.getpid(),directory=str(run),started_at=time.time(),stages=[],acceptance_claim=False)
 def save():
  raw=json.dumps(state,indent=2)+'\n';(run/'status.json').write_text(raw)
  tmp=ROOT/'diagnostic-status.tmp';tmp.write_text(raw);tmp.replace(ROOT/'diagnostic-status.json')
 save();manifest={}
 try:
  names=subprocess.check_output(['git','ls-files','-co','--exclude-standard','rebirth/src/rust','rebirth/src/llama.cpp','tests/llm-golden/projection','tests/llm-golden/live-state/f6b'],cwd=REPO,text=True).splitlines()
  manifest={n:gate.digest(REPO/n) for n in sorted(set(names)) if (REPO/n).is_file()}
  raw=json.dumps(manifest,indent=2,sort_keys=True)+'\n';(run/'source-manifest.json').write_text(raw)
  source=hashlib.sha256(raw.encode()).hexdigest();state['source_manifest_sha256']=source
  (run/'diagnostic-ready.json').write_text(json.dumps(ready,indent=2)+'\n')
  (run/'verify-diagnostic.py').write_bytes(Path(__file__).read_bytes())
  (run/'verify-feasibility.py').write_bytes((ROOT/'verify-feasibility.py').read_bytes())
  (run/'candidate.patch').write_bytes(subprocess.check_output(['git','diff','--binary','HEAD'],cwd=REPO))
  with tarfile.open(run/'changed-source.tar.gz','w:gz') as tar:
   for n in ready['source_hashes']:tar.add(REPO/n,arcname=n)
  env={**os.environ,'F6E_SOURCE':source,'F6E_REFERENCE_MANIFEST_SHA256':gate.REFERENCE_HASH,'RUST_TEST_THREADS':'1'}
  commands=[('format',['cargo','fmt','--all','--check']),('clippy',['cargo','clippy','--locked','--offline','-p','rebirth-llm','--all-targets','--','-D','warnings']),('diagnostic',ready['command'])]
  for name,cmd in commands:
   item=dict(name=name,command=cmd,status='running',started_at=time.time());state['stages'].append(item);state['stage']=name;save()
   with (run/(name+'.log')).open('w') as out:
    p=subprocess.Popen(cmd,cwd=WORK,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
    item['pid']=p.pid;save()
    try:rc=p.wait(timeout=600)
    except subprocess.TimeoutExpired:
     os.killpg(p.pid,signal.SIGTERM)
     try:p.wait(timeout=10)
     except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
     raise
   item.update(status='passed' if rc==0 else 'failed',exit_code=rc,finished_at=time.time(),log_sha256=gate.digest(run/(name+'.log')));save()
   if rc:raise RuntimeError(name+' failed; preserve and inspect before any retry')
  log=(run/'diagnostic.log').read_text();gate.test_result(log,1)
  result=collect(log,source);(run/'collection.json').write_text(json.dumps(result,indent=2)+'\n')
  state['status']='awaiting_owner_diagnosis'
 except Exception as e:state.update(status='failed',error=str(e),traceback=traceback.format_exc())
 finally:
  state['source_drift']=[n for n,h in manifest.items() if gate.digest(REPO/n)!=h]
  if state['source_drift']:state.update(status='failed',error='source drift during diagnostic')
  state['finished_at']=time.time();save()

if __name__=='__main__':main()
