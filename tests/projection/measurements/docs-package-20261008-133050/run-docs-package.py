"""Affected vignettes and scoped package check; no native/model/old-suite replay."""
from pathlib import Path
import fcntl,hashlib,json,os,shutil,signal,subprocess,time,traceback,tarfile
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');B=Path('/private/tmp/relm-f6e')
O=B/('docs-package-'+time.strftime('%Y%m%d-%H%M%S'))
I=B/'evaluation-dependencies-20261008-123712'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
state=dict(status='launching',pid=os.getpid(),directory=str(O),stages=[])
def save():
 state['updated_unix']=time.time();data=json.dumps(state,indent=2)+'\n'
 (O/'status.json').write_text(data)
 p=B/'docs-package-status.tmp';p.write_text(data);p.replace(B/'docs-package-status.json')
def main():
 lock=(B/'verify.lock').open('a+');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 binding=json.loads((B/'docs-package-binding.json').read_text())
 assert sha(__file__)==binding['driver_sha256']
 for p,h in binding['files'].items():assert sha(p)==h,p
 cfg=json.loads((I/'config.json').read_text())
 def freeze():
  for p,h in cfg['source_hashes'].items():assert sha(Path(p) if Path(p).is_absolute() else R/p)==h,p
  for p,h in cfg['installed_hashes'].items():assert sha(Path(cfg['library'])/p)==h,p
  for p,h in binding['files'].items():assert sha(p)==h,p
 freeze();O.mkdir(exist_ok=False);save()
 env=os.environ.copy()
 env['R_LIBS']=':'.join([str(B/'public-library-budget'),'/private/tmp/relm-service/library','/Users/alessandrovadala/Library/R/arm64/4.5/library'])
 env['R_LIBS_USER']=str(B/'public-library-budget')
 env['PATH']='/Applications/RStudio.app/Contents/Resources/app/quarto/bin:'+env['PATH']
 env['DENO_DIR']=str(B/'deno-cache')
 # No optional real-model examples or hidden network/model work in this scope.
 for k in list(env):
  if k.startswith(('RELM_TEST_MODEL','RELM_TEST_MMPROJ')) or k in ('RELM_EXAMPLE_MODEL','RELM_DEMO_MODEL'):env.pop(k)
 def stage(name,cmd,timeout=600):
  item=dict(name=name,command=cmd,status='running');state['stages'].append(item)
  state.update(status='running',stage=name);save()
  with (O/(name+'.log')).open('w') as log:
   p=subprocess.Popen(cmd,cwd=O,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
   item['pid']=p.pid;save()
   try:rc=p.wait(timeout=timeout)
   except subprocess.TimeoutExpired:
    os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=10);raise RuntimeError(name+' timeout')
  item.update(status='passed' if rc==0 else 'failed',exit_code=rc);save()
  assert rc==0,name+' failed; diagnose retained raw log'
 paths=[]
 for name in ('R','man','inst','vignettes','tests/testthat'):
  paths.extend(p for p in (R/'rebirth'/name).rglob('*') if p.is_file() and '/.quarto/' not in str(p) and '_files/' not in str(p))
 paths.extend(R/'rebirth'/name for name in ('DESCRIPTION','NAMESPACE','NEWS.md'))
 sources={str(p.relative_to(R)):sha(p) for p in sorted(paths)}
 (O/'source-manifest.json').write_text(json.dumps(sources,indent=2)+'\n')
 for name in ('contrast-directions','model-interventions'):
  shutil.copy2(R/'rebirth/vignettes'/f'{name}.qmd',O/f'{name}.qmd')
  stage('vignette-'+name,['quarto','render',f'{name}.qmd','--to','html'])
  raw=(O/f'vignette-{name}.log').read_text()
  assert not any(x in raw for x in ('Warning:','Error:','Execution halted')),name+' emitted diagnostics'
 stage('source-build',['R','CMD','build','--no-build-vignettes','--no-manual',str(R/'rebirth')])
 tar=list(O.glob('relm_*.tar.gz'));assert len(tar)==1
 with tarfile.open(tar[0]) as archive:
  for name in ('contrast-directions','model-interventions'):
   assert archive.extractfile(f'relm/vignettes/{name}.qmd').read()==(R/'rebirth/vignettes'/f'{name}.qmd').read_bytes()
 stage('scoped-check',['R','CMD','check','--no-install','--no-tests','--no-vignettes','--no-manual','--library='+str(B/'public-library-budget'),str(tar[0])])
 raw=(O/'relm.Rcheck/00check.log').read_text()
 warning_lines=[line for line in raw.splitlines() if line.startswith('* checking') and line.endswith('WARNING')]
 assert warning_lines==["* checking files in ‘vignettes’ ... WARNING","* checking package vignettes ... WARNING"],warning_lines
 assert 'Status: 2 WARNINGs' in raw and ' ERROR' not in raw and ' NOTE' not in raw
 assert "Directory 'inst/doc' does not exist." in raw and 'checking tests ... SKIPPED' in raw
 freeze()
 for p,h in sources.items():assert sha(R/p)==h,p
 (O/'manifest.json').write_text(json.dumps({str(p.relative_to(O)):sha(p) for p in O.rglob('*') if p.is_file() and p.name!='status.json'},indent=2)+'\n')
 state.update(status='awaiting_owner_verification',stage='complete',models=0,native_builds=0,
  scoped_check=dict(errors=0,warnings=2,notes=0,tests='not rerun',vignettes='Two changed documents rendered separately; omitted bundled-vignette warnings retained'))
 save()
try:main()
except Exception as e:
 O.mkdir(exist_ok=True);(O/'failure.txt').write_text(traceback.format_exc())
 state.update(status='failed',stage='diagnose_before_retry',error=str(e));save();raise
