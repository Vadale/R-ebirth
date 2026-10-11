import json,os,subprocess,time
from pathlib import Path
root=Path('/private/tmp/relm-maintenance-040');work=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth/rebirth/src/rust')
env=os.environ.copy();env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip();env['RUST_TEST_THREADS']='1'
state={'status':'running','pid':os.getpid(),'stages':[]}
def save():
 p=root/'final-local-status.tmp';p.write_text(json.dumps(state,indent=2)+'\n');p.replace(root/'final-local-status.json')
save()
for name,cmd in [
 ('format',['cargo','fmt','--all','--check']),
 ('native-clippy',['cargo','clippy','--locked','--offline','-p','rebirth-llm','--all-targets','--','-D','warnings']),
 ('private-check',['cargo','check','--locked','--offline','-p','rebirth-ffi','--features','projection-private']),
 ('ffi-unit',['cargo','test','--locked','--offline','-p','rebirth-ffi','--features','selftest','--lib'])]:
 row={'name':name,'command':cmd,'status':'running'};state['stage']=name;state['stages'].append(row);save()
 with (root/(name+'.log')).open('w') as log:r=subprocess.run(cmd,cwd=work,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
 row.update(status='passed' if r.returncode==0 else 'failed',exit_code=r.returncode);save()
 if r.returncode:break
state['status']='awaiting_owner_verification' if all(x['status']=='passed' for x in state['stages']) else 'failed';state['finished']=time.time();save()
