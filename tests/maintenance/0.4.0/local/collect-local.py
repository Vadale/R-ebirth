from pathlib import Path
import csv, hashlib, json, shutil, subprocess

repo = Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
root = Path('/private/tmp/relm-maintenance-040')
run = root / 'builds-20261011-180737'
out = repo / 'tests/maintenance/0.4.0/local'
out.mkdir(parents=True, exist_ok=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
read = lambda p: json.loads(p.read_text())
source = read(run / 'source-manifest.json')
delta = [p for p, value in source.items() if sha(repo / p) != value]
assert delta == ['rebirth/R/extendr-wrappers.R'], delta
assert (repo / delta[0]).read_bytes() == (run / 'production/package/R/extendr-wrappers.R').read_bytes()
status = read(run / 'status.json')
assert status['status'] == 'failed' and status['stage'] == 'selftest-R'
for stage in status['stages']:
    assert sha(run / (stage['name'] + '.log')) == stage['log_sha256']
for mode, features in [('production', ['default', 'spill']), ('selftest', ['default', 'selftest', 'spill'])]:
    dest = run / mode
    binary = read(dest / 'binary.json')
    assert binary['artifact']['features'] == features and not binary['artifact']['fresh']
    assert sha(dest / 'relm.so') == binary['dll_sha256']
    for path, value in read(dest / 'installed-manifest.json').items():
        assert sha(dest / 'library/relm' / path) == value, path
    for line in (run / (mode + '-build.log')).read_text().splitlines():
        if line.startswith('{'):
            event = json.loads(line)
            assert not (event.get('reason') == 'compiler-message' and event['message']['level'] in ('warning', 'error'))
assert (run / 'production/compiled-profile.csv').read_bytes() == (run / 'selftest/compiled-profile.csv').read_bytes()
counts = list(csv.DictReader((root / 'combined-R-counts.csv').open()))
assert len(counts) == 443 and sum(int(r['passed']) for r in counts) == 6704
assert all(r['failed'] == '0' and r['error'] == 'FALSE' and r['warning'] == '0' for r in counts)
assert sum(r['skipped'] == 'TRUE' for r in counts) == 67
assert 'MAINTENANCE_PLATFORM_RESUME_OK cases=61 expectations=319' in (root / 'platform.log').read_text()
assert 'STATE_API_OK cases=24 model_calls=0' in (root / 'state-controls.log').read_text()
assert '9 passed; 0 failed; 0 ignored' in (root / 'ffi-unit.log').read_text()
assert all(s['status'] == 'passed' for s in read(root / 'final-local-status.json')['stages'])
assert 'MAINTENANCE_ROUTING_OK' in (root / 'routing.log').read_text()
closure = read(root / 'integrated-review-closure.json')
files = list(root.glob('*.log')) + list(root.glob('*.json')) + list(root.glob('*.py')) + list(root.glob('*.R'))
files += [root / 'combined-R-counts.csv', root / 'platform-results.rds', root / 'integrated-review.md', root / 'integrated-review-closure.md']
files += list(run.glob('*.log')) + list(run.glob('*.json')) + list(run.glob('*.patch'))
for mode in ('production', 'selftest'):
    files += [p for p in (run / mode).iterdir() if p.suffix in ('.json', '.csv', '.rds')]
files += [root / 'state-api/run.R', root / 'state-api/state_api_test.c']
for p in files:
    if p.exists():
        dst = out / p.relative_to(root)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, dst)
diagnostics = repo / 'rebirth/tests/testthat/_diagnostics'
if diagnostics.exists():
    shutil.move(str(diagnostics), str(out / 'original-test-diagnostics'))
receipt = {
 'status': 'passed', 'scope': 'Local maintenance corrections; release and numerical debt remain pending',
 'original_pipeline_status': 'failed; retained unchanged',
 'resumption': 'Only 61 named failures caused by unavailable sandbox Metal/sysctl access; same installed DLL, no rebuild',
 'R': {'cases': 443, 'expectations': 6704, 'skips': 67, 'failures': 0, 'errors': 0,
       'skip_scope': '66 optional model/network cases; one recording-machine VLM pin stopped first at sandbox CPU fingerprint. VLM environment was absent; no VLM acceptance claimed.'},
 'production_registration': {'cases': 6, 'expectations': 19, 'fixture_hooks': 0},
 'selftest_fixture_hooks': 12, 'C_controls': 24, 'FFI_unit_cases': 9,
 'source_inventory': len(source), 'post_build_delta': 'Generated production wrappers match the exact production DLL; no other inventoried code drift',
 'compiled_profile_fields_unchanged': 27,
 'production_dll': read(run / 'production/binary.json')['dll_sha256'],
 'selftest_dll': read(run / 'selftest/binary.json')['dll_sha256'],
 'version_scope': 'Local installed libraries still carry 0.3.0 metadata; version/docs change followed this execution. Not final 0.4.0 package acceptance.',
 'warnings': ['Standalone C control compilation: installed R Boolean.h unknown warning group', 'External testthat built under R 4.5.2; local R is 4.5.1'],
 'production_and_selftest_compiler_warnings': 0,
 'review': 'One integrated review; two findings closed in separate source-only closure',
 'not_executed': ['cached-Qwen/consumed efficacy replay', 'new ignored long-prefill diagnostic', 'final release package and distribution']
}
(out / 'owner.json').write_text(json.dumps(receipt, indent=2) + '\n')
(out / 'manifest.json').write_text(json.dumps({str(p.relative_to(out)): sha(p) for p in sorted(out.rglob('*')) if p.is_file() and p.name != 'manifest.json'}, indent=2) + '\n')
print(json.dumps({'archive': str(out), 'files': len(read(out / 'manifest.json')), 'manifest_sha256': sha(out / 'manifest.json')}))
