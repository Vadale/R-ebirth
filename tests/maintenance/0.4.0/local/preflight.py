import hashlib,json,os,subprocess,time,traceback
from pathlib import Path
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); root=Path('/private/tmp/relm-maintenance-040')
work=repo/'rebirth/src/rust'; env=os.environ.copy(); env['R_HOME']=subprocess.check_output(['R','RHOME'],text=True).strip()
state={'status':'running','pid':os.getpid(),'stages':[],'started':time.time()}
def save():
 p=root/'preflight-status.tmp';p.write_text(json.dumps(state,indent=2)+'\n');p.replace(root/'preflight-status.json')
save()
try:
 commands=[
 ('state-compile',['R','CMD','SHLIB','state_api_test.c'],root/'state-api'),
 ('state-controls',['Rscript','--vanilla','run.R','state_api_test.so'],root/'state-api'),
 ('clippy-default',['cargo','clippy','--locked','--offline','-p','rebirth-ffi','--all-targets','--','-D','warnings'],work),
 ('clippy-selftest',['cargo','clippy','--locked','--offline','-p','rebirth-ffi','--all-targets','--features','selftest','--','-D','warnings'],work),
 ('check-no-spill',['cargo','check','--locked','--offline','-p','rebirth-ffi','--no-default-features'],work),
 ('check-private',['cargo','check','--locked','--offline','-p','rebirth-ffi','--features','projection-private'],work)]
 for name,cmd,cwd in commands:
  row={'name':name,'command':cmd,'status':'running'};state['stages'].append(row);state['stage']=name;save()
  with (root/(name+'.log')).open('w') as log: result=subprocess.run(cmd,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
  row.update(status='passed' if result.returncode==0 else 'failed',exit_code=result.returncode);save()
 state['status']='passed' if all(x['status']=='passed' for x in state['stages']) else 'failed'
except Exception as e: state.update(status='failed',error=str(e),traceback=traceback.format_exc())
state['finished']=time.time();save()
