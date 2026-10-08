from pathlib import Path
from html.parser import HTMLParser
import hashlib,json,tarfile,shutil,re,subprocess
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');B=Path('/private/tmp/relm-f6e')
O=B/'docs-package-20261008-133050';I=B/'evaluation-dependencies-20261008-123712'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
binding=json.loads((B/'docs-package-binding.json').read_text())
assert sha(B/'run-docs-package.py')==binding['driver_sha256']
for p,h in binding['files'].items():assert sha(p)==h,p
manifest=json.loads((O/'manifest.json').read_text())
for p,h in manifest.items():assert sha(O/p)==h,p
sources=json.loads((O/'source-manifest.json').read_text())
for p,h in sources.items():assert sha(R/p)==h,p
cfg=json.loads((I/'config.json').read_text())
for p,h in cfg['source_hashes'].items():assert sha(Path(p) if Path(p).is_absolute() else R/p)==h,p
for p,h in cfg['installed_hashes'].items():assert sha(Path(cfg['library'])/p)==h,p
status=json.loads((O/'status.json').read_text())
assert [x['name'] for x in status['stages']]==['vignette-contrast-directions','vignette-model-interventions','source-build','scoped-check']
assert all(x['exit_code']==0 and x['status']=='passed' for x in status['stages'])
check=(O/'relm.Rcheck/00check.log').read_text()
assert [x for x in check.splitlines() if x.startswith('* checking') and x.endswith('WARNING')]==[
 '* checking files in ‘vignettes’ ... WARNING','* checking package vignettes ... WARNING']
assert check.endswith('Status: 2 WARNINGs\n') and ' ERROR' not in check and ' NOTE' not in check
for item in ['checking examples ... OK','checking tests ... SKIPPED','checking running R code from vignettes ... SKIPPED']:
 assert item in check,item
class Document(HTMLParser):
 def __init__(self):super().__init__();self.ids=set();self.links=[];self.images=[];self.text=[];self.skip=0
 def handle_starttag(self,t,a):
  d=dict(a)
  if t in ('script','style'):self.skip+=1
  if 'id' in d:self.ids.add(d['id'])
  if t in ('a','link','script'):
   v=d.get('href',d.get('src'))
   if v:self.links.append(v)
  if t=='img':self.images.append(d['src'])
 def handle_endtag(self,t):
  if t in ('script','style'):self.skip-=1
 def handle_data(self,x):
  if not self.skip:self.text.append(x)
documents={}
for name,count in [('contrast-directions',1),('model-interventions',2)]:
 doc=Document();doc.feed((O/(name+'.html')).read_text());assert len(doc.images)==count
 for link in doc.links+doc.images:
  if link.startswith('#'):assert link[1:] in doc.ids,link
  elif not link.startswith(('https:','http:','data:','mailto:')):assert (O/link.split('#')[0].split('?')[0]).exists(),link
 text=' '.join(' '.join(doc.text).split());(O/(name+'-owner-text.txt')).write_text(text+'\n')
 if name=='contrast-directions':
  for item in ['Project a component direction','relm_direction/2','-0.2','0.4','1102.25','234.875','The result is modest.','consumed']:
   assert item in text,item
 else:
  for item in ['configured_projections','Static projection does not create additive steering revisions','synthetic']:
   assert item.lower() in text.lower(),item
 raw=(O/('vignette-'+name+'.log')).read_text()
 assert 'Output created: '+name+'.html' in raw and not re.search(r'Warning:|Error:|Execution halted',raw)
 documents[name]=dict(local_references=len(doc.links),images=count,missing_references=0,source_sha256=sha(R/'rebirth/vignettes'/(name+'.qmd')))
tar=O/'relm_0.3.0.tar.gz';matched=0;description=None
with tarfile.open(tar) as archive:
 for m in archive.getmembers():
  if not m.isfile():continue
  name=m.name.removeprefix('relm/');actual=archive.extractfile(m).read();source=R/'rebirth'/name
  assert source.is_file(),name
  if name=='DESCRIPTION':description=actual;continue
  assert actual==source.read_bytes(),name;matched+=1
assert matched==781 and description
(O/'built-DESCRIPTION').write_bytes(description)
# R CMD build's DCF wrapping/metadata additions are checked without execution.
def dcf(raw):
 fields={};key=None
 for line in raw.decode().splitlines():
  if line.startswith((' ','\t')):fields[key]+=' '+line.strip()
  elif line:
   key,value=line.split(':',1);fields[key]=value.strip()
 return {k:" ".join(v.split()) for k,v in fields.items()}
original=dcf((R/'rebirth/DESCRIPTION').read_bytes());built=dcf(description)
assert all(built[k]==v for k,v in original.items())
assert set(built)-set(original)=={'NeedsCompilation','Packaged','Author','Maintainer'} and built['NeedsCompilation']=='yes'
result=dict(status='PASS',stages=4,original_output_hashes=len(manifest),package_source_hashes=len(sources),
 accepted_source_hashes=len(cfg['source_hashes']),installed_hashes=len(cfg['installed_hashes']),
 source_tar_files=782,source_tar_exact_matches=matched,source_tar_sha256=sha(tar),
 description_delta='DCF wrapping plus NeedsCompilation/Packaged/Author/Maintainer from R CMD build; original fields unchanged',
 documents=documents,visual_inspection='Three emitted PNGs individually inspected, legible synthetic labels/axes and retained-history notices. HTML contents and all local references checked; no browser interaction claim.',
 errors=0,warnings=2,notes=0,warning_scope='Only deliberately omitted bundled-vignette warnings; both changed documents executed separately',
 models=0,native_builds=0,installed_package='Existing exact accepted library; no reinstall',
 tests='Accepted suites not rerun; R CMD check examples passed with model environment variables removed',
 original_status_preserved='awaiting_owner_verification')
(O/'owner-verification.json').write_text(json.dumps(result,indent=2)+'\n')
A=R/'tests/projection/measurements'/O.name;A.mkdir(exist_ok=False)
# Preserve the complete original run, including source tar and extracted check tree.
with tarfile.open(A/'original-run.tar.gz','w:gz') as a:a.add(O,arcname=O.name)
for p in [O/'owner-verification.json',O/'manifest.json',O/'source-manifest.json',O/'status.json',O/'relm.Rcheck/00check.log',B/'run-docs-package.py',B/'docs-package-binding.json',B/'docs-package-launch.json',Path(__file__)]:shutil.copy2(p,A/p.name)
(A/'archive-manifest.json').write_text(json.dumps({p.name:sha(p) for p in A.iterdir() if p.is_file()},indent=2)+'\n')
print(json.dumps(dict(**result,archive_manifest_sha256=sha(A/'archive-manifest.json'))))
