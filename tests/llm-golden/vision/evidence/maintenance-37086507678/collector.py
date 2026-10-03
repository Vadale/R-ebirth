from pathlib import Path
import gzip,hashlib,json,math,re,subprocess
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); root=Path('/private/tmp/relm-maintenance/vision-37086507678');head='e280868e3cae25f244a988b08990c673af8be586'
out=repo/'tests/llm-golden/vision/evidence/maintenance-37086507678';out.mkdir(exist_ok=False)
summary={'run_id':37086507678,'source_sha':head,'status':'verified_at_recorded_source','runners':[],'limitations':'Producer/model/shared-library bytes not in downloaded artifact are represented by runtime-verified manifest identities, not independently rehashed locally. Each reference is runner-specific. Future D040 source is not covered by relabelling this result.'}
sha=lambda data:hashlib.sha256(data).hexdigest()
readgit=lambda path:subprocess.check_output(['git','show',head+':'+path],cwd=repo)
tree=subprocess.check_output(['git','rev-parse',head+'^{tree}'],cwd=repo,text=True).strip()
nonces=set()
for p in sorted(root.iterdir()):
 def one(name):
  files=list(p.rglob(name));assert len(files)==1,(name,len(files));return files[0]
 m=json.loads(one('upstream-here.manifest.json').read_text());c=m['context'];j=json.loads(one('vision-job-context.json').read_text())
 assert c['source_sha']==c['workflow_sha']==j['checkout_sha']==j['GITHUB_SHA']==head
 assert c['run_id']==j['GITHUB_RUN_ID']=='37086507678' and c['run_attempt']==j['GITHUB_RUN_ATTEMPT']=='1'
 assert c['job']==j['GITHUB_JOB']=='vision-golden' and c['runner_name']==j['RUNNER_NAME'] and c['runner_os']==j['RUNNER_OS']
 assert j['source_tree']==tree and j['workflow_sha256']==sha(readgit('.github/workflows/nightly-vision-golden.yaml'))
 assert re.fullmatch('[0-9a-f]{64}',c['job_nonce']) and c['job_nonce'] not in nonces;nonces.add(c['job_nonce'])
 ref=one('upstream-here.txt').read_bytes();lines=ref.decode('ascii').splitlines()
 assert list(map(int,lines[0].split()))==m['reference']['dimensions']==[64,1536] and len(lines)==98305
 assert all(math.isfinite(float(x)) and abs(float(x))<=3.4028234663852886e38 for x in lines[1:])
 digest=sha(ref);assert m['reference']['sha256']==digest and m['reference']['bytes']==len(ref)
 for label,name in [('build_info','reference-build.json'),('cmake_cache','CMakeCache.txt')]:
  data=one(name).read_bytes();assert m['artifacts'][label]=={'bytes':len(data),'sha256':sha(data)}
 for label,path in [('manifest_tool','tests/llm-golden/vision/tools/reference_manifest.py'),('producer_source','tests/llm-golden/vision/tools/dump-encode.c'),('comparator_source','rebirth/src/rust/rebirth-llm/tests/vlm_golden.rs'),('image','tests/vision/red-square.png')]:
  data=readgit(path);assert m['artifacts'][label]=={'bytes':len(data),'sha256':sha(data)}
 pins={'upstream_archive':'da0a960b36505081df726d35552ae71e84c5b7da313d41d9c52055f0d85b0247','model':'5745685d2e607a82a0696c1118e56a2a1ae0901da450fd9cd4f161c6b62867d7','projector':'ecb20cabcdd8dbc277de06bd6eb980aeb2adfaaba9f199a434e328d205675d03'}
 assert all(m['artifacts'][k]['sha256']==v for k,v in pins.items())
 log=one('vlm-tests.log').read_text();loglines=log.splitlines()
 consumed=f'VISION_REFERENCE_CONSUMED sha256={digest} bytes={len(ref)} tokens=64 embedding=1536'
 success=f"VISION_REFERENCE_COMPARISON_PASSED sha256={digest} nonce={c['job_nonce']} source={head} run=37086507678 attempt=1 job=vision-golden"
 assert loglines.count(consumed)==1 and loglines.count(success)==1
 delta=re.search(r'embd-ATOL leg: max \|Δ\| = ([0-9.e+-]+) over 98304 values',log);assert delta and float(delta[1])<=1e-3
 assert 'T1 token-ids pin:' in log and log.count('test result: ok. 1 passed; 0 failed; 0 ignored;')==3
 async_log=one('async-vlm-tests.log').read_text();assert async_log.splitlines().count('ASYNC_VLM_BOUNDARIES_PASSED')==1
 child=one('vision-r-installed-child.log').read_text();assert re.search(r'VISION_INSTALLED_CHILD_OK source='+head+r' package=\S+/relm-vision-library/relm dll_sha256=[0-9a-f]{64}',child)
 assert '══ DONE ' in one('vision-r-tests.log').read_text()
 dest=out/c['runner_os'];dest.mkdir();files={}
 for f in p.rglob('*'):
  if not f.is_file():continue
  data=f.read_bytes();archive=gzip.compress(data,mtime=0);name=str(f.relative_to(p)).replace('/','--')+'.gz';(dest/name).write_bytes(archive)
  files[name]={'raw_sha256':sha(data),'raw_bytes':len(data),'archive_sha256':sha(archive)}
 summary['runners'].append({'os':c['runner_os'],'arch':c['runner_arch'],'source_sha':head,'reference':m['reference'],'max_abs_difference':float(delta[1]),'job_nonce':c['job_nonce'],'files':files})
assert {x['os'] for x in summary['runners']}=={'Linux','macOS'}
checks=json.loads(Path('/private/tmp/relm-maintenance/pr57-e280868-checks.json').read_text());assert checks['headRefOid']==head and len(checks['statusCheckRollup'])==9 and all(x['status']=='COMPLETED' and x['conclusion']=='SUCCESS' for x in checks['statusCheckRollup'])
(out/'ordinary-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
(out/'receipt.json').write_text(json.dumps(summary,indent=2)+'\n')
(out/'collector.py').write_bytes(Path(__file__).read_bytes())
print(json.dumps({'ordinary_checks':9,'vision_runners':[{k:v for k,v in x.items() if k!='files'} for x in summary['runners']]},indent=2))
