from pathlib import Path
import csv,datetime,hashlib,json,os,shutil,subprocess,time
root=Path('/private/tmp/relm-f6e');repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
out=root/('owners-constructor-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));out.mkdir()
files=['rebirth/R/'+f for f in ['conditions.R','direction-schema.R','live-state.R','projection-memory.R','projection-owners.R','llm.R']]+['rebirth/tests/testthat/test-projection-memory.R','rebirth/tests/testthat/test-projection-owners.R']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
manifest={p:sha(repo/p) for p in files}
for p in files:
 target=out/p;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(repo/p,target)
shutil.copy2(root/'check-owners-constructor.R',out/'driver.R')
shutil.copy2(Path(__file__),out/'verify.py')
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
status={'status':'running','pid':os.getpid(),'directory':str(out),'started_at':time.time()}
def save():
 for p in [root/'owners-status.json',out/'status.json']:p.write_text(json.dumps(status,indent=2)+'\n')
save()
try:
 with (out/'test.log').open('wb') as log:
  p=subprocess.run(['Rscript','--vanilla',str(out/'driver.R')],env={**os.environ,'F6E_OWNER_RUN':str(out)},stdout=log,stderr=subprocess.STDOUT)
 assert p.returncode==0,p.returncode
 rows=list(csv.DictReader((out/'r-test-results.csv').open()))
 assert len(rows)==2 and all(int(r['passed'])>0 and r['failed']=='0' and r['error']=='FALSE' and r['skipped']=='FALSE' and r['warning']=='0' for r in rows)
 assert all(sha(repo/p)==h for p,h in manifest.items())
 status.update(status='passed',cases=2,expectations=sum(int(x['passed']) for x in rows),source_hashes=len(manifest),source_drift=[],model_runs=0,installed_acceptance=False,test_log_sha256=sha(out/'test.log'))
except BaseException as e:status.update(status='failed',error=repr(e))
finally:status['finished_at']=time.time();save()
