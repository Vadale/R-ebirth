from pathlib import Path
import os,json,subprocess,hashlib,datetime,time,csv,traceback
B=Path('/tmp/relm-phase8');OUT=B/'performance-benchmark';OUT.mkdir(exist_ok=False)
STATUS=B/'performance-benchmark-status.json';state={'status':'running','pid':os.getpid(),'output':str(OUT),'completed_configs':[]}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def save():
 state['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(state,indent=2)+'\n');t.replace(STATUS)
telemetry=None;proc=None
try:
 save();P=B/'installed-pic';prep=B/'performance-benchmark-preparation'
 assert json.loads((P/'owner.json').read_text())['status']=='passed'
 assert json.loads((B/'performance-profile/owner.json').read_text())['status']=='passed'
 source=json.loads((P/'source-after.json').read_text());installed=json.loads((P/'installed-hashes.json').read_text())
 assert all(sha(Path(p))==h for p,h in source.items())
 assert all(sha(P/'library/relm'/p)==h for p,h in installed.items())
 recipe=prep/'benchmark.R';logger=P/'log_capture.so';model=Path('/home/grauk/.local/share/relm/models/qwen2.5-0.5b-instruct-q8_0.gguf')
 assert sha(model)=='ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e'
 binding={'recipe':sha(recipe),'protocol':sha(prep/'PROTOCOL.md'),'logger':sha(logger),'model':sha(model),'direction':sha(P/'workflow/directions.rds'),'DLL':sha(P/'library/relm/libs/relm.so'),'source':source,'installed':installed,'profile_owner':sha(B/'performance-profile/owner.json')}
 (OUT/'binding.json').write_text(json.dumps(binding,indent=2,sort_keys=True)+'\n')
 env=os.environ.copy();env.pop('LD_LIBRARY_PATH',None);env['R_LIBS']=str(P/'library')+':/home/grauk/.local/share/relm/phase8/R-library';env['TMPDIR']='/home/grauk/.local/share/relm/phase8/tmp'
 for k in list(env):
  if k.startswith(('RELM_TEST_MODEL','F6E_MODEL')):env.pop(k)
 cmd=['nvidia-smi','--query-gpu=timestamp,index,utilization.gpu,utilization.memory,memory.used,temperature.gpu,clocks.sm,clocks.mem,power.draw,power.limit','--format=csv,nounits']
 configs=[('cpu_baseline','cpu','.005'),('cuda_baseline','cuda','.005'),('cuda_live_1ms','cuda','.001')]
 for name,backend,interval in configs:
  dest=OUT/name;dest.mkdir();state.update(stage=name);save()
  (dest/'gpu-before.csv').write_text(subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=True).stdout)
  with (dest/'gpu-samples.csv').open('w') as gpu,(dest/'gpu-sampling.err').open('w') as err,(dest/'run.log').open('w') as log,(dest/'process-samples.csv').open('w',newline='') as procs:
   telemetry=subprocess.Popen(cmd+['--loop-ms=200'],stdout=gpu,stderr=err)
   proc=subprocess.Popen(['Rscript','--vanilla',str(recipe),str(dest),backend,interval,str(model),str(logger)],env=env,stdout=log,stderr=subprocess.STDOUT)
   state.update(R_pid=proc.pid);save();writer=csv.writer(procs);writer.writerow(['epoch','operation','rss_kib','hwm_kib','cpu_user_ticks','cpu_system_ticks','threads'])
   deadline=time.monotonic()+600
   while proc.poll() is None:
    try:
     status=dict(l.split(':',1) for l in Path(f'/proc/{proc.pid}/status').read_text().splitlines() if ':' in l)
     stats=Path(f'/proc/{proc.pid}/stat').read_text().rsplit(')',1)[1].split();operation='startup';f=dest/'current-operation.csv'
     if f.exists():
      with f.open() as stream:entries=list(csv.DictReader(stream))
      operation=entries[0]['stage'] if entries else 'transition'
     writer.writerow([time.time(),operation,status.get('VmRSS','').split()[0],status.get('VmHWM','').split()[0],stats[11],stats[12],status['Threads'].strip()]);procs.flush()
    except (FileNotFoundError,IndexError):pass
    if time.monotonic()>deadline:proc.terminate();raise RuntimeError('outer watchdog; retain partial benchmark, no replay')
    time.sleep(.1) # Fixed performance telemetry, not an interactive monitor.
   state['R_returncode']=proc.returncode
   if proc.returncode:raise RuntimeError(name+' execution failed; preserve all results without replay')
  telemetry.terminate();telemetry.wait(timeout=10);telemetry=None
  assert 'WP13_BENCHMARK_COMPLETE' in (dest/'run.log').read_text()
  state['completed_configs'].append(name);save()
 assert all(sha(Path(p))==h for p,h in source.items()) and all(sha(P/'library/relm'/p)==h for p,h in installed.items())
 assert binding['recipe']==sha(recipe) and binding['protocol']==sha(prep/'PROTOCOL.md')
 (OUT/'files.json').write_text(json.dumps({str(p.relative_to(OUT)):sha(p) for p in OUT.rglob('*') if p.is_file()},indent=2,sort_keys=True)+'\n')
 state.update(status='awaiting_owner_verification',source_drift=False)
except Exception as e:
 state.update(status='failed',error=str(e));(OUT/'driver-error.txt').write_text(traceback.format_exc())
finally:
 if telemetry is not None:telemetry.terminate();telemetry.wait(timeout=10)
 save()
