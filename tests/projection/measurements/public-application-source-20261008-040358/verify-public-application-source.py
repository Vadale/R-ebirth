import json,hashlib,subprocess,os,time,traceback
from pathlib import Path
root=Path('/private/tmp/relm-f6e');repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
run=root/('public-application-source-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
paths=['rebirth/R/'+p+'.R' for p in ['conditions','direction-schema','live-state','llm','projection-memory','projection-owners','projection-binding','direction-arithmetic','direction-validation','direction-encoding','directions','intervene','images']]+['rebirth/tests/testthat/'+p+'.R' for p in ['helper-directions','test-projection-memory','test-projection-owners','test-projection-public-binding','test-projection-application']]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m={p:sha(repo/p) for p in paths};(run/'source-manifest.json').write_text(json.dumps(m,indent=2)+'\n')
for p in paths:
 d=run/'sources'/p;d.parent.mkdir(parents=True,exist_ok=True);d.write_bytes((repo/p).read_bytes())
for f in ['check-public-application-source.R','verify-public-application-source.py']:(run/f).write_bytes((root/f).read_bytes())
s={'status':'running','pid':os.getpid(),'directory':str(run),'scope':'source-only R binding/mocks; no installed/native/model acceptance'}
def save():
 raw=json.dumps(s,indent=2)+'\n';(run/'status.json').write_text(raw);p=root/'public-application-source-status.tmp';p.write_text(raw);p.replace(root/'public-application-source-status.json')
save()
try:
 with (run/'r-source.log').open('w') as log:
  p=subprocess.Popen(['Rscript','--vanilla',str(root/'check-public-application-source.R')],cwd=repo,env={**os.environ,'F6E_APPLICATION_RUN':str(run)},stdout=log,stderr=subprocess.STDOUT)
  s['child_pid']=p.pid;save();rc=p.wait(timeout=300)
 s['exit_code']=rc;s['log_sha256']=sha(run/'r-source.log')
 s['source_drift']=[p for p,h in m.items() if sha(repo/p)!=h]
 assert rc==0 and not s['source_drift']
 assert (run/'r-source.log').read_text().count('F6E_PUBLIC_APPLICATION_R_SOURCE cases=9 expectations=97 failures=0 errors=0 skips=0 warnings=0 native=0 models=0')==1
 s['status']='awaiting_owner_verification'
except Exception as e:s.update(status='failed',error=str(e),traceback=traceback.format_exc())
finally:save()
