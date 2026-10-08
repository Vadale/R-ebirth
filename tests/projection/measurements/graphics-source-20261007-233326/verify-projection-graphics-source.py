from pathlib import Path
import hashlib,json,os,subprocess,time
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');root=Path('/private/tmp/relm-f6e')
run=root/('graphics-source-'+time.strftime('%Y%m%d-%H%M%S'));run.mkdir()
paths=['rebirth/R/'+n for n in ('conditions.R','direction-schema.R','direction-arithmetic.R','direction-encoding.R','direction-validation.R','directions.R','llm.R','live-state.R','graphics-helpers.R','graphics-plots.R')]+['rebirth/tests/testthat/'+n for n in ('helper-directions.R','helper-direction-goldens.R','test-projection-graphics.R')]
paths+= [str(p.relative_to(repo)) for p in sorted((repo/'rebirth/tests/testthat/fixtures/projection').iterdir())]
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
manifest={p:digest(repo/p) for p in paths}
(run/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
for p in paths:
 dest=run/'sources'/p;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes((repo/p).read_bytes())
state={'status':'running','pid':os.getpid(),'directory':str(run),'scope':'source-only projection graphics table tests; no native/model/installed acceptance'}
def save():
 (run/'status.json').write_text(json.dumps(state,indent=2)+'\n');(root/'graphics-status.json').write_text(json.dumps(state,indent=2)+'\n')
save()
with (run/'source-tests.log').open('w') as log:
 r=subprocess.run(['Rscript','--vanilla',str(root/'check-projection-graphics-source.R')],cwd=repo,env={**os.environ,'F6E_SCHEMA_RUN':str(run)},stdout=log,stderr=subprocess.STDOUT,timeout=120)
state.update(status='awaiting_owner_verification' if r.returncode==0 else 'failed',exit_code=r.returncode,source_drift=[p for p,h in manifest.items() if digest(repo/p)!=h],log_sha256=digest(run/'source-tests.log'))
save()
