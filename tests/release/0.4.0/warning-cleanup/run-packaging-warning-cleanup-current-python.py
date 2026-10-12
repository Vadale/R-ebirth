"""Build the warning-corrected production package once; carry rendered documents."""
import hashlib, json, os, shutil, subprocess, tarfile, time, traceback
from pathlib import Path
REPO = Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
BASE = Path('/private/tmp/relm-release-0.4.0')
ROOT = BASE / 'packaging-warning-cleanup-current-python'
PARENT = BASE / 'packaging-r-path'
TOOLS = BASE / 'warning-cleanup/tools-library'
CARGO = ROOT / 'cargo-home'
QUARTO = '/Applications/RStudio.app/Contents/Resources/app/quarto/bin'
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def inventory(root):
    return {str(p.relative_to(root)):sha(p) for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink()}
def tar_hashes(path):
    with tarfile.open(path) as t:
        return {m.name:hashlib.sha256(t.extractfile(m).read()).hexdigest() for m in t.getmembers() if m.isfile()}
def main():
    ROOT.mkdir(exist_ok=False)
    state = dict(status='running',pid=os.getpid(),started_at=time.time(),stages=[],
        scope='Affected production rebuild/check for compiler directives and C++ linking; carried six rendered vignettes and parent site/RStudio scopes. Optional model environments cleared, committed synthetic package tests execute.')
    def save():
        data=json.dumps(state,indent=2)+'\n'; tmp=BASE/'warning-cleanup-status.tmp';tmp.write_text(data);tmp.replace(BASE/'warning-cleanup-status.json');(ROOT/'status.json').write_text(data)
    env=os.environ.copy()
    for k in list(env):
        if k.startswith(('RELM_TEST_MODEL_','RELM_DEMO_')) or k in ['DEBUG','NOT_CRAN','RUSTFLAGS','RUSTC_WRAPPER','RELM_PROJECTION_SOURCE_SHA']:
            env.pop(k)
    env.update(RELM_ENABLE_SELFTESTS='0',CARGO_NET_OFFLINE='true',QUARTO_PATH=QUARTO+'/quarto',RSTUDIO_PANDOC=QUARTO+'/tools/aarch64',
        PATH='/opt/homebrew/bin:'+QUARTO+':'+env['PATH'],R_LIBS=':'.join([str(ROOT/'library'),str(TOOLS),'/Users/alessandrovadala/Library/R/arm64/4.5/library','/private/tmp/relm-service/library']),
        MAKEFLAGS='CARGOTMP='+str(CARGO))
    def run(name,args,required=True):
        item=dict(name=name,command=args,status='running',started_at=time.time());state['stages'].append(item);state['stage']=name;save()
        with (ROOT/(name+'.log')).open('w') as log:
            result=subprocess.run(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=7200)
        item.update(status='passed' if result.returncode==0 else 'failed',exit_code=result.returncode,finished_at=time.time(),log_sha256=sha(ROOT/(name+'.log')));save()
        if result.returncode and required: raise RuntimeError(name+' failed; inspect retained output before correction')
        return result.returncode
    try:
        save()
        binding=json.loads((BASE/'warning-cleanup-binding.json').read_text())
        assert sha(__file__)==binding['driver_sha256']
        assert all(sha(REPO/n)==h for n,h in binding['repo_inputs'].items()), 'Repository input drift'
        assert inventory(TOOLS)==binding['tool_library'], 'Tool library drift'
        assert all(sha(p)==h for p,h in binding['tool_executables'].items()), 'Tool executable drift'
        assert sha(BASE/'check-release-installed.R')==binding['installed_recipe_sha256']
        parent_tar=PARENT/'relm_0.4.0.tar.gz';assert sha(parent_tar)==binding['parent_tar_sha256']
        state['binding_sha256']=sha(BASE/'warning-cleanup-binding.json')
        state['source_head']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip()
        state['source_tree']='Dirty source plus exact input inventory; not a clean-tree claim.'
        with tarfile.open(parent_tar) as t: t.extractall(ROOT,filter='data')
        stage=ROOT/'relm'
        for name in binding['overlay']:
            dest=stage/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(REPO/'rebirth'/name,dest)
        for name in ['.Rbuildignore','_pkgdown.yml']:shutil.copy2(REPO/'rebirth'/name,stage/name)
        sources=inventory(stage);(ROOT/'source-manifest.json').write_text(json.dumps(sources,indent=2)+'\n')
        state['source_manifest_sha256']=sha(ROOT/'source-manifest.json');state['source_files']=len(sources);save()
        run('build-carried-vignettes',['/usr/local/bin/R','CMD','build','--no-build-vignettes',str(stage)])
        source=ROOT/'relm_0.4.0.tar.gz'; old,new=tar_hashes(parent_tar),tar_hashes(source)
        added=set(new)-set(old);removed=set(old)-set(new)
        assert not removed and added=={'relm/src/llama.cpp/patches/0005-compiler-diagnostics.diff'},(added,removed)
        changed=[n for n in old if new[n]!=old[n]]
        assert set(changed)<=set('relm/'+x for x in binding['overlay'])|{'relm/DESCRIPTION','relm/build/vignette.rds'},changed
        assert all(old[n]==new[n] for n in old if n.startswith('relm/inst/doc/'))
        for name in binding['overlay']: assert new['relm/'+name]==sha(REPO/'rebirth'/name),name
        state['tar_comparison']=dict(parent_sha256=sha(parent_tar),files=len(new),changed=changed,added=sorted(added),carried_vignette_files=sum(n.startswith('relm/inst/doc/') for n in old));state['source_tarball_sha256']=sha(source);save()
        (ROOT/'check').mkdir();CARGO.mkdir()
        subprocess.run(['/bin/cp','-cR','/Users/alessandrovadala/.cargo/registry',str(CARGO/'registry')],check=True)
        code=run('check',['/usr/local/bin/R','CMD','check','--as-cran','--install-args=--build','--output='+str(ROOT/'check'),str(source)],required=False)
        if code: raise RuntimeError('Package check failed; preserve native build and completed stages before resuming')
        bins=list(ROOT.rglob('relm_0.4.0.tgz'));assert len(bins)==1,[str(x) for x in bins]
        binary=bins[0];state['binary_path']=str(binary);state['binary_sha256']=sha(binary);save()
        (ROOT/'library').mkdir()
        run('install',['/usr/local/bin/R','CMD','INSTALL','--library='+str(ROOT/'library'),str(binary)])
        run('installed-production',['/usr/local/bin/Rscript','--vanilla',str(BASE/'check-release-installed.R'),str(ROOT/'library/relm'),str(stage),str(ROOT)])
        (ROOT/'installed-manifest.json').write_text(json.dumps(inventory(ROOT/'library/relm'),indent=2)+'\n')
        assert not {n:sha(stage/n) for n,h in sources.items() if sha(stage/n)!=h},'Staged source drift'
        assert all(sha(REPO/n)==h for n,h in binding['repo_inputs'].items()), 'Repository input drift'
        assert inventory(TOOLS)==binding['tool_library'],'Tool library drift'
        state['status']='awaiting_owner_verification';state['acceptance']='Inspect actual warnings/notes, source/archive/installed provenance; stage success is not release acceptance.'
    except Exception as e:
        state.update(status='failed',error=str(e));(ROOT/'error.log').write_text(traceback.format_exc())
    finally:
        state['finished_at']=time.time();save()
if __name__=='__main__':main()
