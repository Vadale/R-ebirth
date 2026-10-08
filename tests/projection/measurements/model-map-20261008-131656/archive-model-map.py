from pathlib import Path
import hashlib,json,csv,subprocess,shutil,re
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');B=Path('/private/tmp/relm-f6e')
I=B/'evaluation-dependencies-20261008-123712';O=B/'model-map-20261008-131656'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
binding=json.loads((B/'model-map-binding.json').read_text())
assert sha(B/'run-model-map.py')==binding['driver_sha256']
for p,h in binding['files'].items():assert sha(p)==h,p
manifest=json.loads((O/'manifest.json').read_text())
for p,h in manifest.items():assert sha(O/p)==h,p
cfg=json.loads((I/'config.json').read_text())
for p,h in cfg['source_hashes'].items():assert sha(Path(p) if Path(p).is_absolute() else R/p)==h,p
for p,h in cfg['installed_hashes'].items():assert sha(Path(cfg['library'])/p)==h,p
assert sha(cfg['model'])==cfg['model_sha256'] and sha(cfg['logger'])==cfg['logger_sha256']
rows=list(csv.DictReader((O/'cases.csv').open()))
assert [x['case'] for x in rows]==binding['expected_cases']
assert [x['refusal'] for x in rows]==['FALSE']*5+['TRUE','FALSE']
raw=(O/'model-map.log').read_text();native=(O/'native-placement.log').read_text()
warning="load: control-looking token: 128247 '</s>' was not control-type; this is probably a bug in the model. its type will be overridden"
expected=warning+'\n'+''.join(f"F6E_MODEL_MAP_CASE {x['case']} refusal={x['refusal']}\n" for x in rows)+'F6E_MODEL_MAP_COMPLETE cases=7 refusals=1 load_attempts=1 derive_attempts=1 generation_attempts=0\n'
assert raw==expected,'unexpected R/runtime diagnostic'
assert re.findall(r'^\[3\].*$',native,re.M)==['[3] '+warning]
assert not re.search(r'^\[4\]',native,re.M)
assert re.findall(r'offloaded (\d+)/(\d+) layers to GPU',native)==[('0','25')]
buffers=re.findall(r'\b(\S+)\s+(model|KV|compute) buffer size\s*=\s*([0-9.]+) MiB',native)
assert {b[1] for b in buffers}=={'model','KV','compute'} and all(b[0].startswith('CPU') for b in buffers)
with (O/'owner-data.log').open('w') as log:
 p=subprocess.run(['/usr/local/bin/Rscript','--vanilla',str(B/'verify-model-map-owner.R'),str(O)],stdout=log,stderr=subprocess.STDOUT,timeout=30)
assert p.returncode==0,'independent RDS/CSV inspection failed'
result=dict(status='PASS',cases=7,refusals=1,source_hashes=len(cfg['source_hashes']),installed_hashes=len(cfg['installed_hashes']),
 original_output_hashes=len(manifest),rows=9,columns=6,configured_projection='layer12/mlp_out',
 load_attempts=1,derive_attempts=1,generation_attempts=0,logits_attempts=0,trace_attempts=0,tokenize_attempts=0,
 native_offload='0/25; CPU model/KV/compute messages verified',native_warning=warning,R_warnings=0,native_errors=0,
 visual_inspection='PASS: actual configured MLP[P1], P/S/A counts, omitted layers and static/metadata legend legible and unclipped; PNG individually inspected. PDF uses identical recipe/table.',
 original_status_preserved='awaiting_visual_verification',scope='Actual loaded/configured owners and public graphics; no new efficacy or timing evidence')
(O/'owner-verification.json').write_text(json.dumps(result,indent=2)+'\n')
A=R/'tests/projection/measurements'/O.name;A.mkdir(exist_ok=False)
for p in O.iterdir():
 if p.is_file():shutil.copy2(p,A/p.name)
for p in [B/'run-model-map.py',B/'model-map-binding.json',B/'model-map-launch.json',B/'model-map-status.json',B/'verify-model-map-owner.R',Path(__file__),R/'tests/projection/evaluation/model-map.R']:
 shutil.copy2(p,A/p.name)
(A/'archive-manifest.json').write_text(json.dumps({p.name:sha(p) for p in A.iterdir() if p.is_file()},indent=2)+'\n')
print(json.dumps(dict(**result,archive_manifest_sha256=sha(A/'archive-manifest.json'))))
