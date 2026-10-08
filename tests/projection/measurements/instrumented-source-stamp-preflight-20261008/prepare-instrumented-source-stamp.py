from pathlib import Path
import json,hashlib,subprocess,shutil
repo=Path.cwd();root=Path('/private/tmp/relm-f6e');raw=root/'instrumented-review-37782783888/raw';sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
scopepath=repo/'tests/projection/instrumented-review-scope.json';scope=json.loads(scopepath.read_text());assert sha(scopepath)=='357c430dda4aedb523b8a26dcef6ce020c0a2ebacb3716d0abdcf6a04af7346c';assert sha(raw/'projection-review-source-scope.json')==sha(scopepath)
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()=='26eff2c4dd64ab9d285576f64f563c78ce08be1b'
for p,h in scope['source_hashes'].items():assert sha(repo/p)==h,p
assert sha(raw/'workflow.yaml')==scope['source_hashes']['.github/workflows/nightly-memory-safety.yaml']
assert [p.name for p in (raw/'projection-review-asan').iterdir()]==['FAILURE.txt']
fail=(raw/'projection-review-asan/FAILURE.txt').read_text();assert 'possible early-return/model skip' in fail
archive=repo/'tests/projection/measurements/instrumented-review-37782783888';shutil.copytree(raw,archive/'raw');shutil.copy2(root/'instrumented-review-dispatch.json',archive/'dispatch.json')
report={'status':'verified_failure_before_native_build','run':37782783888,'head':'26eff2c4dd64ab9d285576f64f563c78ce08be1b','source_hashes':1001,'raw_files':len([p for p in raw.rglob('*') if p.is_file()]),'native_builds':0,'native_tests':0,'model_loads':0,'cause':'The unchanged conservative unconditional-test source guard rejects env::var inside the test body. Its only occurrence is the terminal source-provenance JSON field, not a skip/admission branch. Refactor that expression into a helper outside the test, preserving assertions and the guard itself.','whole_workflow':'failed','correction':'Test-only source stamp helper; no product, assertion, model, runtime guard or bound change. Actual affected ASan/Memcheck remain unexecuted.'}
(archive/'owner-failure-verification.json').write_text(json.dumps(report,indent=2)+'\n');(archive/'manifest.json').write_text(json.dumps({str(p.relative_to(archive)):sha(p) for p in archive.rglob('*') if p.is_file()},indent=2)+'\n')
prep=repo/'tests/projection/measurements/instrumented-source-stamp-preflight-20261008';prep.mkdir();shutil.copy2(scopepath,prep/'previous-scope.json')
p=repo/'rebirth/src/rust/rebirth-llm/src/projection_review_tests.rs';old=p.read_text();shutil.copy2(p,prep/'previous-projection_review_tests.rs')
expr='std::env::var("F6E_SOURCE").unwrap_or_default()';helper='fn review_source_stamp() -> String {\n    '+expr+'\n}\n\n'
assert old.count(expr)==1
new=old.replace('#[test]\nfn projection_zero_live_capture',helper+'#[test]\nfn projection_zero_live_capture',1).replace('"source":'+expr,'"source":review_source_stamp()')
assert new.replace(helper,'',1).replace('"source":review_source_stamp()','"source":'+expr)==old
p.write_text(new)
controls=repo/'tests/projection/instrumented_review_controls.py';c=controls.read_text();shutil.copy2(controls,prep/'previous-instrumented_review_controls.py')
method='''    def test_actual_source_is_unconditional(self):
        source = (Path(__file__).resolve().parents[2] / R.ZERO_SOURCE).read_text()
        R.BASE.check_unconditional_source(source, R.ZERO_ID)
        entry = "fn " + R.ZERO_ID.split("::")[-1] + "() {"
        mutations = [
            source.replace('"source":review_source_stamp()',
                           '"source":std::env::var("F6E_SOURCE").unwrap_or_default()'),
            source.replace(entry, entry + "\\n    return;", 1),
            source.replace(entry, entry + '\\n    let _ = std::env::var("SKIP");', 1),
            source.replace(entry, entry + '\\n    let _ = option_env!("SKIP");', 1),
            source.replace("#[test]\\n" + entry, "#[test]\\n#[ignore]\\n" + entry, 1),
            source.replace(entry, entry + "\\n    skip!();", 1),
        ]
        for i, text in enumerate(mutations):
            with self.subTest(i=i), self.assertRaises(RuntimeError):
                R.BASE.check_unconditional_source(text, R.ZERO_ID)

'''
c=c.replace('    def test_bound_positive(self):',method+'    def test_bound_positive(self):',1).replace('result.testsRun!=5','result.testsRun!=6').replace('"methods":5,','"methods":6,"source_positive":1,"source_negatives":6,')
controls.write_text(c)
changed=['rebirth/src/rust/rebirth-llm/src/projection_review_tests.rs','tests/projection/instrumented_review_controls.py'];delta={p:{'before':scope['source_hashes'][p],'after':sha(repo/p)} for p in changed}
for p in changed:scope['source_hashes'][p]=delta[p]['after']
scope['source_stamp_extraction']={'parent_scope_sha256':sha(prep/'previous-scope.json'),'parent_failed_run':37782783888,'changed':delta,'unchanged_source_files':999,'semantic_scope':'Exact source-stamp expression moved to a helper. Test body reconstructs byte-for-byte; no product or assertion change. Generic unconditional guard unchanged.'}
scopepath.write_text(json.dumps(scope,indent=2,sort_keys=True)+'\n');shutil.copy2(scopepath,prep/'current-scope.json');shutil.copy2(Path(__file__),prep/Path(__file__).name)
print(json.dumps({'failed_archive_manifest_sha256':sha(archive/'manifest.json'),'new_scope_sha256':sha(scopepath),'changed':delta,'bound_files':len(scope['source_hashes'])},indent=2))
