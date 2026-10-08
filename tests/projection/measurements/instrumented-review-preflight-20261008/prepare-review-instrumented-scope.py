import hashlib,importlib.util,json,shutil
from pathlib import Path
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');T=Path('/private/tmp/relm-f6e')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
old_path=R/'tests/projection/instrumented-scope.json';old=json.loads(old_path.read_text())
assert sha(old_path)=='126b53bff265a8f4ecf1d61ec5128d619b24d45b80fe8437999104c5a7675985'
allowed={'docs/f6e-instrumented-plan.md','.github/workflows/nightly-memory-safety.yaml','rebirth/src/rust/rebirth-ffi/src/projection_transfer_boundary.rs','rebirth/src/rust/rebirth-llm/src/projection.rs','tests/projection/instrumented.py'}
changes={p:{'parent':h,'current':sha(R/p)} for p,h in old['source_hashes'].items() if sha(R/p)!=h}
assert set(changes)==allowed,changes
added=['rebirth/src/rust/rebirth-llm/src/projection_review_tests.rs','rebirth/src/rust/rebirth-ffi/src/projection_review_registry_tests.rs','tests/projection/instrumented_review.py','tests/projection/instrumented_review_controls.py','tests/projection/instrumented_path_controls.py']
sources={p:sha(R/p) for p in list(old['source_hashes'])+added}
sp=importlib.util.spec_from_file_location('review',R/'tests/projection/instrumented_review.py');m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m)
new={'schema':1,'selection':'projection-review-fixes','fixture_sha256':old['fixture_sha256'],
 'source_hashes':sources,'selected_tests':{mode:m.selected(mode) for mode in ['sanitizers','valgrind']},
 'parent_scope':{'path':str(old_path.relative_to(R)),'sha256':sha(old_path),'source_commit':'e2081b43ebc7108c7bdc7b96fc2203b679d222a7','run_id':37773468792,'status':'failed; two ASan tests and first Memcheck test independently accepted at parent source'},
 'revision':{'unchanged':len(old['source_hashes'])-len(changes),'changed':changes,'added':{p:sources[p] for p in added}},
 'execution_status':'unexecuted; publish all bound sources after local correction acceptance before dispatch',
 'scope':'One new ASan/UBSan zero/live test, previously unexecuted worker plus new zero/live in baseline Memcheck. Production integration compiled for rlib audit, not executed. No R/SEXP, FFI registry/R GC, GPU, new numerical accuracy or performance acceptance.'}
p=R/'tests/projection/instrumented-review-scope.json';assert not p.exists();p.write_text(json.dumps(new,indent=2,sort_keys=True)+'\n');m.P.verify_sources(R,new)
A=R/'tests/projection/measurements/instrumented-review-preflight-20261008';A.mkdir()
for name in ['instrumented-review-controls.log','instrumented-path-controls.log','instrumented-path-controls-fixture-draft.py','instrumented-path-controls-fixture-draft.log','check-review-workflow.R','check-review-workflow.log','check-review-workflow-yaml11-draft.R','check-review-workflow-yaml11-draft.log','prepare-review-instrumented-scope.py','prepare-review-instrumented-scope-draft.py']:
 shutil.copy2(T/name,A/name)
for name in ['instrumented.py','instrumented_review.py','instrumented_review_controls.py','instrumented_path_controls.py','instrumented-review-scope.json']:shutil.copy2(R/'tests/projection'/name,A/name)
shutil.copy2(R/'.github/workflows/nightly-memory-safety.yaml',A/'workflow.yaml')
(A/'preflight-notes.txt').write_text('Model-free preparation only. Three new literal-path controls and five new affected collector methods pass (13 marker/6 structural negatives plus finding and selection checks). Original 40 controls were not replayed. Initial path-test fake context omitted root; corrected fixture only. R yaml uses YAML 1.1 and maps the on key to TRUE; initial trigger accessor assertion failed, then corrected without editing workflow semantics. Full/scheduled/old projection routing and pins remain unchanged. The first scope-preparation allowlist omitted the just-updated plan document; its strict check refused before writing the scope. The explicit documentation delta is now bound. No remote/build/native/model execution by these controls. Source scope: 991 unchanged parent files, five explicit changes, five new files.\n')
(A/'manifest.json').write_text(json.dumps({str(x.relative_to(A)):sha(x) for x in A.rglob('*') if x.is_file()},indent=2)+'\n')
print(json.dumps({'status':'prepared_unexecuted','source_count':len(sources),'changed':len(changes),'added':len(added),'scope_sha256':sha(p),'manifest_sha256':sha(A/'manifest.json')},indent=2))
