from pathlib import Path
import hashlib,importlib.util,json,re,shlex,subprocess
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');scratch=Path('/private/tmp/relm-f6')
sha='6877c4dc4bca3eb08d8eeb06f02b71cebc0601d7';runid='37142257323'
root=scratch/f'sanitizer-{runid}'/f'native-sanitizers-{sha}-{runid}-1'
assert root.is_dir()
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()==sha
assert not subprocess.check_output(['git','status','--porcelain'],cwd=repo,text=True)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(name):return (root/name).read_text()
def obj(name):return json.loads(read(name))
spec=importlib.util.spec_from_file_location('pinned_harness',repo/'tests/sanitizers/run.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
expected={(b,t) for b,tests in h.LIVE_CASES.items() for t in tests};assert len(expected)==15
jobs=json.loads((scratch/f'sanitizer-{runid}-jobs.json').read_text())
assert jobs['headSha']==sha and jobs['conclusion']=='success'
assert all(j['conclusion'] in ['success','skipped'] for j in jobs['jobs'])
provenance=obj('provenance.json');assert provenance['source_commit']==sha
assert provenance['selection']=='live-only' and provenance['selected_tests']==h.LIVE_CASES
assert provenance['ci']['GITHUB_SHA']==sha and provenance['ci']['GITHUB_RUN_ID']==runid
assert provenance['ci']['GITHUB_RUN_ATTEMPT']=='1' and provenance['ci']['GITHUB_JOB']=='asan-ubsan-native'
for p,s in provenance['tracked_file_sha256'].items():
 assert digest(repo/p)==s,p
flags=provenance['flags']
assert flags['RELM_NATIVE_SANITIZERS']=='address,undefined'
assert '-Zsanitizer=address' in flags['CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS']
assert '-Zexternal-clangrt' in flags['CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS']
assert 'detect_leaks=1' in flags['ASAN_OPTIONS'] and 'halt_on_error=1' in flags['UBSAN_OPTIONS']
for version in ['clang-19','clang++-19']:assert 'clang version 19.1.1' in read(version+'-version.out')
assert 'LLVM version: 19.' in read('rust-version.out')
assert '1:19.1.1-1ubuntu1~24.04.2' in read('packages.out')
callback=obj('cpu-callbacks/result.json')
assert callback['status']=='passed' and callback['runtime_required'] is True
assert callback['runtime_status']=='passed' and callback['runtime_function_hook'] is True
assert callback['runtime_rejections']==[True]*7 and callback['contracts']==7
for p,s in callback['source_sha256'].items():assert digest(repo/p)==s,p
for p,s in callback['evidence_sha256'].items():assert digest(root/'cpu-callbacks'/p)==s,p
assert 'ubsan_handle_function_type_mismatch' in read('cpu-callbacks/caller-symbols.out')
targets=['ggml_vec_dot_f32','ggml_vec_dot_f16','ggml_vec_dot_bf16','ggml_cpu_fp32_to_fp32','ggml_cpu_fp32_to_fp16','ggml_cpu_fp32_to_bf16','ggml_cpu_fp32_to_i32']
commands={x['name']:x for x in callback['commands']}
for i,name in enumerate(targets):
 err=read(f'cpu-callbacks/original-runtime-{i}.err')
 assert commands[f'original-runtime-{i}']['exit_code']!=0 and 'incorrect function type' in err and name in err
 assert not read(f'cpu-callbacks/original-runtime-{i}.out')
 assert commands[f'uninstrumented-control-{i}']['exit_code']==0
 assert read(f'cpu-callbacks/uninstrumented-control-{i}.out')==f'ORIGINAL_TYPE_MISMATCH_SURVIVED {i}\n'
assert read('cpu-callbacks/sanitized-forwarding.out').splitlines()==[f'CALLBACK_PASS {i}' for i in range(7)]+['SEVEN_ADAPTERS_PASSED']
assert not read('cpu-callbacks/sanitized-forwarding.err')
graph=obj('graph-size-layout/result.json');assert graph['status']=='passed' and graph['cases']==68
for p,s in graph['source_sha256'].items():assert digest(repo/p)==s,p
for p,s in graph['evidence_sha256'].items():assert digest(root/'graph-size-layout'/p)==s,p
# Independently inspect actual compilation flags and retained object symbols.
databases=sorted(root.glob('compile_commands-*.json'));assert len(databases)==2
entries=[e for p in databases for e in json.loads(p.read_text())]
objects=obj('native-objects.json');assert len(entries)==len(objects)==269
for i,(entry,record) in enumerate(zip(entries,objects)):
 args=entry.get('arguments') or shlex.split(entry['command'])
 assert Path(args[0]).name in ['clang-19','clang++-19']
 assert set(h.NATIVE_FLAGS).issubset(args) and not any(a.startswith('-fno-sanitize=') for a in args)
 assert entry['file']==record['source'] and record['asan'] is True
 symbols=read(f'object-{i:04d}.out');assert '__asan_' in symbols
 assert ('__ubsan_' in symbols)==record['ubsan']
 assert re.fullmatch('[a-f0-9]{64}',record['sha256'])
for n in ['grammar.cpp','abi.cpp','spill_lease.cpp']:assert any(Path(o['source']).name==n for o in objects)
cvec=[s for s in re.split(r'(?m)^[0-9a-f]+ <',read('patched-build-cvec-disassembly.out')) if s.startswith('llm_graph_context::build_cvec(')]
assert len(cvec)==1 and '__asan_' in cvec[0] and '__ubsan_' in cvec[0]
# Derive archive identities independently from the two actual Cargo transcripts.
# Build-script stdout lines are accepted only with the pinned Cargo -vv prefix.
required={'rebirth_llm','arrow_array','std'}
declared={};production=None;test_executable=None;arrow_inputs={}
for stage in ['build','build-library']:
 events=[]
 for line in read(stage+'.out').splitlines():
  if not line.strip():continue
  if line.startswith('{'):
   e=json.loads(line);assert isinstance(e,dict) and 'reason' in e;events.append(e)
  else:assert re.match(r'^\[[A-Za-z0-9_][A-Za-z0-9_.-]* [0-9]+\.[0-9]+\.[0-9]+[^\]]*\] ',line),line
 finished=[e for e in events if e['reason']=='build-finished'];assert len(finished)==1 and finished[0]['success'] is True
 seen=set()
 for e in events:
  if e['reason']!='compiler-artifact':continue
  crate=e['target']['name']
  if crate=='rebirth_llm' and e['profile']['test']:
   assert stage=='build' and e['executable'];test_executable=e['executable'];continue
  if crate not in required:continue
  assert e['profile']['test'] is False and e['executable'] is None
  assert e['target']['kind']==(['rlib'] if crate=='std' else ['lib'])
  assert crate not in seen;seen.add(crate)
  paths=[p for p in e['filenames'] if p.endswith('.rlib')];assert len(paths)==1
  if crate=='arrow_array':arrow_inputs[stage]=e['filenames']
  path=Path(paths[0]);debug=Path(flags['CARGO_TARGET_DIR'])/'x86_64-unknown-linux-gnu/debug'
  assert path.parent in [debug,debug/'deps']
  assert re.fullmatch(r'lib'+crate+r'(?:-[0-9a-f]+)?\.rlib',path.name)
  declared.setdefault((crate,str(path)),[]).append(stage)
  if crate=='rebirth_llm':assert stage=='build-library';production=str(path)
assert {c for c,p in declared}==required and len(declared)==4 and test_executable
rust=obj('rust-objects.json');assert len(rust)==4
assert {(r['crate'],r['archive']) for r in rust}==set(declared)
assert len({r['symbols_file'] for r in rust})==4
build_log=read('build.err')+'\n'+read('build-library.err')
for r in rust:
 assert r['cargo_stages']==declared[(r['crate'],r['archive'])]
 symbolfile=r['symbols_file'];assert Path(symbolfile).name==symbolfile
 assert r['asan'] is True and '__asan_' in read(symbolfile)
 assert re.fullmatch('[0-9a-f]{64}',r['sha256'])
 lines=[l for l in build_log.splitlines() if re.search(r'--crate-name '+r['crate']+r'\s',l) and '--target x86_64-unknown-linux-gnu' in l]
 assert lines and all('-Zsanitizer=address' in l and '-Zexternal-clangrt' in l for l in lines)
lib=obj('library-artifact.json');assert lib['archive']==production
assert [(r['archive'],r['sha256']) for r in rust if r['crate']=='rebirth_llm']==[(lib['archive'],lib['sha256'])]
# Both parent compilations consume the Arrow variant actually declared for their stage.
for stage in ['build','build-library']:
 parent=[l for l in read(stage+'.err').splitlines() if '--crate-name rebirth_llm ' in l and '--target x86_64-unknown-linux-gnu' in l]
 assert parent
 arrow=[path for (crate,path),stages in declared.items() if crate=='arrow_array' and stage in stages];assert len(arrow)==1
 linked=[m.group(1).strip("'") for l in parent for m in re.finditer(r'--extern arrow_array=([^ ]+)',l)]
 assert len(linked)==1 and linked[0] in arrow_inputs[stage]
 assert Path(linked[0]).stem==Path(arrow[0]).stem
# Parse actual libtest events separately from the harness's validator.
receipts=obj('executed-tests.json');assert len(receipts)==15
assert {(r['binary'],r['test']) for r in receipts}==expected
for r in receipts:
 assert r['status']=='executed_ok' and r['selection']=='live-only'
 assert digest(repo/'rebirth/src/rust/rebirth-llm'/r['source_file'])==r['source_sha256']
 assert re.fullmatch('[a-f0-9]{64}',r['binary_sha256'])
 for stream in ['stdout','stderr']:
  name=r[stream+'_file'];assert Path(name).name==name and ':' not in name
  assert digest(root/name)==r[stream+'_sha256']
 events=[json.loads(l) for l in read(r['stdout_file']).splitlines() if l.strip()]
 tests=[e for e in events if e['type']=='test'];suites=[e for e in events if e['type']=='suite']
 assert [(e['name'],e['event']) for e in tests]==[(r['test'],'started'),(r['test'],'ok')]
 assert len(events)==4
 if r['test'] in h.CAPTURED_WORK_MARKERS:
  captured=tests[1]['stdout'];assert h.CAPTURED_WORK_MARKERS[r['test']] in captured
  match=re.fullmatch(r'F6_GOLDEN activation_values=3840 max_activation_delta=([0-9.e+-]+) max_logit_delta=([0-9.e+-]+)\n',captured)
  assert match and all(0<=float(v)<=0.01 for v in match.groups())
 assert len(suites)==2 and suites[0]['event']=='started' and suites[0]['test_count']==1
 assert suites[1]['event']=='ok' and suites[1]['passed']==1 and suites[1]['failed']==suites[1]['ignored']==0
 text=read(r['stdout_file'])+read(r['stderr_file']);assert not re.search(r'ERROR: (?:AddressSanitizer|LeakSanitizer)|SUMMARY: (?:AddressSanitizer|UndefinedBehaviorSanitizer)|runtime error:',text)
 if r['binary'] in h.WORK_MARKERS:assert h.WORK_MARKERS[r['binary']] in text
for binary in h.LIVE_CASES:
 syms=read(f'binary-{binary}-symbols.out')
 for name in ['__asan_init','__ubsan_handle_add_overflow_abort']:assert re.search(r'\b[TtWw] '+name+r'$',syms,re.M)
# Fault/no-op controls and exact successful completion, without hiding prior failures.
records=[json.loads(line) for line in read('commands.jsonl').splitlines()]
statuses={}
for record in records:
 if 'status' in record:
  assert record['label'] not in statuses
  statuses[record['label']]=record['status']
assert statuses['build']==statuses['build-library']==0
for r in receipts:
 label=Path(r['stdout_file']).stem
 assert statuses[label]==0
 assert len({x['binary_sha256'] for x in receipts})==1
for mode in ['rust-asan','c-asan','cpp-asan','cpp-ubsan']:
 assert statuses[mode]==1
 marker='runtime error: signed integer overflow' if mode=='cpp-ubsan' else 'ERROR: AddressSanitizer: stack-buffer-overflow'
 assert marker in read(mode+'.out')+read(mode+'.err')
for mode in ['plain','instrumented']:
 assert statuses['safe-'+mode]==0 and 'mixed-language safe control executed' in read('safe-'+mode+'.out')
 assert not read('safe-'+mode+'.err')
for symbol in ['__asan_init','__ubsan_handle_add_overflow_abort']:
 assert re.search(r'\b[TtWw] '+symbol+r'$',read('symbols-instrumented.out'),re.M)
assert not re.search(r'\b[TtWw] __asan_init$',read('symbols-plain.out'),re.M)
assert read('uninstrumented-control.txt').startswith('PASS: the identical safe probe without instrumentation was rejected.')
assert '15 required native CPU tests executed' in read('SUCCESS.txt')
assert not (root/'FAILURE.txt').exists()
assert 'Sanitizer runtime, fault and uninstrumented controls passed' in read('harness.log')
assert '34 tests' in read('harness-controls.log') and '\nOK\n' in read('harness-controls.log')
files={str(p.relative_to(root)):dict(sha256=digest(p),bytes=p.stat().st_size) for p in root.rglob('*') if p.is_file()}
manifest=scratch/f'sanitizer-{runid}-verified-files.json';manifest.write_text(json.dumps(files,indent=2)+'\n')
result={'status':'independently_verified','run_id':int(runid),'source_sha':sha,'product_tests':15,'callback_runtime_controls':7,'graph_layout_cases':68,'mixed_fault_controls':4,'uninstrumented_control_rejected':True,'native_objects':len(objects),'rust_archives':len(rust),'source_files_verified':len(provenance['tracked_file_sha256']),'raw_files':len(files),'raw_bytes':sum(f['bytes'] for f in files.values()),'file_manifest_sha256':digest(manifest),'scope':'Exercised Linux CPU native paths only; no R/SEXP, GPU, vision, TSan or universal UB claim. Native object/archive/test-binary bytes are absent from the artifact: their recorded digests remain runtime receipts, while downloaded symbol outputs, flags, source and per-test bytes were independently checked. Callback/graph probe binary bytes are present and rehashed. Old failed runs remain failed.'}
(scratch/f'sanitizer-{runid}-verification.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
