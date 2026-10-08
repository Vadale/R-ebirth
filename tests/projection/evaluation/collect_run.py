#!/usr/bin/env python3
"""Execution-bound F6e collector: no inference, no product imports, no retuning."""
import csv
import hashlib
import importlib.util
import io
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]

def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module
v = load_module('f6e_verifier', HERE / 'verify_results.py')
reference = load_module('f6d_encoding_only', REPO / 'tests/llm-golden/directions/reference_directions.py')

def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def write_json(path, value): Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False)+'\n')
def read_json(path): return json.loads(Path(path).read_text())
def descriptor(root, name): return dict(file=name, sha256=sha(root/name))
def require(ok, message):
    if not ok: raise ValueError(message)
def write_csv(path, columns, rows):
    with Path(path).open('w', newline='', encoding='utf-8') as f:
        w=csv.DictWriter(f, fieldnames=columns, lineterminator='\n');w.writeheader();w.writerows(rows)

TOKEN_WARNING = "[3] load: control-looking token: 128247 '</s>' was not control-type; this is probably a bug in the model. its type will be overridden"
TOKEN_DIAGNOSIS_SHA = 'befbfb9501178b798872e61e2bf9966845579cb37263c5a51a7bf2992db059b9'

def cpu_receipt(raw, diagnosis=None):
    text=raw.decode('utf-8', errors='strict')
    offloads=re.findall(r'offloaded ([0-9]+)/([0-9]+) layers to GPU',text)
    require(offloads == [('0','25')], 'missing/extra/nonzero actual CPU offload receipt')
    buffers=re.findall(r'\b(\S+)\s+(model|KV|compute) buffer size\s*=\s*([0-9.]+) MiB',text)
    require(buffers and {row[1] for row in buffers} == {'model','KV','compute'}, 'missing actual buffer categories')
    require(all(row[0].startswith('CPU') and float(row[2]) >= 0 for row in buffers), 'non-CPU buffer placement')
    warnings=re.findall(r'^\[3\].*$',text,re.M)
    require(not re.search(r'^\[4\]',text,re.M), 'native load error requires diagnosis')
    if diagnosis is None:
        require(not warnings, 'native load warning requires diagnosis')
    else:
        require(diagnosis['model_sha256']==v.MODEL_SHA and
                diagnosis['metadata_sha256']=='ce98a193e9d08aa64d049e21af5be38dc7582f0b570baeb20d0422b0aa536dea' and
                diagnosis['vocab_source_sha256']=='33a3ac4e52bebb21101d0228e9ff5dbde34e7e4d119334a09e7d9e09f915423f',
                'tokenizer diagnosis identity mismatch')
        metadata=diagnosis['metadata']
        require(metadata['tokenizer.ggml.tokens']['selected'][0]==dict(zero_based_id=128247,value='</s>') and
                metadata['tokenizer.ggml.token_type']['selected'][0]==dict(zero_based_id=128247,value=1) and
                metadata['tokenizer.ggml.eos_token_id']==151645, 'diagnosed token metadata mismatch')
        require(warnings==[TOKEN_WARNING], 'new/missing/duplicate native warning requires diagnosis')
    return dict(backend='cpu',n_gpu_layers=0,model_sha256=v.MODEL_SHA,
        actual_offload_layers=0,actual_total_layers=25,
        buffers=[dict(name=a,kind=b,MiB=float(c)) for a,b,c in buffers],
        retained_warnings=warnings, tokenizer_caveat=(diagnosis['diagnosis'] if diagnosis else None),
        scope='actual load-time native buffer/offload messages; not loaded-weight authentication')

def decode_node(node):
    tag,value=node
    double=lambda x:struct.unpack('<d',bytes.fromhex(x))[0]
    if tag=='D': value=double(value)
    elif tag=='d': value=[double(x) for x in value]
    elif tag in ('R','F'): value=[[name,decode_node(child)] for name,child in value]
    elif tag=='M': value=[*value[:4],[double(x) for x in value[4]]]
    return [tag,value]

def check_construction(root):
    results={}
    for key in ('residual','mlp','random_mlp'):
        data=read_json(root/'artifacts'/f'{key}-typed.json')
        nodes={name:decode_node(data[name]) for name in ('target','control','pairs','splits','values','payload')}
        expected_schema='relm_direction/1' if key=='residual' else 'relm_direction/2'
        require(data['schema']==expected_schema,'wrong artifact schema')
        actual_digests={}
        for name,node in nodes.items():
            domain={'target':'matrix','control':'matrix','payload':'artifact'}.get(name,name)
            h=hashlib.sha256();h.update(expected_schema.encode()+b'\0')
            for raw in reference.encode(['S',domain]): h.update(raw)
            for raw in reference.encode(node): h.update(raw)
            actual_digests[name]=h.hexdigest()
            require(actual_digests[name]==data['digests'][name],f'independent canonical mismatch {key}/{name}')
        nr,nc,labels,coords,target=nodes['target'][1]
        other=nodes['control'][1]
        require(nr==12 and nc==896 and other[:4]==nodes['target'][1][:4], 'matrix identity/shape')
        require(labels==[f'f6e-c{i:02}' for i in range(1,13)] and coords==[str(i) for i in range(1,897)],'matrix coordinates')
        control=other[4]
        # Separate scalar math.fsum arithmetic, not a call to product arithmetic.
        mean=[math.fsum((target[i*nc+j]-control[i*nc+j])/nr for i in range(nr)) for j in range(nc)]
        norm=math.sqrt(math.fsum(x*x for x in mean));require(norm>0 and math.isfinite(norm),'degenerate construction')
        expected=[x/norm for x in mean]
        fields=dict(nodes['values'][1]);actual=fields['value'][1]
        require(fields['neuron'][1]==list(range(1,897)),'artifact coordinates')
        errors=[abs(a-b) for a,b in zip(actual,expected)]
        require(len(actual)==896 and all(e<=1e-12*(1+abs(b)) for e,b in zip(errors,expected)),'construction arithmetic mismatch')
        results[key]=dict(values=896,maximum_absolute_error=max(errors),bound='1e-12*(1+abs(expected))',digests=actual_digests)
    # Bind the randomized matrices themselves, not just swapped provenance.
    source=decode_node(read_json(root/'artifacts/mlp-typed.json')['target'])[1][4]
    control=decode_node(read_json(root/'artifacts/mlp-typed.json')['control'])[1][4]
    random=read_json(root/'artifacts/random_mlp-typed.json')
    rt=decode_node(random['target'])[1][4];rc=decode_node(random['control'])[1][4]
    with (root/'random-signs.csv').open() as stream: signs=list(csv.DictReader(stream))
    for i,row in enumerate(signs):
        sl=slice(i*896,(i+1)*896);a,b=(source,control) if int(row['sign'])==1 else (control,source)
        require(rt[sl]==a[sl] and rc[sl]==b[sl], 'random control is not the actual pair swap')
    return dict(status='PASS',artifacts=results,random_rows=12,model_calls=0,
        scope='new captured-data arithmetic and canonical encoding; no reference fixtures regenerated or rerun')

def source_snapshot(root, cfg, output):
    rows=[]
    for name,expected in sorted(cfg['source_hashes'].items()):
        path=REPO/name if not name.startswith('/') else Path(name)
        require(sha(path)==expected,'source drift: '+name)
        dest='source-snapshots/'+expected
        if not (root/dest).exists():
            (root/dest).parent.mkdir(exist_ok=True);(root/dest).write_bytes(path.read_bytes())
        rows.append(dict(source=name,snapshot_file=dest,sha256=expected))
    write_csv(root/output,v.SOURCE_COLUMNS,rows)
    for name,expected in cfg['installed_hashes'].items(): require(sha(Path(cfg['library'])/name)==expected,'installed drift: '+name)

def receipt(root,cfg,complete):
    runtime=read_json(root/'runtime.json')
    identity=dict(model_sha256=v.MODEL_SHA,backend='cpu',context_length=512,layer=12,
        package_version=runtime['package_version'],engine_revision=runtime['engine_revision'],
        source_revision=cfg['source_revision'],r_version=runtime['r_version'],dll_sha256=cfg['dll_sha256'],
        cpu_evidence=descriptor(root,'cpu-evidence.json'),installed_evidence=descriptor(root,'installed-evidence.json'))
    names={'sources_before':'sources-before.csv','sources_after':'sources-after.csv',
        'construction':'construction.csv','artifact_pairs':'artifact-pairs.csv','random_signs':'random-signs.csv',
        'bootstrap':'bootstrap.csv','selection':'selection.csv',
        'evaluation':'evaluation.csv','views':'views.csv','view_states':'view-states.csv','selection_lock':'selection-lock.json'}
    later={'evaluation','views','view_states','selection_lock'}
    return dict(schema=v.SCHEMA_VERSION,protocol_sha256=v.PROTOCOL_SHA,manifest_sha256=v.MANIFEST_SHA,
        prompts_sha256=v.PROMPTS_SHA,identity=identity,rng=v.SCHEMA['rng_exact_fields'],
        producer_sources=cfg['producer_sources'],
        artifacts={k:descriptor(root,f'artifacts/{k}.rds') for k in ('residual','mlp','random_mlp')},
        files={k:None if k in later and not complete else descriptor(root,n) for k,n in names.items()})

def main(stage,root):
    root=Path(root).resolve();cfg=read_json(root/'config.json')
    if stage=='cpu':
        diagnosis=root/'token-warning-diagnosis.json'
        require(sha(diagnosis)==TOKEN_DIAGNOSIS_SHA,'tokenizer diagnosis receipt changed')
        require(cfg['source_hashes']['rebirth/src/llama.cpp/src/llama-vocab.cpp']==read_json(diagnosis)['vocab_source_sha256'],'diagnosed loader source changed')
        data=(root/'native-placement.log').read_bytes();result=cpu_receipt(data,read_json(diagnosis))
        (root/'placement-load.log').write_bytes(data)
        result['raw_log']=descriptor(root,'placement-load.log')
        result['tokenizer_diagnosis']=descriptor(root,'token-warning-diagnosis.json')
        require(read_json(root/'loaded-metadata.json')['backend']=='cpu','loaded backend mismatch')
        write_json(root/'cpu-evidence.json',result)
    elif stage=='construction': write_json(root/'construction-verification.json',check_construction(root))
    elif stage in ('selection','complete'):
        source_snapshot(root,cfg,'sources-after.csv')
        write_json(root/'receipt.json',receipt(root,cfg,stage=='complete'))
        report=root/(stage+'-report.json')
        require(not report.exists(),'refuse overwritten result report')
        result=v.verify_bundle(root,stage,cfg['rscript']);write_json(report,result)
        if stage=='selection':
            require(not (root/'selection-lock.json').exists(),'selection already locked')
            write_json(root/'selection-lock.json',dict(schema='F6e-selection-lock/1',
                selected_add=result['selected']['add'],selected_project=result['selected']['project'],
                selection_evidence_sha256=result['selection_evidence_sha256'],
                selection_report=descriptor(root,'selection-report.json'),verifier_sha256=sha(HERE/'verify_results.py'),
                locked_at_unix=time.time()))
        print(f'F6E_EVALUATION_COLLECTED stage={stage} observations={result["observations"]}',flush=True)
    else: raise ValueError('unknown collector stage')

if __name__=='__main__':
    require(len(sys.argv)==3,'stage and bundle required');main(sys.argv[1],sys.argv[2])
