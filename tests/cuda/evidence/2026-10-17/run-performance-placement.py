from pathlib import Path
import os,subprocess,json,datetime,hashlib,traceback
B=Path('/tmp/relm-phase8');O=B/'performance-placement';O.mkdir(exist_ok=False);S=B/'performance-placement-status.json'
s={'status':'running','pid':os.getpid(),'scope':'separate load-only receipts; original benchmark native logs remain missing'}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save():
 s['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();p=S.with_suffix('.tmp');p.write_text(json.dumps(s,indent=2)+'\n');p.replace(S)
try:
 save();old=json.loads((B/'performance-benchmark/binding.json').read_text());lib=B/'installed-pic/library';recipe=B/'performance-placement-preparation/placement.R'
 assert all(sha(Path(p))==h for p,h in old['source'].items()) and all(sha(lib/'relm'/p)==h for p,h in old['installed'].items())
 (O/'binding.json').write_text(json.dumps({'recipe':sha(recipe),'benchmark_binding':sha(B/'performance-benchmark/binding.json'),'source':old['source'],'installed':old['installed'],'DLL':old['DLL']},indent=2,sort_keys=True)+'\n')
 env=os.environ.copy();env.pop('LD_LIBRARY_PATH',None);env['R_LIBS']=str(lib)+':/home/grauk/.local/share/relm/phase8/R-library'
 for backend in ['cpu','cuda']:
  p=O/backend;p.mkdir();s['stage']=backend;save()
  with (p/'run.log').open('w') as log:r=subprocess.run(['Rscript','--vanilla',str(recipe),str(p),backend],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=90)
  assert r.returncode==0,backend+' load-only failed; no retry'
 assert all(sha(Path(p))==h for p,h in old['source'].items()) and all(sha(lib/'relm'/p)==h for p,h in old['installed'].items())
 (O/'files.json').write_text(json.dumps({str(p.relative_to(O)):sha(p) for p in O.rglob('*') if p.is_file()},indent=2,sort_keys=True)+'\n');s['status']='awaiting_owner_verification'
except Exception as e:s.update(status='failed',error=str(e));(O/'error.txt').write_text(traceback.format_exc())
finally:save()
