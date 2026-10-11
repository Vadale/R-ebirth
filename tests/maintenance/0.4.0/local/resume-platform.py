import json,os,subprocess,time
from pathlib import Path
root=Path('/private/tmp/relm-maintenance-040')
env=os.environ.copy();env.update(RELM_ENABLE_SELFTESTS='1',NOT_CRAN='true',R_LIBS=str(root/'builds-20261011-180737/selftest/library')+':/private/tmp/relm-service/library:/Users/alessandrovadala/Library/R/arm64/4.5/library')
for k in list(env):
 if k.startswith(('RELM_TEST_MODEL_','RELM_TEST_MMPROJ_','F6E_MODEL')):env.pop(k)
state={'status':'running','pid':os.getpid(),'scope':'61 retained platform-access failures only; test_file desc selects exact original test bodies; same compiled installed DLL; no build','started':time.time()}
def save():
 p=root/'platform-status.tmp';p.write_text(json.dumps(state,indent=2)+'\n');p.replace(root/'platform-status.json')
save()
with (root/'platform.log').open('w') as log:r=subprocess.run(['Rscript','--vanilla',str(root/'resume-platform.R')],env=env,cwd='/Users/alessandrovadala/DOCUDESK/R-ebirth',stdout=log,stderr=subprocess.STDOUT,timeout=1800)
state.update(status='awaiting_owner_verification' if r.returncode==0 else 'failed',exit_code=r.returncode,finished=time.time());save()
