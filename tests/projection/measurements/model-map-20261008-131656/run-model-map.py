from pathlib import Path
import json,hashlib,subprocess,os,time,traceback,fcntl,importlib.util
B=Path('/private/tmp/relm-f6e');R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
I=B/'evaluation-dependencies-20261008-123712';O=B/('model-map-'+time.strftime('%Y%m%d-%H%M%S'))
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def status(state,**more):
 x=dict(status=state,pid=os.getpid(),directory=str(O),updated_unix=time.time(),**more)
 p=B/'model-map-status.tmp';p.write_text(json.dumps(x,indent=2)+'\n');p.replace(B/'model-map-status.json')
def main():
 lock=(B/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 z=json.loads((B/'model-map-binding.json').read_text());assert sha(__file__)==z['driver_sha256']
 for p,h in z['files'].items():assert sha(p)==h,p
 cfg=json.loads((I/'config.json').read_text())
 def freeze():
  for n,h in cfg['source_hashes'].items():assert sha(Path(n) if Path(n).is_absolute() else R/n)==h,n
  for n,h in cfg['installed_hashes'].items():assert sha(Path(cfg['library'])/n)==h,n
  assert sha(cfg['model'])==cfg['model_sha256']
  assert sha(cfg['logger'])==cfg['logger_sha256']
 freeze();O.mkdir(exist_ok=False);status('running',stage='actual_configured_handle_map')
 env=os.environ.copy();env['R_LIBS']=':'.join([str(B/'public-library-budget'),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
 with (O/'model-map.log').open('w') as out:
  p=subprocess.run(['/usr/local/bin/Rscript','--vanilla',str(R/'tests/projection/evaluation/model-map.R'),str(I),str(O)],cwd=R,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=180)
 assert p.returncode==0,'model map execution failed; preserve log and diagnose'
 freeze()
 spec=importlib.util.spec_from_file_location('f6e_map_collector',R/'tests/projection/evaluation/collect_run.py')
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 diagnosis=json.loads((I/'token-warning-diagnosis.json').read_text())
 cpu=module.cpu_receipt((O/'native-placement.log').read_bytes(),diagnosis)
 (O/'cpu-evidence.json').write_text(json.dumps(cpu,indent=2)+'\n')
 receipt=json.loads((O/'receipt.json').read_text());assert receipt['cases']==7 and receipt['refusals']==1
 raw=(O/'model-map.log').read_text();assert 'Warning' not in raw and 'Error' not in raw
 assert raw.count('F6E_MODEL_MAP_CASE ')==7 and raw.endswith('F6E_MODEL_MAP_COMPLETE cases=7 refusals=1 load_attempts=1 derive_attempts=1 generation_attempts=0\n')
 assert len(list(O.glob('*.png')))==len(list(O.glob('*.pdf')))==1
 (O/'manifest.json').write_text(json.dumps({p.name:sha(p) for p in O.iterdir() if p.is_file()},indent=2)+'\n')
 status('awaiting_visual_verification',stage='complete',cases=7,refusals=1,load_attempts=1,derive_attempts=1,generation_attempts=0)
try:main()
except Exception as e:
 O.mkdir(exist_ok=True);(O/'failure.txt').write_text(traceback.format_exc());status('failed',stage='diagnose_before_retry',error=str(e));raise
