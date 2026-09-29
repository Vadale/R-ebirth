"""Packaging-only follow-up: reuse verified compiled code, preserve check scope."""
import hashlib, json, os, shutil, subprocess, tarfile, time, traceback
from pathlib import Path

base = Path('/private/tmp/relm-release-0.3.0')
root = base/'package-final'
repo = Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
root.mkdir(exist_ok=False)
status = {'status': 'running', 'pid': os.getpid(), 'stages': [], 'started_at': time.time(),
          'scope': 'Packaging-only rebuild with existing built vignettes; no-install check reuses corrected full-check library. Rust installation warning remains recorded in corrected-as-cran.log.'}

def save():
    temp = root/'status.tmp'
    temp.write_text(json.dumps(status, indent=2)+'\n')
    temp.replace(root/'status.json')

def digest(data): return hashlib.sha256(data).hexdigest()

def archive(path):
    with tarfile.open(path) as tar:
        return {m.name: digest(tar.extractfile(m).read()) for m in tar.getmembers() if m.isfile()}

def run(name, command):
    status['stage'] = name
    item = {'name':name, 'command':command, 'status':'running', 'started_at':time.time()}
    status['stages'].append(item);save()
    env = os.environ.copy()
    env['PATH'] = str(base/'tools')+':/private/tmp/relm-maintenance-2026-09-27/quarto/bin:'+env.get('PATH','')
    env['R_LIBS'] = ':'.join([str(base/'packaging-corrected/check/relm.Rcheck'),
                            '/private/tmp/relm-service/library', '/private/tmp/relm-maintenance-2026-09-27/R-library',
                            '/Users/alessandrovadala/Library/R/arm64/4.5/library'])
    env.pop('NOT_CRAN', None)
    for key in list(env):
        if key.startswith(('RELM_TEST_MODEL_', 'RELM_DEMO_')):env.pop(key)
    with (root/(name+'.log')).open('w') as log:
        result = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    item.update(status='passed' if result.returncode==0 else 'failed', exit_code=result.returncode, finished_at=time.time());save()
    if result.returncode:raise RuntimeError(name+' failed')

try:
    save()
    source = base/'packaging-corrected/relm_0.3.0.tar.gz'
    with tarfile.open(source) as tar:
        for member in tar.getmembers():
            assert Path(member.name).parts[0]=='relm' and '..' not in Path(member.name).parts
        tar.extractall(root, filter='data')
    shutil.copyfile(repo/'rebirth/.Rbuildignore',root/'relm/.Rbuildignore')
    run('build', ['R','CMD','build','--no-build-vignettes',str(root/'relm')])
    final = root/'relm_0.3.0.tar.gz'
    old, new = archive(source), archive(final)
    added = sorted(new.keys()-old.keys())
    removed = sorted(old.keys()-new.keys())
    changed = sorted(k for k in old.keys()&new.keys() if old[k]!=new[k])
    assert not added, added
    assert all(k.startswith('relm/vignettes/.quarto/') or k=='relm/vignettes/.gitignore' for k in removed), removed
    assert set(changed)<= {'relm/DESCRIPTION','relm/build/vignette.rds'}, changed
    assert not any('/.quarto/' in k or k.endswith('/_pkgdown.yml') for k in new)
    status['source_tarball_sha256'] = digest(final.read_bytes())
    status['comparison'] = {'parent_tarball_sha256':digest(source.read_bytes()), 'added':added,'removed':removed,'changed':changed,
                            'all_R_native_test_and_example_payloads_unchanged':True,
                            'file_manifest_sha256':digest(json.dumps(new,sort_keys=True).encode())}
    (root/'manifest.json').write_text(json.dumps(new,sort_keys=True,indent=2)+'\n')
    save()
    (root/'check').mkdir()
    run('check', ['R','CMD','check','--as-cran','--no-install','--library='+str(base/'packaging-corrected/check/relm.Rcheck'),
                 '--output='+str(root/'check'),str(final)])
    status['status']='completed'
    status['acceptance']='Review warnings/notes; no-install is not a new native installation or clean CRAN claim.'
except Exception as error:
    status.update(status='failed', error=str(error))
    (root/'error.log').write_text(traceback.format_exc())
finally:
    status['finished_at']=time.time();save()
