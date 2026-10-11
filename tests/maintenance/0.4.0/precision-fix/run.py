from pathlib import Path
import subprocess,os,json,hashlib
r=Path('/private/tmp/relm-maintenance-040/precision-fix'); repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');cwd=repo/'rebirth/src/rust'
names=['rebirth/src/rust/rebirth-llm/src/engine.rs','rebirth/src/rust/rebirth-llm/src/projection_test_support.rs','rebirth/src/rust/rebirth-llm/src/projection_prefix_debt_diagnostic.rs']
hashes={n:hashlib.sha256((repo/n).read_bytes()).hexdigest() for n in names}
(r/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
status={'status':'running','pid':os.getpid(),'stages':[]}
def save(): (r/'status.json').write_text(json.dumps(status,indent=2)+'\n')
try:
 commands=[('fmt',['cargo','fmt','--all','--check']),('clippy',['cargo','clippy','--locked','--offline','-p','rebirth-llm','--all-targets','--','-D','warnings'])]
 for label,test in [('forward','projection_forward_matches_independent_reference'),('microbatches','projection_microbatches_pruning_and_graph_reuse')]:
  commands.append((label,['cargo','test','--locked','--offline','-p','rebirth-llm','--lib','projection::tests::'+test,'--','--exact','--nocapture','--test-threads=1']))
 for name,cmd in commands:
  status['stage']=name;save()
  with (r/(name+'.log')).open('w') as f: p=subprocess.run(cmd,cwd=cwd,env={**os.environ,'RUST_TEST_THREADS':'1','F6E_SOURCE':'maintenance-explicit-oracle-precision'},stdout=f,stderr=subprocess.STDOUT)
  status['stages'].append({'name':name,'exit_code':p.returncode});save()
  if p.returncode: raise RuntimeError(name+' failed')
 assert hashes=={n:hashlib.sha256((repo/n).read_bytes()).hexdigest() for n in names}
 status['status']='awaiting_owner_verification'
except Exception as e: status.update(status='failed',error=str(e))
finally: save()
