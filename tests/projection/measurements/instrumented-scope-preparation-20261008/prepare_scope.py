"""One explicit local source-hash revision; never builds or executes product code."""
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[4]
ARCHIVE = Path(__file__).resolve().parent
TMP = Path('/private/tmp/relm-f6e')
SCOPE = ROOT / 'tests/projection/instrumented-scope.json'
READY = TMP / 'instrumented-ready.json'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
write = lambda p, x: p.write_text(json.dumps(x, indent=2, sort_keys=True) + '\n')
assert sha(SCOPE) == 'f54771e80fef090551a4dfc39c2cfff6294f66500f34f0c9a3972bf620f3c3c2'
assert sha(READY) == 'f8e47ce0f90e36cd06d1723f7741ed443f696b7462dc5acc9b065182cd4a5937'
original = json.loads(SCOPE.read_text())
ready = json.loads(READY.read_text())
assert len(original['source_hashes']) == 858
# Preserve original bytes before changing either live receipt.
shutil.copyfile(SCOPE, ARCHIVE / 'original-instrumented-scope.json')
shutil.copyfile(READY, ARCHIVE / 'original-instrumented-ready.json')
original_ready_hash = sha(READY)
original_scope_hash = sha(SCOPE)

receipts = {
    'budget': ('budget-class-20261008-104809', '8e8cbead752c46f5b2f3ccc97de9ca96619ee40787501a329ebea343ad01f941'),
    'installed': ('installed-public-budget-20261008-105355', '534785f188b08bcb39ac143f48002ebe41d6e9e6394df81c199ace5dffaf85db'),
}
accepted = {}
for name, (directory, expected) in receipts.items():
    base = TMP / directory
    manifest = base / 'source-manifest.json'
    owner = base / 'owner-verification.json'
    assert sha(manifest) == expected
    verification = json.loads(owner.read_text())
    assert verification['status'] == 'PASS' and verification['source_manifest_sha256'] == expected
    sources = json.loads(manifest.read_text())
    for path, digest in sources.items():
        assert sha(ROOT / path) == digest, ('accepted source drift', name, path)
    accepted[name] = sources
    shutil.copyfile(manifest, ARCHIVE / f'{name}-source-manifest.json')
    shutil.copyfile(owner, ARCHIVE / f'{name}-owner-verification.json')

collector = ROOT / 'tests/projection/measurements/instrumented-collector-20261008'
collector_owner = json.loads((collector / 'owner-verification.json').read_text())
assert collector_owner['status'] == 'passed' and collector_owner['tests'] == 40
for p in ['tests/projection/instrumented.py', 'tests/projection/instrumented_controls.py',
          'tests/projection/instrumented_memcheck_probe.c', 'tests/sanitizers/run.py']:
    assert sha(ROOT / p) == collector_owner['source_hashes'][p]
shutil.copyfile(collector / 'owner-verification.json', ARCHIVE / 'collector-owner-verification.json')
shutil.copyfile(collector / 'workflow-check.json', ARCHIVE / 'workflow-check.json')
workflow_path = '.github/workflows/nightly-memory-safety.yaml'
workflow_hash = sha(ROOT / workflow_path)
assert workflow_hash == sha(collector / 'workflow.yaml') == '9aebbaa8343e7a7e3cdd9ae86fee17163a3e813f4b82b451c2104b154eb5056a'
shutil.copyfile(ROOT / workflow_path, ARCHIVE / 'current-workflow.yaml')

updated = {}
changes = []
for path, prior in original['source_hashes'].items():
    actual = sha(ROOT / path)
    updated[path] = actual
    if actual != prior:
        assert path in accepted['budget'] and accepted['budget'][path] == actual
        before = TMP / 'budget-class-original' / path
        assert sha(before) == prior
        target = ARCHIVE / 'original-changed-sources' / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(before, target)
        target = ARCHIVE / 'current-changed-sources' / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, target)
        difference = ''.join(difflib.unified_diff(before.read_text().splitlines(keepends=True),
            (ROOT / path).read_text().splitlines(keepends=True), fromfile=path+' (original scope)', tofile=path+' (accepted budget correction)'))
        (ARCHIVE / (Path(path).name+'.diff')).write_text(difference)
        changes.append({'path': path, 'previous_sha256': prior, 'current_sha256': actual,
                        'acceptance': receipts['budget'][1],
                        'reason': 'bounded over-budget OOM class' if path.endswith('projection_profile.rs') else 'focused model-free OOM class/capacity regression'})
assert {x['path'] for x in changes} == {
    'rebirth/src/rust/rebirth-llm/src/projection_profile.rs',
    'rebirth/src/rust/rebirth-llm/src/projection_profile_tests.rs'}

selected = {}
for path in ['rebirth/src/rust/rebirth-llm/tests/projection_production.rs',
             'rebirth/src/rust/rebirth-llm/src/projection_production_worker_tests.rs']:
    value = sha(ROOT/path)
    assert value == original['source_hashes'][path] == accepted['installed'][path]
    selected[path] = value

vendor = {p: h for p,h in original['source_hashes'].items() if p.startswith('rebirth/src/llama.cpp/')}
current_vendor = {p.relative_to(ROOT).as_posix() for p in (ROOT/'rebirth/src/llama.cpp').rglob('*') if p.is_file() and '.git' not in p.parts}
assert current_vendor == set(vendor)
assert all(sha(ROOT/p) == h for p,h in vendor.items())

# Hash committed reference bytes directly. No producer/check command is executed.
fixture_roots = ['tests/llm-golden/projection', 'tests/llm-golden/live-state/f6b']
entries = subprocess.check_output(['git', 'ls-tree', '-r', '-z', 'd8a4800', '--', *fixture_roots], cwd=ROOT).split(b'\0')
fixtures = {}
for entry in entries:
    if not entry: continue
    meta, name = entry.split(b'\t',1)
    mode, kind, oid = meta.decode().split()
    assert kind == 'blob' and mode in ('100644', '100755')
    path = name.decode()
    expected = hashlib.sha256(subprocess.check_output(['git', 'cat-file', 'blob', oid], cwd=ROOT)).hexdigest()
    assert sha(ROOT/path) == expected, ('frozen fixture drift', path)
    fixtures[path] = expected
current_fixtures = {p.relative_to(ROOT).as_posix() for folder in fixture_roots
                    for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts}
assert current_fixtures == set(fixtures), ('fixture path drift', current_fixtures ^ set(fixtures))
assert sum(p.startswith('tests/llm-golden/projection/') for p in fixtures) == 49
assert fixtures['tests/llm-golden/projection/goldens/manifest.csv'] == '78729e5fe710e30dffa83e76a9d084ee15091a0ef7074230172c3293f2463959'
assert fixtures['tests/llm-golden/projection/goldens/manifest.json'] == 'ab9e0361b5237bd89901854225f430a8492704cab8607c8ddc9b55dc9c7769b6'
write(ARCHIVE/'frozen-reference-hashes.json', fixtures)

# Generated Mac Makevars is accepted local linking context, not a Linux source.
# It is deliberately archived but cannot be mandatory in a fresh Linux checkout.
local_only = {'rebirth/src/Makevars': accepted['installed']['rebirth/src/Makevars']}
shutil.copyfile(ROOT/'rebirth/src/Makevars', ARCHIVE/'accepted-local-Makevars')
additions = []
new_sources = {**accepted['budget'], **accepted['installed'], **fixtures, workflow_path: workflow_hash}
for path, value in sorted(new_sources.items()):
    if path in local_only: continue
    if path not in updated:
        origin = ('frozen independent reference d8a4800' if path in fixtures else
                  'parent verified workflow route' if path == workflow_path else
                  'installed-public accepted source' if path in accepted['installed'] else 'budget-class accepted source')
        additions.append({'path': path, 'current_sha256': value, 'previous_status': 'not bound by original858 scope', 'origin': origin})
    else:
        assert updated[path] == value
    updated[path] = value

revision = {
    'status': 'source_preparation_verified_not_instrumented_acceptance',
    'revision': 2,
    'original_count': 858, 'current_count': len(updated),
    'changed_existing_count': len(changes), 'unchanged_existing_count': 858-len(changes),
    'added_source_bindings_count': len(additions), 'removed_source_bindings': [],
    'changed_existing': changes, 'added_source_bindings': additions,
    'selected_production_files_byte_identical': selected,
    'vendor_files_byte_identical': len(vendor),
    'frozen_reference_files_byte_identical': len(fixtures),
    'reference_commit': 'd8a4800', 'reference_hash_file': 'frozen-reference-hashes.json',
    'accepted_budget_manifest': receipts['budget'][1], 'accepted_installed_manifest': receipts['installed'][1],
    'accepted_budget_source_files_verified': len(accepted['budget']),
    'accepted_installed_source_files_verified': len(accepted['installed']),
    'workflow': {'path': workflow_path, 'sha256': workflow_hash,
        'previous_sha256': ready['existing_workflow_unchanged_sha256'],
        'parent_route': 'projection-only, two exact default-production tests in ASan/UBSan and separate Memcheck; full remains scheduled default',
        'retained_parent_receipt': 'tests/projection/measurements/instrumented-collector-20261008/workflow-check.json'},
    'local_only_context_not_required_on_linux': local_only,
    'executed_by_agent': 'hash/source preparation only; no builds/tests/models/remote calls',
    'scope_limit': 'R/FFI sources are provenance context; Linux driver builds only rebirth-llm, no R/SEXP acceptance claim',
}
write(ARCHIVE/'revision-verification.json', revision)
next_scope = dict(original)
next_scope.update({'revision': 2, 'source_hashes': dict(sorted(updated.items())),
    'previous_scope': {'sha256': original_scope_hash, 'source_count': 858,
        'archive': str((ARCHIVE/'original-instrumented-scope.json').relative_to(ROOT))},
    'accepted_production_source_hashes_scope': 'Historical original18ebedbb source; projection_profile.rs is superseded only by the explicitly recorded accepted budget correction. See source_hashes for current binding.',
    'current_accepted_manifests': {k:v[1] for k,v in receipts.items()},
    'workflow_binding': revision['workflow'],
    'revision_verification': {'path': str((ARCHIVE/'revision-verification.json').relative_to(ROOT)), 'sha256': sha(ARCHIVE/'revision-verification.json')},
    'nonexecuted_context': 'Added R/FFI/source-doc hashes bind the installed source, not an instrumentation claim for those surfaces.'})
write(SCOPE, next_scope)
shutil.copyfile(SCOPE, ARCHIVE/'revised-instrumented-scope.json')
ready.update({'status':'ready','frozen':True,'revision':2,
    'scope':'Explicit source-scope revision after accepted OOM correction and installed public continuation; no instrumentation execution',
    'bound_source_count':len(updated), 'original_ready_sha256':original_ready_hash,
    'original_scope_sha256':original_scope_hash,'native_scope_sha256':sha(SCOPE),
    'preparation_archive':str(ARCHIVE.relative_to(ROOT)),
    'revision_verification_sha256':sha(ARCHIVE/'revision-verification.json'),
    'source_deltas':changes,'added_source_bindings_count':len(additions),
    'selected_production_test_sources_unchanged':selected,
    'accepted_production_sources_unchanged':{p:h for p,h in original['accepted_production_source_hashes'].items() if p not in {x['path'] for x in changes}},
    'historical_production_source_superseded':['rebirth/src/rust/rebirth-llm/src/projection_profile.rs'],
    'accepted_current_source_manifests':{k:v[1] for k,v in receipts.items()},
    'current_workflow_binding':revision['workflow'],
    'workflow_patch':'Parent applied and verified projection-only route; current bytes bound in revised source scope. Agent made no workflow edits.',
    'carried_model_free_controls':{'tests':40,'owner_receipt':str((collector/'owner-verification.json').relative_to(ROOT)), 'owner_receipt_sha256':sha(collector/'owner-verification.json'),'driver_and_controls_unchanged':True},
    'static_checks':['all858 original hashes compared:856unchanged+2acceptedchanges','all117 budget and145 installed source hashes match current','two selected test files byte-identical','vendor path/hash set unchanged','58frozen reference files byte-identical tod8a4800','workflow matches parent retained bytes'],
    'unrun':['Linuxbuildsbothmodes','sanitizerandMemcheckruntimecontrols','twonamedproducttestspermodes','actualcompiledobject/binaryaudits','workflowdispatch','independentinstrumentationownerverification'],
    'pending_native_correction':None,'no_builds_tests_models_executed_by_agent':True,
    'pre_dispatch_requirements':['commit/carry all current bound source files so fresh checkout has matching bytes','parent sole executor; select projection-only','no implicit source-refresh on future drift'],
})
ready['source_hashes']['tests/projection/instrumented-scope.json'] = sha(SCOPE)
ready.pop('existing_workflow_unchanged_sha256')
write(READY,ready)
shutil.copyfile(READY,ARCHIVE/'revised-instrumented-ready.json')
# Validate final live bytes and preserve all preparation artifact hashes.
assert all(sha(ROOT/p)==h for p,h in updated.items())
assert sha(ARCHIVE/'original-instrumented-scope.json')==original_scope_hash
assert sha(ARCHIVE/'original-instrumented-ready.json')==original_ready_hash
write(ARCHIVE/'retention-manifest.json',{p.relative_to(ARCHIVE).as_posix():sha(p) for p in sorted(ARCHIVE.rglob('*')) if p.is_file() and p.name!='retention-manifest.json'})
print(json.dumps({'source_count':len(updated),'changes':len(changes),'additions':len(additions),'vendor_files':len(vendor),'fixtures':len(fixtures),'scope_sha256':sha(SCOPE),'ready_sha256':sha(READY),'preparation_archive':str(ARCHIVE.relative_to(ROOT))},sort_keys=True))
