from pathlib import Path
import struct,json,hashlib
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
model=Path('/Users/alessandrovadala/Library/Caches/org.R-project.R/R/relm/qwen2.5-0.5b-instruct-q8_0.gguf')
base=Path('/private/tmp/relm-f6e/evaluation-20261008-115751')
formats={0:'B',1:'b',2:'H',3:'h',4:'I',5:'i',6:'f',7:'?',10:'Q',11:'q',12:'d'}
with model.open('rb') as f:
 def integer(fmt):
  raw=f.read(struct.calcsize('<'+fmt));assert len(raw)==struct.calcsize('<'+fmt);return struct.unpack('<'+fmt,raw)[0]
 def string():
  n=integer('Q');raw=f.read(n);assert len(raw)==n;return raw.decode('utf-8')
 def value(kind, retain=False):
  if kind==8:return string()
  if kind==9:
   element=integer('I');n=integer('Q');result=[]
   for i in range(n):
    x=value(element)
    if retain and i in (128247,151643,151645):result.append(dict(zero_based_id=i,value=x))
   return dict(element_type=element,length=n,selected=result)
  return integer(formats[kind])
 assert f.read(4)==b'GGUF';version=integer('I');tensors=integer('Q');count=integer('Q');metadata={}
 for _ in range(count):
  key=string();kind=integer('I');x=value(kind,key in ('tokenizer.ggml.tokens','tokenizer.ggml.token_type'))
  if key.startswith('tokenizer.ggml.') and key!='tokenizer.ggml.merges':metadata[key]=x
 end=f.tell()
with model.open('rb') as f:metadata_hash=hashlib.sha256(f.read(end)).hexdigest()
source=repo/'rebirth/src/llama.cpp/src/llama-vocab.cpp';sourcehash=hashlib.sha256(source.read_bytes()).hexdigest()
scope=json.loads((repo/'tests/projection/instrumented-scope.json').read_text())
assert scope['source_hashes']['rebirth/src/llama.cpp/src/llama-vocab.cpp']==sourcehash
modelhash=hashlib.sha256(model.read_bytes()).hexdigest();assert modelhash=='ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e'
assert metadata['tokenizer.ggml.tokens']['selected'][0]==dict(zero_based_id=128247,value='</s>')
assert metadata['tokenizer.ggml.token_type']['selected'][0]==dict(zero_based_id=128247,value=1)
receipt=dict(model_sha256=modelhash,gguf_version=version,tensors=tensors,metadata_entries=count,metadata_bytes=end,
 metadata_sha256=metadata_hash,metadata=metadata,vocab_source_sha256=sourcehash,
 diagnosis='Pinned GGUF stores zero-based token 128247 </s> as NORMAL (1). The unchanged loader adds it to EOG and ORs CONTROL, emitting this warning. This is runtime tokenizer semantics, not a compiler warning or projection defect; no claim of no output effect.',
 evidence_scope='Metadata inspected without model load/inference. Failed attempt has one model load and zero trace/generation/derive/tokenization attempts.')
(base/'token-warning-diagnosis.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt,indent=2))
