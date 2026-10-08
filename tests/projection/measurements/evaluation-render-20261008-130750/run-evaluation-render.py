from pathlib import Path
import json,hashlib,subprocess,os,time,traceback,fcntl
B=Path('/private/tmp/relm-f6e');R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
I=B/'evaluation-dependencies-20261008-123712';O=B/('evaluation-render-'+time.strftime('%Y%m%d-%H%M%S'))
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def status(state,**more):
 x=dict(status=state,pid=os.getpid(),directory=str(O),updated_unix=time.time(),**more)
 p=B/'render-status.tmp';p.write_text(json.dumps(x,indent=2)+'\n');p.replace(B/'render-status.json')
def main():
 lock=(B/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 z=json.loads((B/'render-binding.json').read_text());assert sha(__file__)==z['driver_sha256']
 for p,h in z['files'].items():assert sha(p)==h,p
 owner=json.loads((I/'owner-verification.json').read_text());assert owner['status']=='PASS'
 cfg=json.loads((I/'config.json').read_text());raw=json.loads((I/'raw-manifest.json').read_text())
 def freeze():
  for n,h in raw.items():assert sha(I/n)==h,n
  for n,h in cfg['source_hashes'].items():assert sha(Path(n) if Path(n).is_absolute() else R/n)==h,n
  for n,h in cfg['installed_hashes'].items():assert sha(Path(cfg['library'])/n)==h,n
 freeze();O.mkdir(exist_ok=False);status('running',stage='saved_state_and_summary_render')
 env=os.environ.copy();env['R_LIBS']=':'.join([str(B/'public-library-budget'),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
 with (O/'render.log').open('w') as out:
  p=subprocess.run(['/usr/local/bin/Rscript','--vanilla',str(R/'tests/projection/evaluation/render.R'),str(I),str(O)],cwd=R,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=120)
 assert p.returncode==0,'render execution failed; inspect raw log without inference rerun'
 freeze();assert len(list(O.glob('*.png')))==len(list(O.glob('*.pdf')))==5
 receipt=json.loads((O/'render-receipt.json').read_text());assert receipt['comparison_coordinates']==1792 and receipt['timeline_states']==4
 files={str(p.relative_to(O)):sha(p) for p in O.rglob('*') if p.is_file()}
 (O/'manifest.json').write_text(json.dumps(files,indent=2)+'\n')
 status('awaiting_visual_verification',stage='complete',models=0,inference=0,figures=5,recipe_sha256=z['files'][str(R/'tests/projection/evaluation/render.R')])
try:main()
except Exception as e:
 O.mkdir(exist_ok=True);(O/'failure.txt').write_text(traceback.format_exc());status('failed',stage='diagnose_before_retry',error=str(e));raise
