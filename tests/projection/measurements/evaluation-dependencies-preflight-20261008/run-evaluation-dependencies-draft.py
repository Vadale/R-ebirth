#!/usr/bin/env python3
"""Single detached F6e experiment. No retries, builds of relm, or model downloads."""
import csv, datetime, hashlib, importlib.util, json, os
from pathlib import Path
import shutil, subprocess, sys, time, traceback, shlex
REPO=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
BASE=Path('/private/tmp/relm-f6e')
SOURCES=REPO/'tests/projection/evaluation'
STATUS=BASE/'evaluation-status.json'
ACCEPTED=BASE/'installed-public-budget-20261008-105355'
LIB=BASE/'public-library-budget/relm'
MODEL=Path('/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf')
PARENT=BASE/'evaluation-tokenizer-20261008-120800'
DEPENDENCIES=BASE/'evaluation-dependencies.json'
DIAGNOSIS=BASE/'evaluation-20261008-115751/token-warning-diagnosis.json'
DLL_SHA='d7f946c23fa078a3426fc92791f9615f36a81643f18feab43741603ff42533fb'

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,x):
 t=Path(str(p)+'.tmp');t.write_text(json.dumps(x,indent=2,allow_nan=False)+'\n');t.replace(p)
def require(x,m):
 if not x:raise ValueError(m)
def status(state,stage,**extra):write(STATUS,dict(status=state,stage=stage,pid=os.getpid(),run_dir=str(out),updated_unix=time.time(),**extra))
def execute(name,args,env=None,timeout=None):
 status('running',name)
 with (out/(name+'.log')).open('wb') as f:r=subprocess.run(args,cwd=REPO,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=timeout)
 require(r.returncode==0,f'{name} exit {r.returncode}')
 return sha(out/(name+'.log'))

def main():
 binding=json.loads((BASE/'evaluation-dependencies-launch-binding.json').read_text())
 require(sha(__file__)==binding['driver_sha256'],'driver freeze changed')
 for name,digest in binding['files'].items():require(sha(name)==digest,'preflight source changed: '+name)
 require(subprocess.check_output(['git','branch','--show-current'],cwd=REPO,text=True).strip()=='codex/projection-steering','wrong branch')
 accepted=json.loads((ACCEPTED/'owner-verification.json').read_text());require(accepted['status']=='PASS','installed acceptance incomplete')
 old=json.loads((ACCEPTED/'source-manifest.json').read_text())
 for name,digest in old.items():require(sha(REPO/name)==digest,'accepted source drift: '+name)
 installed=json.loads((ACCEPTED/'installed-manifest.json').read_text())
 for name,digest in installed.items():require(sha(LIB/name)==digest,'accepted installed drift: '+name)
 require(sha(LIB/'libs/relm.so')==DLL_SHA,'wrong installed DLL')
 require(sha(MODEL)=='ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e','wrong model bytes')
 for n,h in binding['parent_files'].items():require(sha(PARENT/n)==h,'retained parent file drift: '+n)
 dependencies=json.loads(DEPENDENCIES.read_text())
 for p in dependencies:
  for name,h in p['files'].items():require(sha(Path(p['path'])/name)==h,'dependency drift: '+p['package']+'/'+name)
 before=dict(old)
 new=[*SOURCES.glob('*.py'),*SOURCES.glob('*.R'),SOURCES/'log_capture.c',SOURCES/'manifest.json',SOURCES/'prompts.csv',
      REPO/'docs/f6e-evaluation-protocol.md',REPO/'tests/llm-golden/directions/reference_directions.py',
      REPO/'rebirth/src/llama.cpp/include/llama.h',REPO/'rebirth/src/llama.cpp/ggml/include/ggml.h',
      REPO/'rebirth/src/llama.cpp/ggml/include/ggml-cpu.h',REPO/'rebirth/src/llama.cpp/ggml/include/ggml-backend.h',
      REPO/'rebirth/src/llama.cpp/ggml/include/ggml-opt.h',Path(__file__),BASE/'evaluation-verifier-schema.json',DIAGNOSIS,REPO/'rebirth/src/llama.cpp/src/llama-vocab.cpp']
 dependencies=(BASE/'evaluation-logger-dependencies.txt').read_text().split(':',1)[1].replace('\\\n',' ')
 new.extend([DEPENDENCIES,PARENT/'owner-partial-verification.json',PARENT/'config.json',BASE/'check-evaluation-resume.R'])
 new.extend(Path(n) if Path(n).is_absolute() else REPO/n for n in shlex.split(dependencies))
 for p in new:
  require(p.is_file(),'missing declared input '+str(p));name=str(p.relative_to(REPO)) if p.is_relative_to(REPO) else str(p)
  before[name]=sha(p)
 logger=out/'f6e_log_capture.dylib'
 logger_parent=BASE/'evaluation-producer-preflight-v3/f6e_log_capture.dylib'
 require(sha(logger_parent)==binding['logger_sha256'],'logger preflight binary drift')
 shutil.copy2(logger_parent,logger)
 for name in ('evaluation-logger-compile.log','evaluation-logger-check.log','check-evaluation-logger.R'):
  shutil.copy2(BASE/name,out/name)
 write(out/'logger-binding.json',dict(source_sha256=sha(SOURCES/'log_capture.c'),binary_sha256=sha(logger),
   compile_log_sha256=sha(out/'evaluation-logger-compile.log'),model_free_log_sha256=sha(out/'evaluation-logger-check.log'),
   actual_adapter_cases=6,refusals=4,models=0,scope='C adapter only; default logger restored after no native owners'))
 cfg=dict(library=str(LIB),dll_sha256=DLL_SHA,model=str(MODEL),model_sha256=sha(MODEL),
   logger=str(logger),logger_sha256=sha(logger),schema=str(BASE/'evaluation-verifier-schema.json'),
   manifest=str(SOURCES/'manifest.json'),prompts=str(SOURCES/'prompts.csv'),status=str(STATUS),
   python=sys.executable,rscript='/usr/local/bin/Rscript',collector=str(SOURCES/'collect_run.py'),
   source_revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),
   source_hashes=before,installed_hashes=installed,
   producer_sources=['tests/projection/evaluation/run.R','tests/projection/evaluation/collect_run.py',
      'tests/projection/evaluation/log_capture.c',str(Path(__file__))])
 cfg.update(dependency_manifest=str(DEPENDENCIES),dependency_manifest_sha256=sha(DEPENDENCIES),
  dependency_packages=[{k:p[k] for k in ('package','version','path')} for p in dependencies],
  construction_parent=dict(directory=str(PARENT),owner_sha256=sha(PARENT/'owner-partial-verification.json'),
   source_manifest_sha256=sha(PARENT/'sources-before.csv'),new_selection_generation_submissions_in_parent=0),
  construction_files=binding['construction_files'])
 for name,h in binding['construction_files'].items():
  require(sha(PARENT/name)==h,'construction drift: '+name)
  dest=out/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(PARENT/name,dest)
 require(sha(DIAGNOSIS)=='befbfb9501178b798872e61e2bf9966845579cb37263c5a51a7bf2992db059b9','diagnosis drift')
 shutil.copy2(DIAGNOSIS,out/'token-warning-diagnosis.json')
 write(out/'config.json',cfg)
 evidence=dict(owner=accepted,source_manifest_sha256=sha(ACCEPTED/'source-manifest.json'),
   installed_hashes=installed,library=str(LIB),scope='current installed source acceptance; local dirty source hashes separately frozen')
 write(out/'installed-evidence.json',evidence)
 shutil.copy2(BASE/'evaluation-dependencies-launch-binding.json',out/'launch-binding.json')
 spec=importlib.util.spec_from_file_location('collector',SOURCES/'collect_run.py');collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
 collector.source_snapshot(out,cfg,'sources-before.csv')
 env=os.environ.copy();env.update(R_LIBS=':'.join([str(LIB.parent),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library']),R_LIBS_USER=str(LIB.parent),F6E_RUN_EVALUATION='1',PYTHONDONTWRITEBYTECODE='1')
 preflight_env=env.copy();preflight_env.pop('F6E_RUN_EVALUATION')
 execute('runtime-preflight',['/usr/local/bin/Rscript','--vanilla',str(BASE/'check-evaluation-resume.R'),str(out/'config.json')],env=preflight_env,timeout=60)
 execute('experiment',['/usr/local/bin/Rscript','--vanilla',str(SOURCES/'run.R'),str(out)],env=env,timeout=20000)
 collector.source_snapshot(out,cfg,'sources-final.csv')
 require((out/'sources-final.csv').read_bytes()==(out/'sources-before.csv').read_bytes(),'final source drift')
 for p in dependencies:
  for name,h in p['files'].items():require(sha(Path(p['path'])/name)==h,'final dependency drift: '+p['package']+'/'+name)
 require(sha(logger)==cfg['logger_sha256'],'logger binary drift')
 report=json.loads((out/'complete-report.json').read_text())
 require(report['observations']==122,'missing final output')
 write(out/'raw-manifest.json',{str(p.relative_to(out)):sha(p) for p in out.rglob('*') if p.is_file() and p.name!='raw-manifest.json'})
 counts=json.loads((out/'attempt-counts.json').read_text())
 status('awaiting_owner_verification','complete',setting_attempts=122,actual_attempt_counters=counts,
        all_generation_calls_attempted=counts['generate']==122,carried_construction_captures=24,new_trace_attempts=counts['trace'],
        experiment_log_sha256=sha(out/'experiment.log'),scientific_acceptance=False)

if __name__=='__main__':
 out=BASE/('evaluation-dependencies-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
 out.mkdir(exist_ok=False)
 try:main()
 except BaseException as e:
  (out/'failure.txt').write_text(traceback.format_exc())
  write(out/'partial-file-manifest.json',{str(p.relative_to(out)):sha(p) for p in out.rglob('*') if p.is_file() and p.name!='partial-file-manifest.json'})
  status('failed','diagnose_before_retry',error=str(e),traceback_file=str(out/'failure.txt'))
  raise
