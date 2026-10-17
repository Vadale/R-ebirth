from pathlib import Path
import os,json,subprocess,hashlib,datetime,time,csv,traceback
BASE=Path('/tmp/relm-phase8');OUT=BASE/'performance-profile';OUT.mkdir(exist_ok=False)
STATUS=BASE/'performance-profile-status.json';state={'status':'running','pid':os.getpid(),'output':str(OUT)}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def save():
 state['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(state,indent=2)+'\n');t.replace(STATUS)
telemetry=None
try:
 save();parent=BASE/'installed-pic';assert json.loads((parent/'owner.json').read_text())['status']=='passed'
 source=json.loads((parent/'source-after.json').read_text());assert all(sha(Path(p))==h for p,h in source.items())
 installed=json.loads((parent/'installed-hashes.json').read_text());assert all(sha(parent/'library/relm'/p)==h for p,h in installed.items())
 recipe=BASE/'performance-preparation/profile.R';logger=parent/'log_capture.so';model=Path('/home/grauk/.local/share/relm/models/qwen2.5-0.5b-instruct-q8_0.gguf')
 assert sha(model)=='ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e'
 binding={'recipe':sha(recipe),'logger':sha(logger),'DLL':sha(parent/'library/relm/libs/relm.so'),'model':sha(model),'parent_owner':sha(parent/'owner.json'),'source':source,'installed':installed}
 (OUT/'binding.json').write_text(json.dumps(binding,indent=2,sort_keys=True)+'\n')
 env=os.environ.copy();env.pop('LD_LIBRARY_PATH',None);env['R_LIBS']=str(parent/'library')+':/home/grauk/.local/share/relm/phase8/R-library';env['TMPDIR']='/home/grauk/.local/share/relm/phase8/tmp'
 for k in list(env):
  if k.startswith(('RELM_TEST_MODEL','F6E_MODEL')):env.pop(k)
 cmd=['nvidia-smi','--query-gpu=timestamp,index,utilization.gpu,utilization.memory,memory.used,temperature.gpu,clocks.sm,clocks.mem,power.draw,power.limit','--format=csv,nounits']
 baseline=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=True).stdout;(OUT/'gpu-before.csv').write_text(baseline)
 with (OUT/'gpu-samples.csv').open('w') as gpu,(OUT/'gpu-sampling.err').open('w') as gpuerr,(OUT/'profile.log').open('w') as log,(OUT/'process-samples.csv').open('w',newline='') as procfile:
  telemetry=subprocess.Popen(cmd+['--loop-ms=200'],stdout=gpu,stderr=gpuerr)
  proc=subprocess.Popen(['Rscript','--vanilla',str(recipe),str(OUT),str(model),str(logger)],env=env,stdout=log,stderr=subprocess.STDOUT)
  state.update(stage='profile',R_pid=proc.pid);save();writer=csv.writer(procfile);writer.writerow(['epoch','operation','rss_kib','hwm_kib','cpu_user_ticks','cpu_system_ticks','threads'])
  deadline=time.monotonic()+240
  while proc.poll() is None:
   try:
    status=dict(l.split(':',1) for l in Path(f'/proc/{proc.pid}/status').read_text().splitlines() if ':' in l)
    stats=Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')',1)[1].split()
    operation='startup';f=OUT/'current-operation.csv'
    if f.exists():
     entries=list(csv.DictReader(f.open()));operation=entries[0]['stage'] if entries else 'transition'
    writer.writerow([time.time(),operation,status.get('VmRSS','').split()[0],status.get('VmHWM','').split()[0],stats[11],stats[12],status['Threads'].strip()]);procfile.flush()
   except (FileNotFoundError,IndexError):pass
   if time.monotonic()>deadline:proc.terminate();raise RuntimeError('outer watchdog; retain partial profile without replay')
   time.sleep(.1) # Bounded performance telemetry, not interactive job polling.
  state['R_returncode']=proc.returncode
  if proc.returncode:raise RuntimeError('profiling execution failed; preserve raw outputs')
 telemetry.terminate();telemetry.wait(timeout=10);telemetry=None
 assert all(sha(Path(p))==h for p,h in source.items()) and all(sha(parent/'library/relm'/p)==h for p,h in installed.items())
 assert 'WP13_PROFILE_COMPLETE' in (OUT/'profile.log').read_text()
 (OUT/'files.json').write_text(json.dumps({str(p.relative_to(OUT)):sha(p) for p in OUT.rglob('*') if p.is_file()},indent=2,sort_keys=True)+'\n')
 state.update(status='awaiting_owner_verification',source_drift=False,diagnostic_only=True)
except Exception as e:
 state.update(status='failed',error=str(e));(OUT/'driver-error.txt').write_text(traceback.format_exc())
finally:
 if telemetry is not None:telemetry.terminate();telemetry.wait(timeout=10)
 save()
