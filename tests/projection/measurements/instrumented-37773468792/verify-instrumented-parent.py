import hashlib, importlib.util, json, re, shlex, subprocess, tarfile
from pathlib import Path
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');D=Path('/private/tmp/relm-f6e/instrumented-37773468792');raw=D/'raw';HEAD='e2081b43ebc7108c7bdc7b96fc2203b679d222a7'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
blob=lambda p:subprocess.check_output(['git','show',HEAD+':'+p],cwd=R)
assert sha(R/'tests/projection/instrumented.py')==hashlib.sha256(blob('tests/projection/instrumented.py')).hexdigest()
spec=importlib.util.spec_from_file_location('collector',R/'tests/projection/instrumented.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
scope=json.loads((raw/'projection-source-scope.json').read_text());sources=scope['source_hashes'];assert len(sources)==996
paths=list(sources);data=subprocess.check_output(['git','cat-file','--batch'],cwd=R,input=''.join(HEAD+':'+p+'\n' for p in paths).encode());pos=0
for p in paths:
 end=data.index(b'\n',pos);header=data[pos:end].split();assert header[1]==b'blob';size=int(header[2]);body=data[end+1:end+1+size];assert hashlib.sha256(body).hexdigest()==sources[p],p;pos=end+1+size+1
assert pos==len(data)
assert sha(raw/'projection-source-scope.json')=='126b53bff265a8f4ecf1d61ec5128d619b24d45b80fe8437999104c5a7675985'
assert (raw/'workflow.yaml').read_bytes()==blob('.github/workflows/nightly-memory-safety.yaml')
assert json.loads((D/'run.json').read_text())['headSha']==HEAD
A=raw/'projection-asan';V=raw/'projection-valgrind'
manifest=json.loads((A/'artifact-sha256.json').read_text())
for p,h in manifest.items():assert sha(A/p)==h,p
for directory,mode in [(A,'sanitizers'),(V,'valgrind')]:
 prov=json.loads((directory/'provenance.json').read_text());assert prov['source_commit']==HEAD and prov['scope']==scope and prov['mode']==mode and prov['ci']['GITHUB_RUN_ID']=='37773468792'
 assert prov['selection']=='projection-only'
 cmds=[json.loads(line) for line in (directory/'commands.jsonl').read_text().splitlines()]
 assert len(cmds)%2==0
 command_map={}
 for x,y in zip(cmds[::2],cmds[1::2]):assert x['label']==y['label'];command_map[x['label']]={**x,**y}
 builds=(directory/'build.out').read_text();binaries,library=c.collect_artifacts(builds,Path('/home/runner/work/_temp/relm-f6e-'+('asan' if mode=='sanitizers' else 'valgrind')+'-target'))
 receipt=json.loads((directory/'binary-artifacts.json').read_text());lib=json.loads((directory/'library-artifact.json').read_text());assert lib['archive']==str(library) and lib['profile_test'] is False and lib['features']==['default','spill']
 assert command_map['build']['status']==0
 assert not re.search(r'^(?:warning(?:\[|:)|ld: warning:)',(directory/'build.err').read_text(),re.M)
 parsed=json.loads((directory/'executed-tests.json').read_text());assert len(parsed)==(2 if mode=='sanitizers' else 1)
 for r in parsed:
  out=(directory/r['stdout_file']).read_text();err=(directory/r['stderr_file']).read_text();name=r['binary']
  assert sha(directory/r['stdout_file'])==r['stdout_sha256'] and sha(directory/r['stderr_file'])==r['stderr_sha256']
  assert c.collect_test(out,err,name)==r['production_marker']
  assert r['source_sha256']==sources[r['source_file']] and r['binary_sha256']==receipt[name]['sha256']
  label=c.BASE.test_log_label(r['test']);assert command_map[label]['status']==0
  symbols=(directory/('binary-'+name+'-symbols.out')).read_text()
  if mode=='sanitizers':c.BASE.check_runtime_symbols(symbols)
  else:
   assert not re.search(r'\b[TtWw] __(?:asan|ubsan)_',symbols)
   assert c.collect_valgrind((directory/(label+'.xml')).read_text(),binaries[name])==r['memcheck']
  for function in c.FUNCTIONS:assert re.search(r'\b[TtWw] '+function+r'$',symbols,re.M)
 if mode=='sanitizers':
  for label in ['safe-instrumented','safe-plain']:
   assert command_map[label]['status']==0 and 'mixed-language safe control executed' in (directory/(label+'.out')).read_text()
  for label in ['rust-asan','c-asan','cpp-asan','cpp-ubsan']:
   expected='runtime error: signed integer overflow' if label=='cpp-ubsan' else 'ERROR: AddressSanitizer: stack-buffer-overflow'
   c.BASE.check_fault(command_map[label]['status'],(directory/(label+'.out')).read_text()+(directory/(label+'.err')).read_text(),expected)
  assert 'rejected' in (directory/'uninstrumented-control.txt').read_text()
  objects=json.loads((directory/'native-objects.json').read_text());entries=sum([json.loads((directory/('compile_commands-'+str(i)+'.json')).read_text()) for i in range(2)],[]);assert len(objects)==len(entries)==270
  for i,(o,e) in enumerate(zip(objects,entries)):
   args=e.get('arguments') or shlex.split(e['command']);assert Path(args[0]).name in ['clang-19','clang++-19']
   assert all(f in args for f in c.BASE.NATIVE_FLAGS) and not any(a.startswith('-fno-sanitize=') for a in args)
   assert o['object']==str(Path(e['directory'])/args[args.index('-o')+1]) and o['source']==e['file']
   symbols=(directory/('object-'+str(i).zfill(4)+'.out')).read_text();assert '__asan_' in symbols and o['asan'] is True and o['ubsan']==('__ubsan_' in symbols)
  projection=json.loads((directory/'projection-object.json').read_text());assert projection['asan'] and projection['ubsan'] and projection['disassembly_sha256']==sha(directory/'projection-disassembly.out')
  parts=re.split(r'(?m)^[0-9a-f]+ <',(directory/'projection-disassembly.out').read_text())
  for f in c.FUNCTIONS:
   found=[p for p in parts if p.startswith(f+'>:')];assert len(found)==1 and '__asan_' in found[0] and '__ubsan_' in found[0]
  rust=json.loads((directory/'rust-objects.json').read_text());assert {r['crate'] for r in rust}=={'rebirth_llm','std','arrow_array'}
  for r in rust:
   assert '__asan_' in (directory/r['symbols_file']).read_text()
   lines=[l for l in (directory/'build.err').read_text().splitlines() if re.search(r'--crate-name '+r['crate']+r'\s',l) and '--target x86_64-unknown-linux-gnu' in l]
   assert lines and all('-Zsanitizer=address' in l and '-Zexternal-clangrt' in l for l in lines)
  env=prov['controlled_environment'];assert 'detect_leaks=1' in env['ASAN_OPTIONS']
 else:
  for mode_name,fault in [('safe',None),('invalid-write','InvalidWrite'),('leak','Leak_DefinitelyLost')]:
   label='memcheck-control-'+mode_name;assert command_map[label]['status']==(0 if fault is None else 1)
   c.collect_valgrind((directory/(label+'.xml')).read_text(),Path('/home/runner/work/_temp/relm-sanitizer-evidence/projection-valgrind/memcheck-probe'),fault)
  label=c.BASE.test_log_label(c.CASES['rebirth_llm']['id'])
  assert command_map[label]['status']==1
  assert (directory/(label+'.out')).read_bytes()==b'' and not (directory/(label+'.xml')).exists()
  err=(directory/(label+'.err')).read_text();assert "Expected 'p' or 'q' or '%' after '%'" in err and 'Bad option: --xml-file=' in err
  assert '%3A' in next(a for a in command_map[label]['command'] if a.startswith('--xml-file='))
report={'status':'partial_verified','whole_run':'failed','head':HEAD,'run_id':37773468792,'source_hashes_verified':len(sources),'asan_artifact_hashes_verified':len(manifest),'native_objects':270,'rust_archives':len(rust),'sanitizers':{'tests':2,'cases':23,'refusals':11,'values':291,'reported_tiny_loads':2,'reported_constructors':3},'memcheck_constructor':{'tests':1,'cases':13,'refusals':9,'values':288,'reported_tiny_loads':1,'reported_constructors':2,'errors':0,'applied_suppressions':0},'memcheck_worker':{'executed':False,'reason':'Valgrind rejects percent-encoded XML path before binary execution','stdout_bytes':0,'xml_present':False},'compiler_warnings':0,'limits':'Original e2081b4 scope; no R/SEXP, GPU, universal UB, new golden accuracy or later review-fix execution claim.'}
(D/'owner-verification.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
