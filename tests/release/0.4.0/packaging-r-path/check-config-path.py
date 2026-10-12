"""Exercise the real build script against R CMD check's actual PATH guard."""
import hashlib,json,os,subprocess
from pathlib import Path
base=Path('/private/tmp/relm-release-0.4.0/r-config-fix')
crate=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth/rebirth/src/rust/rebirth-ffi')
guard=Path('/private/tmp/relm-release-0.4.0/packaging/check/relm.Rcheck/R_check_bin')
rhome=subprocess.check_output(['/usr/local/bin/R','RHOME'],text=True).strip()
results=[]
for version,source in [('original',base/'build-original.rs'),('corrected',crate/'build.rs')]:
 executable=base/(version+'-build-script')
 p=subprocess.run(['rustc','--edition=2021',str(source),'-o',str(executable)],capture_output=True,text=True)
 (base/(version+'-rustc.log')).write_text(p.stdout+p.stderr)
 assert p.returncode==0
 modes=['hosted-shadow'] if version=='original' else ['hosted-shadow','standalone-path']
 for mode in modes:
  out=base/(version+'-'+mode);out.mkdir(exist_ok=False)
  env=os.environ.copy();env['OUT_DIR']=str(out)
  if mode=='hosted-shadow':
   env['R_HOME']=rhome;env['PATH']=str(guard)+':'+env['PATH']
  else:env.pop('R_HOME',None)
  result=subprocess.run([str(executable)],cwd=crate,env=env,capture_output=True,text=True)
  (out/'output.log').write_text(result.stdout+result.stderr)
  expected=version!='original'
  assert (result.returncode==0)==expected, result.stderr
  if not expected: assert "'R' should not be used without a path" in (guard/'R').read_text()
  else: assert (out/'projection_state.o').is_file() and (out/'librelm-r-state.a').is_file()
  results.append(dict(version=version,mode=mode,exit_code=result.returncode,expected_success=expected,
   source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
   output_sha256=hashlib.sha256((out/'output.log').read_bytes()).hexdigest()))
a=(base/'corrected-hosted-shadow/projection_state.o').read_bytes()
b=(base/'corrected-standalone-path/projection_state.o').read_bytes()
assert a==b
receipt=dict(status='passed',r_home=rhome,guard_sha256=hashlib.sha256((guard/'R').read_bytes()).hexdigest(),
 results=results,compiled_object_sha256=hashlib.sha256(a).hexdigest(),model_calls=0,
 scope='Original expected rejection plus corrected real host-path and standalone compiler invocation; identical C object bytes.')
(base/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
