from pathlib import Path
import datetime, hashlib, json, os, subprocess, time
root = Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
out = Path('/private/tmp/relm-phase7')
source = root/'examples/research-workflow/run.R'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
record = {'started': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'status':'running', 'source_sha256':sha(source), 'installed_scope':'carried Phase6 R-state build; not a fresh installation'}
(out/'walkthrough-source.R').write_bytes(source.read_bytes())
(out/'walkthrough-status.json').write_text(json.dumps(record,indent=2)+'\n')
env = dict(os.environ)
env['R_LIBS'] = '/private/tmp/relm-f6e/r-state-api-resume-20261008-165326/library:/private/tmp/relm-service/library:/Users/alessandrovadala/Library/R/arm64/4.5/library'
start = time.monotonic()
with (out/'walkthrough.log').open('wb') as log:
    result = subprocess.run(['/usr/local/bin/Rscript','--vanilla',str(out/'walkthrough.R')],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
record.update(status='awaiting_owner_verification' if result.returncode == 0 else 'failed', exit_code=result.returncode, elapsed_seconds=time.monotonic()-start, source_unchanged=sha(source)==record['source_sha256'], log_sha256=sha(out/'walkthrough.log'))
(out/'walkthrough-status.json').write_text(json.dumps(record,indent=2)+'\n')
