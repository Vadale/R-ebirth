from pathlib import Path
import ast,json,hashlib,subprocess,os,shutil
root=Path('/private/tmp/relm-f6e');parent=root/'installed-review-20261008-151124';sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
original=root/'run-installed-review.py';driver=root/'run-installed-review-resume.py';s=original.read_text()
s=s.replace("ROOT/'installed-review-binding.json'","ROOT/'installed-review-resume-binding.json'")
s=s.replace("run=ROOT/('installed-review-'+time.strftime", "run=ROOT/('installed-review-resume-'+time.strftime")
s=s.replace("lib=ROOT/'public-library-review';lib.mkdir(exist_ok=True);assert not (lib/'relm').exists()", "lib=ROOT/'public-library-review';assert (lib/'relm').is_dir()\n for p,h in bind['parent_installed'].items():assert sha(lib/'relm'/p)==h,p")
s=s.replace("env['R_LIBS']=':'.join", "env['R_LIBS_USER']=str(lib);env['R_LIBS']=':'.join")
a=s.index("  package=run/'package-source'");b=s.index("  config=dict(bind['config'])",a)
code="library(relm);stopifnot(normalizePath(find.package('relm'))==normalizePath('/private/tmp/relm-f6e/public-library-review/relm'));stopifnot(requireNamespace('later',quietly=TRUE),requireNamespace('promises',quietly=TRUE));stopifnot(utils::packageVersion('later')=='1.4.8',utils::packageVersion('promises')=='1.5.0');for(p in c('later','promises')) stopifnot(normalizePath(getNamespaceInfo(p,'path'))==normalizePath(file.path('/Users/alessandrovadala/Library/R/arm64/4.5/library',p)));codetools::checkUsagePackage('relm');cat('F6E_INSTALLED_REVIEW_RUNTIME dependencies=2 usage=ok',intToUtf8(10L),sep='')"
s=s[:a]+"  installed=dict(bind['parent_installed'])\n  assert sha(lib/'relm/libs/relm.so')==sha(native)\n  (run/'installed-manifest.json').write_text(json.dumps(installed,indent=2)+'\\n')\n  (run/'carried-install.json').write_text(json.dumps(bind['parent_acceptance'],indent=2)+'\\n')\n  code="+repr(code)+"\n  text=stage('runtime-preflight',['/usr/local/bin/Rscript','--vanilla','-e',code]);assert text.strip()=='F6E_INSTALLED_REVIEW_RUNTIME dependencies=2 usage=ok'\n"+s[b:]
s=s.replace("['Rscript','--vanilla',str(REPO/'tests/projection/installed_review.R')", "['/usr/local/bin/Rscript','--vanilla',str(REPO/'tests/projection/installed_review.R')")
ast.parse(s);driver.write_text(s)
bind=json.loads((root/'installed-review-binding.json').read_text());bind['files'].pop(str(original));bind['files'][str(driver)]=sha(driver)
for path in [parent/'owner-failure-verification.json',parent/'status.json',parent/'install.log',parent/'installed-source.log',parent/'source-manifest.json',parent/'installed-manifest.json']:bind['files'][str(path)]=sha(path)
bind['source_hashes']=json.loads((parent/'source-manifest.json').read_text());bind['parent_installed']=json.loads((parent/'installed-manifest.json').read_text());bind['parent_acceptance']={'directory':str(parent),'status':'whole_run_failed_before_model','carried':'Fresh installation and function body/formals assertions before the failed dependency metadata check; no reinstall or source loop replay','source_manifest_sha256':sha(parent/'source-manifest.json'),'installed_manifest_sha256':sha(parent/'installed-manifest.json')}
# Do not copy parent status/manifest using colliding basenames into new run state.
s=driver.read_text().replace("for p in bind['files']:shutil.copy2(p,run/Path(p).name)","for p in bind['files']:\n   target=run/'bound-inputs'/Path(p).name;target.parent.mkdir(exist_ok=True);shutil.copy2(p,target)")
ast.parse(s);driver.write_text(s);bind['files'][str(driver)]=sha(driver)
(root/'installed-review-resume-binding.json').write_text(json.dumps(bind,indent=2)+'\n')
for path,h in {**bind['files'],**bind['external_files'],**bind['dependency_files']}.items():assert sha(path)==h,path
for path,h in bind['source_hashes'].items():assert sha(Path.cwd()/path)==h,path
for path,h in bind['parent_installed'].items():assert sha(root/'public-library-review/relm'/path)==h,path
# Execute only the previously unexecuted dependency/codetools preflight, with no model.
e=os.environ.copy();e.update(R_LIBS='/private/tmp/relm-f6e/public-library-review:/private/tmp/relm-service/library:/Users/alessandrovadala/Library/R/arm64/4.5/library',R_LIBS_USER='/private/tmp/relm-f6e/public-library-review')
p=subprocess.run(['/usr/local/bin/Rscript','--vanilla','-e',code],env=e,capture_output=True,text=True);assert p.returncode==0 and not p.stderr and p.stdout=='F6E_INSTALLED_REVIEW_RUNTIME dependencies=2 usage=ok\n',(p.returncode,p.stdout,p.stderr)
# Carry this preflight into the detached run, rather than executing it twice.
preflight=root/'installed-review-runtime-preflight.log';preflight.write_text(p.stdout)
bind['files'][str(preflight)]=sha(preflight)
s=driver.read_text().replace("text=stage('runtime-preflight',['/usr/local/bin/Rscript','--vanilla','-e',code]);assert text.strip()=='F6E_INSTALLED_REVIEW_RUNTIME dependencies=2 usage=ok'", "shutil.copy2(ROOT/'installed-review-runtime-preflight.log',run/'runtime-preflight-carried.log')\n  st['runtime_preflight_carried']=True;save()")
ast.parse(s);driver.write_text(s);bind['files'][str(driver)]=sha(driver);(root/'installed-review-resume-binding.json').write_text(json.dumps(bind,indent=2)+'\n')
prep=Path('tests/projection/measurements/installed-review-resume-preflight-20261008');prep.mkdir()
for path in [Path(__file__),driver,root/'installed-review-resume-binding.json',preflight]:shutil.copy2(path,prep/path.name)
record={'status':'passed','driver_sha256':sha(driver),'binding_sha256':sha(root/'installed-review-resume-binding.json'),'source_hashes':len(bind['source_hashes']),'installed_hashes':len(bind['parent_installed']),'dependencies':998,'models':0,'preflight_output':p.stdout,'scope':'Only dependency namespace/version resolution and previously unrun codetools. Fresh install and body/formals loop carried; external binary and dependency hashes unchanged. No product/harness R edits.'}
(prep/'preflight.json').write_text(json.dumps(record,indent=2)+'\n');(prep/'manifest.json').write_text(json.dumps({str(p.relative_to(prep)):sha(p) for p in prep.rglob('*') if p.is_file()},indent=2)+'\n');print(json.dumps(record,indent=2))
