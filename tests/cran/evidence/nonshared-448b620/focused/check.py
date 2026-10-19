from pathlib import Path
import hashlib,json,os,shutil,subprocess,tarfile
repo=Path.cwd(); out=Path(__file__).parent
ffi=repo/'rebirth/src/rust/rebirth-ffi'
records=[]
def run(name,cmd,env=None,cwd=ffi,success=True):
 p=subprocess.run(cmd,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 (out/(name+'.stdout')).write_bytes(p.stdout);(out/(name+'.stderr')).write_bytes(p.stderr)
 records.append(dict(name=name,command=[str(x) for x in cmd],returncode=p.returncode))
 assert (p.returncode==0)==success,(name,p.stderr[-2000:])
 return p
base=os.environ.copy()
for k in ['R_HOME','R_INCLUDE_DIR','R_ARCH','R_LIBS','R_LIBS_USER','RUSTFLAGS']: base.pop(k,None)
include=Path(run('include-query',['Rscript','--vanilla','-e',"cat(R.home('include'))"],base).stdout.decode())
rhome=out/'rhost'; (rhome/'bin').mkdir(parents=True);(rhome/'etc').mkdir();(rhome/'share/make').mkdir(parents=True)
with tarfile.open('/home/grauk/Work/relm-phase9/r-hosted-wrappers/R-4.6.1.tar.gz') as t:
 for source,dest in [('src/scripts/config','bin/config'),('share/make/config.mk','share/make/config.mk')]:
  (rhome/dest).write_bytes(t.extractfile('R-4.6.1/'+source).read())
(rhome/'bin/R').write_text('#!/bin/sh\n[ "$1" = CMD ] && [ "$2" = config ] || exit 90\nshift 2\nexec /bin/sh "$R_HOME/bin/config" "$@"\n');(rhome/'bin/R').chmod(0o755)
old=out/'original.rs'; old.write_bytes(subprocess.check_output(['git','show','HEAD:rebirth/src/rust/rebirth-ffi/build.rs']))
new=out/'current.rs';shutil.copyfile(ffi/'build.rs',new)
for name,path in [('original',old),('current',new)]:run(name+'-compile',['rustc','--edition=2021','-Dwarnings',path,'-o',out/name])
env=base.copy();env.update(R_HOME=str(rhome),R_INCLUDE_DIR=str(include),R_SHARE_DIR=str(rhome/'share'),MAKE='make',RELM_R_PORTABLE='1',CC='gcc',CFLAGS='-O2 -fPIC -Werror')
for library in ['shared','nonshared']:
 (rhome/'etc/Makeconf').write_text('CC = gcc\nLIBR = '+('-lR' if library=='shared' else '')+'\nSTATIC_LIBR =\n')
 flags=run(library+'-cppflags',[rhome/'bin/R','CMD','config','--cppflags'],env)
 assert (bool(flags.stdout.strip()))==(library=='shared')
 if library=='nonshared': assert b'R was not built as a library' in flags.stderr
 for variant in ['original','current']:
  dest=out/(library+'-'+variant);dest.mkdir()
  e=env.copy();e['OUT_DIR']=str(dest)
  r=run(library+'-'+variant,[out/variant],e,success=not(library=='nonshared' and variant=='original'))
  if r.returncode: assert b'Rinternals.h: No such file or directory' in r.stderr
# Shared and nonshared cases produce identical C object bytes, not linked engines.
objects=[out/(name)/'projection_state.o' for name in ['shared-original','shared-current','nonshared-current']]
assert len({hashlib.sha256(p.read_bytes()).hexdigest() for p in objects})==1
# Standalone cargo discovery uses real R, without installation variables.
dest=out/'standalone';dest.mkdir();e=base.copy();e['OUT_DIR']=str(dest)
run('standalone',[out/'current'],e)
# Pass hostile-looking include paths as data, retain a subarchitecture search path.
special=out/"headers with spaces owner's $literal";special.symlink_to(include,target_is_directory=True)
dest=out/'special-arch';dest.mkdir();e=env.copy();e.update(OUT_DIR=str(dest),R_INCLUDE_DIR=str(special),R_ARCH='/x64')
run('special-arch',[out/'current'],e)
dest=out/'missing';dest.mkdir();e=env.copy();e.update(OUT_DIR=str(dest),R_INCLUDE_DIR=str(out/'missing-headers'))
r=run('missing-header-refusal',[out/'current'],e,success=False);assert b'R headers missing' in r.stderr and not list(dest.iterdir())
(out/'records.json').write_text(json.dumps(records,indent=2)+'\n')
(out/'result.json').write_text(json.dumps(dict(status='passed',old_nonshared_rejected=True,new_compiles=4,object_sha256=hashlib.sha256(objects[0].read_bytes()).hexdigest(),actual_c_source_sha256=hashlib.sha256((ffi/'native/projection_state.c').read_bytes()).hexdigest(),native_engine_builds=0,model_calls=0,scope='Exact official R config behavior plus actual accessor compilation; hosted full nonshared installation pending'),indent=2)+'\n')
print((out/'result.json').read_text())
