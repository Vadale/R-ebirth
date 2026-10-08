"""Owner verification of retained completed stages, never a native/model rerun."""
from pathlib import Path
import hashlib,importlib.util,json,re,sys,tarfile
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); root=Path('/private/tmp/relm-f6e');run=root/'feasibility-pruning-20261007-224427'
spec=importlib.util.spec_from_file_location('retained_driver',run/'verify-feasibility-pruning.py');d=importlib.util.module_from_spec(spec);sys.modules[spec.name]=d;spec.loader.exec_module(d)
s=json.loads((run/'status.json').read_text());m=json.loads((run/'source-manifest.json').read_text());source=d.digest(run/'source-manifest.json')
assert source==s['source_manifest_sha256'] and s['status']=='failed' and s['source_drift']==[]
assert all(d.digest(repo/n)==h for n,h in m.items())
for st in s['stages']:assert d.digest(run/(st['name']+'.log'))==st['log_sha256']
ready=json.loads((run/'native-ready.json').read_text())
with tarfile.open(run/'changed-source.tar.gz') as archive:
 for n,h in ready['source_hashes'].items():
  if not n.startswith('rebirth/'):continue
  assert hashlib.sha256(archive.extractfile(n).read()).hexdigest()==h
receipts=[]
for index in (7,8,9):
 log=(run/f'native-{index:02}.log').read_text();d.test_result(log,1)
 marker=d.markers(log,'F6E_PROJECTION_TEST');assert len(marker)==1;d.test_receipt(marker[0],d.TEST_IDS[index-1],source);receipts+=marker
 assert not re.search(r'warning:|warning\[',log)
 if index==7:
  same=d.markers(log,'F6E_PROJECTION_SAME_ROW');assert len(same)==1;d.verify_same_row(same[0],d.TEST_IDS[6],'cpu',source)
  p=d.markers(log,'F6E_PROJECTION_PRUNING');assert len(p)==1
  pruning=d.pruning.verify_pruning(p[0],d.markers(log,'F6E_PROJECTION_PRUNING_CASE'),source,d)
log=(run/'benchmark-cpu.log').read_text();d.test_result(log,1)
cpu=d.markers(log,'F6E_PROJECTION_BENCH');d.verify_benchmark(cpu,'cpu',source,log)
assert not re.search(r'warning:|warning\[',log)
metal=(run/'benchmark-metal.log').read_text();assert len(d.markers(metal,'F6E_PROJECTION_BENCH'))==0 and len(d.markers(metal,'F6E_PROJECTION_SAMPLE'))==0
assert 'native_status=-6' in metal and '0 passed; 1 failed' in metal
for name in ('format','clippy','no-spill-compile'):assert not re.search(r'warning:|warning\[',(run/(name+'.log')).read_text())
out=dict(status='partial_stages_verified_overall_failed',source_manifest_sha256=source,sources_verified=len(m),executed_native_tests=3,native_receipts=receipts,pruning=pruning,same_row=same[0],cpu_benchmark=dict(samples=len(cpu[0]['samples']),tokens_per_sample=128,mode_order=cpu[0]['mode_order'],medians_seconds=cpu[0]['median_elapsed_seconds'],dormant_ratio=cpu[0]['dormant_ratio'],dormant_limit=1.05,backend=cpu[0]['hooked_backend']['compute_buffers_mib']),metal=dict(status='failed_before_timing',test_passes=0,timing_samples=0,reason='native_status=-6 producer/layout/alias/buffer refusal during tiny-model derive probe; detailed cause requires source/actual buffer evidence'),warnings=0,public_feature_acceptance=False)
(run/'owner-verification.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps({k:out[k] for k in ['status','source_manifest_sha256','sources_verified','cpu_benchmark','metal']}))
