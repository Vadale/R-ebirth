import hashlib,importlib.util,json,re,shlex,subprocess,xml.etree.ElementTree as ET
from pathlib import Path
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');D=Path('/private/tmp/relm-f6e/instrumented-review-37784612697');raw=D/'raw';HEAD='1a9ec091f43c6d869f9184f95af2ce3a89bbb850';RUN='37784612697';SCOPE='4fc29cbff9883bafa8be57004cd7048e199450c690cce0bd9358a6f84dbf2c5d'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
spec=importlib.util.spec_from_file_location('review_collector',R/'tests/projection/instrumented_review.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c);P=c.P;BASE=c.BASE
scope=json.loads((raw/'projection-review-source-scope.json').read_text());sources=scope['source_hashes'];assert len(sources)==1001 and sha(raw/'projection-review-source-scope.json')==SCOPE
paths=list(sources);data=subprocess.check_output(['git','cat-file','--batch'],cwd=R,input=''.join(HEAD+':'+p+'\n' for p in paths).encode());pos=0
for p in paths:
 end=data.index(b'\n',pos);header=data[pos:end].split();assert header[1]==b'blob';size=int(header[2]);body=data[end+1:end+1+size];assert hashlib.sha256(body).hexdigest()==sources[p]==sha(R/p),p;pos=end+1+size+1
assert pos==len(data)
assert sha(raw/'workflow.yaml')==sources['.github/workflows/nightly-memory-safety.yaml']
run=json.loads((D/'run.json').read_text());assert run['headSha']==HEAD and run['conclusion']=='success' and run['status']=='completed'
assert [x['conclusion'] for x in run['jobs'] if x['name'].startswith('ASan Rust')]==['success']
assert [x['conclusion'] for x in run['jobs'] if x['name'].startswith('Valgrind memcheck')]==['skipped']
all_modes={};artifact_counts={};native_count=0
for short,mode in [('asan','sanitizers'),('valgrind','valgrind')]:
 directory=raw/('projection-review-'+short);manifest=json.loads((directory/'artifact-sha256.json').read_text());artifact_counts[mode]=len(manifest)
 for p,h in manifest.items():assert sha(directory/p)==h,p
 prov=json.loads((directory/'provenance.json').read_text());assert prov['source_commit']==HEAD and prov['scope']==scope and prov['mode']==mode and prov['ci']['GITHUB_RUN_ID']==RUN
 assert prov['selection']=='projection-review-fixes' and prov['selected_tests']=={'rebirth_llm':c.selected(mode)}
 cmds=[json.loads(line) for line in (directory/'commands.jsonl').read_text().splitlines()];assert len(cmds)%2==0;command_map={}
 for x,y in zip(cmds[::2],cmds[1::2]):assert x['label']==y['label'] and x['label'] not in command_map;command_map[x['label']]={**x,**y}
 target=Path('/home/runner/work/_temp/relm-f6e-review-'+short+'-target');builds=(directory/'build.out').read_text();binaries,library=P.collect_artifacts(builds,target)
 receipt=json.loads((directory/'binary-artifacts.json').read_text());lib=json.loads((directory/'library-artifact.json').read_text());assert lib['archive']==str(library) and lib['profile_test'] is False and lib['features']==['default','spill']
 assert command_map['build']['status']==0 and not re.search(r'^\s*(?:warning(?:\[|:)|ld: warning:)',(directory/'build.err').read_text(),re.M)
 actual_warnings=[x for x in [json.loads(l) for l in builds.splitlines() if l.startswith('{')] if x.get('reason')=='compiler-message' and x['message']['level'] in ['warning','error']]
 inventory=json.loads((D/'compiler-warning-inventory.json').read_text())[short]
 assert actual_warnings==inventory['diagnostics'] and inventory['exact_diagnostic_multiset_matches_parent'] is True and inventory['own_package_warnings']==0 and inventory['errors']==0
 parsed=json.loads((directory/'executed-tests.json').read_text());assert [r['test'] for r in parsed]==c.selected(mode)
 assert not any(BASE.test_log_label(case['id']) in command_map for name,case in P.CASES.items() if name!='rebirth_llm')
 for r in parsed:
  out=(directory/r['stdout_file']).read_text();err=(directory/r['stderr_file']).read_text();assert r['binary']=='rebirth_llm'
  assert sha(directory/r['stdout_file'])==r['stdout_sha256'] and sha(directory/r['stderr_file'])==r['stderr_sha256']
  expected=c.collect_zero(out,err,SCOPE) if r['test']==c.ZERO_ID else P.collect_test(out,err,'rebirth_llm')
  assert expected==r['marker'] and r['source_sha256']==sources[r['source_file']] and r['binary_sha256']==receipt['rebirth_llm']['sha256']
  label=BASE.test_log_label(r['test']);cmd=command_map[label];assert cmd['status']==0 and '--exact' in cmd['command'] and r['test'] in cmd['command']
  symbols=(directory/'binary-rebirth_llm-symbols.out').read_text()
  if mode=='sanitizers':BASE.check_runtime_symbols(symbols)
  else:
   assert not re.search(r'\b[TtWw] __(?:asan|ubsan)_',symbols)
   assert P.collect_valgrind((directory/(label+'.xml')).read_text(),binaries['rebirth_llm'])==r['memcheck']
   xml=ET.parse(directory/(label+'.xml')).getroot();assert not xml.findall('error') and not xml.findall('suppcounts/pair')
   argv=next(a for a in cmd['command'] if a.startswith('--xml-file='));assert '%%3A' in argv and '%3A' in label
  for f in P.FUNCTIONS:assert re.search(r'\b[TtWw] '+f+r'$',symbols,re.M)
 if mode=='sanitizers':
  for label in ['safe-instrumented','safe-plain']:assert command_map[label]['status']==0 and 'mixed-language safe control executed' in (directory/(label+'.out')).read_text()
  for label in ['rust-asan','c-asan','cpp-asan','cpp-ubsan']:
   expected='runtime error: signed integer overflow' if label=='cpp-ubsan' else 'ERROR: AddressSanitizer: stack-buffer-overflow'
   BASE.check_fault(command_map[label]['status'],(directory/(label+'.out')).read_text()+(directory/(label+'.err')).read_text(),expected)
  assert 'rejected' in (directory/'uninstrumented-control.txt').read_text()
  objects=json.loads((directory/'native-objects.json').read_text());entries=sum([json.loads((directory/('compile_commands-'+str(i)+'.json')).read_text()) for i in range(2)],[]);assert len(objects)==len(entries)==270;native_count=len(objects)
  for i,(o,e) in enumerate(zip(objects,entries)):
   args=e.get('arguments') or shlex.split(e['command']);assert Path(args[0]).name in ['clang-19','clang++-19']
   assert all(f in args for f in BASE.NATIVE_FLAGS) and not any(a.startswith('-fno-sanitize=') for a in args)
   assert o['object']==str(Path(e['directory'])/args[args.index('-o')+1]) and o['source']==e['file']
   symbols=(directory/('object-'+str(i).zfill(4)+'.out')).read_text();assert '__asan_' in symbols and o['asan'] is True and o['ubsan']==('__ubsan_' in symbols)
  projection=json.loads((directory/'projection-object.json').read_text());assert projection['asan'] and projection['ubsan'] and projection['disassembly_sha256']==sha(directory/'projection-disassembly.out')
  parts=re.split(r'(?m)^[0-9a-f]+ <',(directory/'projection-disassembly.out').read_text())
  for f in P.FUNCTIONS:
   found=[p for p in parts if p.startswith(f+'>:')];assert len(found)==1 and '__asan_' in found[0] and '__ubsan_' in found[0]
  rust=json.loads((directory/'rust-objects.json').read_text());assert {r['crate'] for r in rust}=={'rebirth_llm','std','arrow_array'}
  for r in rust:
   assert '__asan_' in (directory/r['symbols_file']).read_text()
   lines=[l for l in (directory/'build.err').read_text().splitlines() if re.search(r'--crate-name '+r['crate']+r'\s',l) and '--target x86_64-unknown-linux-gnu' in l]
   assert lines and all('-Zsanitizer=address' in l and '-Zexternal-clangrt' in l for l in lines)
  assert 'detect_leaks=1' in prov['controlled_environment']['ASAN_OPTIONS']
 else:
  for mode_name,fault in [('safe',None),('invalid-write','InvalidWrite'),('leak','Leak_DefinitelyLost')]:
   label='memcheck-control-'+mode_name+('-%3A-%p' if mode_name=='safe' else '')
   cmd=command_map[label];assert cmd['status']==(0 if fault is None else 1)
   binary=Path('/home/runner/work/_temp/relm-sanitizer-evidence/projection-review-valgrind/memcheck-probe')
   P.collect_valgrind((directory/(label+'.xml')).read_text(),binary,fault)
   if mode_name=='safe':
    assert next(a for a in cmd['command'] if a.startswith('--xml-file=')).endswith('memcheck-control-safe-%%3A-%%p.xml')
    assert (directory/'memcheck-control-safe-%3A-%p.xml').is_file()
 summary=json.loads((directory/'projection-review-summary.json').read_text());totals={k:sum(r['marker'][k] for r in parsed) for k in ['executed_cases','rejected_cases','compared_values','model_loads','constructor_calls']}
 assert tuple(totals.values())==((8,2,224,1,1) if mode=='sanitizers' else (18,4,227,2,2))
 assert all(summary[k]==v for k,v in totals.items()) and summary['production_integration_built_not_executed'] is True and summary['registry_r_gc_or_ffi_acceptance'] is False
 all_modes[mode]={'tests':len(parsed),**totals,'errors':0,'applied_suppressions':0}
report={'status':'passed','whole_run':'success','head':HEAD,'run_id':int(RUN),'source_hashes_verified':1001,'artifact_hashes_verified':artifact_counts,'native_objects':native_count,'rust_archives':3,'modes':all_modes,'runtime_fault_controls':'passed','real_literal_percent_filename_control':'passed','own_package_compiler_warnings':0,'retained_external_compiler_warnings':{'sanitizers':17,'valgrind':10},'external_diagnostics_exactly_match_parent':True,'integration_binary_built_not_executed':True,'scope':'Affected default-library CPU zero/live regression plus previously unrun worker Memcheck. No R/SEXP/FFI-registry, GPU, universal UB, new golden accuracy or performance claim. Parent successes carried at exact retained source scopes.'}
(D/'owner-verification.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
