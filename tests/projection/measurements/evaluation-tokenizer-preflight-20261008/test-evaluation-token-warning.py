from pathlib import Path
import ast,copy,hashlib,importlib.util,json,sys
root=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth');old=Path('/private/tmp/relm-f6e/evaluation-20261008-115751')
spec=importlib.util.spec_from_file_location('collector',root/'tests/projection/evaluation/collect_run.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
raw=(old/'native-placement.log').read_bytes();diagnosis=json.loads((old/'token-warning-diagnosis.json').read_text())
assert c.sha(old/'token-warning-diagnosis.json')==c.TOKEN_DIAGNOSIS_SHA
r=c.cpu_receipt(raw,diagnosis);assert r['retained_warnings']==[c.TOKEN_WARNING] and r['actual_offload_layers']==0
bad=[]
bad.append((raw,None))
bad.append((raw+b'\n[3] new warning\n',diagnosis))
bad.append((raw+b'\n[4] new error\n',diagnosis))
bad.append((raw+b'\n'+c.TOKEN_WARNING.encode()+b'\n',diagnosis))
bad.append((raw.replace(c.TOKEN_WARNING.encode(),b'[3] changed warning'),diagnosis))
bad.append((raw.replace(c.TOKEN_WARNING.encode(),b''),diagnosis))
bad.append((raw.replace(b'offloaded 0/25',b'offloaded 1/25'),diagnosis))
bad.append((raw.replace(b'CPU KV buffer',b'MTL0 KV buffer'),diagnosis))
for field in ('model_sha256','metadata_sha256','vocab_source_sha256'):
 d=copy.deepcopy(diagnosis);d[field]='0'*64;bad.append((raw,d))
for path,key,value in [('tokenizer.ggml.tokens','value','other'),('tokenizer.ggml.token_type','value',3),('tokenizer.ggml.tokens','zero_based_id',12)]:
 d=copy.deepcopy(diagnosis);d['metadata'][path]['selected'][0][key]=value;bad.append((raw,d))
d=copy.deepcopy(diagnosis);d['metadata']['tokenizer.ggml.eos_token_id']=0;bad.append((raw,d))
for i,(stream,d) in enumerate(bad):
 try:c.cpu_receipt(stream,d)
 except ValueError:continue
 raise AssertionError(f'Negative {i} was accepted')
# Existing transport, source, receipt, arithmetic functions did not change.
cfg=json.loads((old/'config.json').read_text());digest=cfg['source_hashes']['tests/projection/evaluation/collect_run.py']
before=ast.parse((old/'source-snapshots'/digest).read_text());after=ast.parse((root/'tests/projection/evaluation/collect_run.py').read_text())
a={n.name:ast.dump(n,include_attributes=False) for n in before.body if isinstance(n,ast.FunctionDef)}
b={n.name:ast.dump(n,include_attributes=False) for n in after.body if isinstance(n,ast.FunctionDef)}
unchanged=[name for name in a if name not in ('cpu_receipt','main')]
assert all(a[name]==b[name] for name in unchanged)
print('F6E_TOKEN_WARNING_COLLECTOR positive=1 negative='+str(len(bad))+' unchanged_functions='+str(len(unchanged))+' model_calls=0 inference=0')
print(json.dumps(r,indent=2))
