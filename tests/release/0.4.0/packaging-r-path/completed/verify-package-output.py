"""Read retained packaging artifacts; no compilation, models or package checks."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlparse, unquote
import hashlib,json,re,tarfile
B=Path('/private/tmp/relm-release-0.4.0')
P=B/'packaging-r-path'
R=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
status=json.loads((P/'status.json').read_text());assert status['status']=='awaiting_owner_verification'
for item in status['stages']:assert item['exit_code']==0 and sha(P/(item['name']+'.log'))==item['log_sha256']
src=json.loads((P/'source-manifest.json').read_text())
assert all(sha(P/'relm'/n)==h for n,h in src.items())
installed=json.loads((P/'installed-manifest.json').read_text())
assert all(sha(P/'library/relm'/n)==h for n,h in installed.items())
source=P/'relm_0.4.0.tar.gz';binary=P/'relm_0.4.0.tgz'
assert sha(source)==status['source_tarball_sha256'] and sha(binary)==status['binary_sha256']
with tarfile.open(source) as t: payload={m.name:t.extractfile(m).read() for m in t.getmembers() if m.isfile()}
repo_equal=[];generated=[];different=[]
for name,data in payload.items():
 rel=Path(name).relative_to('relm');p=R/'rebirth'/rel
 if p.is_file():
  if data==p.read_bytes():repo_equal.append(str(rel))
  else:different.append(str(rel))
 else:generated.append(str(rel))
assert different==['DESCRIPTION'],different
with tarfile.open(binary) as t:
 bfiles={str(Path(m.name).relative_to('relm')):hashlib.sha256(t.extractfile(m).read()).hexdigest() for m in t.getmembers() if m.isfile()}
assert all(installed.get(n)==h for n,h in bfiles.items()),'Binary/installed drift'
check=(P/'check/relm.Rcheck/00check.log').read_text()
assert 'Status: 2 WARNINGs, 2 NOTEs' in check and ' ERROR' not in check
for token in ['checking examples ... OK','checking package vignettes ... OK','checking PDF version of manual ... OK','checking Rust compilation ... OK']:
 assert token in check,token
raw=(P/'check/relm.Rcheck/tests/testthat.Rout').read_text()
assert '[ FAIL 0 | WARN 0 | SKIP 130 | PASS 5010 ]' in raw
link=(P/'check/relm.Rcheck/00install.out').read_text()
assert link.count('ld: warning: ignoring duplicate libraries:')==1
site=P/'site'
class Links(HTMLParser):
 def __init__(self):super().__init__();self.links=[];self.ids=set()
 def handle_starttag(self,tag,attrs):
  d=dict(attrs)
  if 'id' in d:self.ids.add(d['id'])
  for key in ['href','src']:
   if key in d:self.links.append(d[key])
parsed={}
for p in site.rglob('*.html'):
 h=Links();h.feed(p.read_text());parsed[p.resolve()]=h
missing=[];local=0
for p,h in parsed.items():
 for link in h.links:
  u=urlparse(link)
  if u.scheme or u.netloc or not u.path or u.path.startswith('/'):continue
  q=(p.parent/unquote(u.path)).resolve()
  if q.is_dir():q=q/'index.html'
  local+=1
  if not q.exists():missing.append([str(p.relative_to(site)),link])
assert not missing,missing
pages=['reference/llm_direction.html','reference/llm_apply_direction.html','reference/llm_compare.html','reference/llm_timeline.html','reference/plot.llm.html','articles/contrast-directions.html','articles/model-interventions.html']
assert all((site/p).stat().st_size>1000 for p in pages)
receipt=dict(status='verified_with_disclosed_diagnostics',source_files=len(src),installed_files=len(installed),raw_stage_logs=len(status['stages']),
 tar_files=len(payload),repository_byte_equal=len(repo_equal),generated_files=generated,metadata_changed=different,
 source_sha256=sha(source),binary_sha256=sha(binary),dll_sha256=sha(P/'library/relm/libs/relm.so'),binary_files_equal_installed=len(bfiles),
 package_check=dict(errors=0,warnings=['missing checkbashisms tool','pinned vendor nonportable/diagnostic pragmas'],notes=['new submission/tarball size','installed tidy too old for HTML validation']),
 tests=dict(passed=5010,failed=0,test_warnings=0,skipped=130,skip_scope='62 omitted native-fixture tests; 62 optional-model tests; 4 repository-only fixtures; 1 network download; 1 CRAN-gated model case'),
 additional_diagnostics=['one duplicate -lc++ linker warning','external testthat built under R4.5.2 while host is4.5.1','12 pkgdown examplesIf false model conditions'],
 html_pages=len(parsed),local_html_references=local,missing_local_references=missing,required_new_pages=pages,
 limits='HTML structural/link inspection, not browser interaction. Visual figures and actual RStudio smoke remain separate. No new model execution in verification.')
(B/'package-owner.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt,indent=2))
