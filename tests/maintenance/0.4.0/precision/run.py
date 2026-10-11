from pathlib import Path
import subprocess,os,json,time
r=Path('/private/tmp/relm-maintenance-040/precision'); cwd='/Users/alessandrovadala/DOCUDESK/R-ebirth/rebirth/src/rust'
status={'status':'running','pid':os.getpid(),'stages':[]}
def save(): (r/'status.json').write_text(json.dumps(status,indent=2)+'\n')
try:
 for name,cmd in [('clippy',['cargo','clippy','--locked','--offline','-p','rebirth-llm','--all-targets','--','-D','warnings']),('precision',['cargo','test','--locked','--offline','-p','rebirth-llm','--lib','projection::tests::projection_cache_precision_debt_diagnostic','--','--ignored','--exact','--nocapture','--test-threads=1'])]:
  status['stage']=name;save()
  with (r/(name+'.log')).open('w') as f: p=subprocess.run(cmd,cwd=cwd,env={**os.environ,'RUST_TEST_THREADS':'1','F6E_SOURCE':'maintenance-cache-precision-uncommitted'},stdout=f,stderr=subprocess.STDOUT)
  status['stages'].append({'name':name,'exit_code':p.returncode});save()
  if p.returncode: raise RuntimeError(name+' failed')
 status['status']='awaiting_owner_verification'
except Exception as e: status.update(status='failed',error=str(e))
finally: save()
