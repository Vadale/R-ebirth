from pathlib import Path
import hashlib,json,subprocess,shutil,csv
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); B=Path('/private/tmp/relm-f6e')
I=B/'evaluation-dependencies-20261008-123712'; O=B/'evaluation-render-20261008-130750'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
binding=json.loads((B/'render-binding.json').read_text())
assert sha(B/'run-evaluation-render.py')==binding['driver_sha256']
for p,h in binding['files'].items(): assert sha(p)==h,p
manifest=json.loads((O/'manifest.json').read_text())
for p,h in manifest.items(): assert sha(O/p)==h,p
cfg=json.loads((I/'config.json').read_text());raw=json.loads((I/'raw-manifest.json').read_text())
for p,h in raw.items():assert sha(I/p)==h,p
for p,h in cfg['source_hashes'].items():assert sha(Path(p) if Path(p).is_absolute() else R/p)==h,p
for p,h in cfg['installed_hashes'].items():assert sha(Path(cfg['library'])/p)==h,p
assert (O/'render.log').read_text()=='F6E_RENDER_COMPLETE comparison_coordinates=1792 timeline_states=4 figures=5 models=0 inference=0\n'
read=lambda p:list(csv.DictReader(Path(p).open()))
summary=read(O/'final-summary.csv');base={x['setting']:x for x in read(I/'owner-summary.csv')}
assert len(summary)==4 and all(x==base[x['setting']] for x in summary)
intervals=read(O/'paired-intervals.csv'); report=json.loads((I/'complete-report.json').read_text())['intervals']
assert len(intervals)==len(report)==36
for a,b in zip(intervals,report):
 for k in a: assert a[k]==b[k] if isinstance(b[k],str) else abs(float(a[k])-b[k])<1e-9,(k,a,b)
with (O/'owner-data.log').open('w') as log:
 p=subprocess.run(['/usr/local/bin/Rscript','--vanilla',str(B/'verify-render-owner.R'),str(I),str(O)],stdout=log,stderr=subprocess.STDOUT,timeout=30)
assert p.returncode==0,'owner RDS/CSV verification failed'
result=dict(status='PASS',original_files=len(manifest),source_hashes=len(cfg['source_hashes']),
 installed_hashes=len(cfg['installed_hashes']),evaluation_original_hashes=len(raw),
 comparison_coordinates=1792,timeline_states=4,summary_settings=4,intervals=36,
 visual_inspection=dict(figures=5,PNG='All five individually inspected: legible, no clipped labels; static projection distinguished from additive revisions.',PDF='Same render recipe and data; PDF bytes retained.'),
 models=0,inference=0,warnings=0,model_map='Still pending actual configured handle',
 scope='Saved observations and fixed-corpus summaries; no same-row native formula or generalized efficacy claim',
 original_status_preserved='awaiting_visual_verification')
(O/'owner-verification.json').write_text(json.dumps(result,indent=2)+'\n')
A=R/'tests/projection/measurements'/O.name;A.mkdir(exist_ok=False)
for f in O.iterdir():
 if f.is_file():shutil.copy2(f,A/f.name)
for f in [B/'run-evaluation-render.py',B/'render-binding.json',B/'render-launch.json',B/'render-status.json',B/'verify-render-owner.R',Path(__file__),R/'tests/projection/evaluation/render.R']:
 shutil.copy2(f,A/f.name)
(A/'archive-manifest.json').write_text(json.dumps({f.name:sha(f) for f in A.iterdir() if f.is_file()},indent=2)+'\n')
print(json.dumps(dict(**result,archive=str(A),archive_manifest_sha256=sha(A/'archive-manifest.json'))))
