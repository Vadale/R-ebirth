from pathlib import Path
import csv,hashlib,json,math,struct,subprocess
repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth'); root=Path(__file__).parent
records={}
for line in (root/'precision/diagnostic.log').read_text().splitlines():
    if line.startswith(('F6E_CACHE_PRECISION_','F6E_PREFIX_DEBT_RUN ')):
        k,v=line.split(' ',1);records.setdefault(k,[]).append(json.loads(v))
assert {k:len(v) for k,v in records.items()}=={'F6E_CACHE_PRECISION_START':1,'F6E_CACHE_PRECISION_CONTEXT':3,'F6E_PREFIX_DEBT_RUN':3,'F6E_CACHE_PRECISION_COMPLETE':1}
rows=[x for x in csv.DictReader((repo/'tests/llm-golden/projection/goldens/forward-projections.csv').open()) if x['case']=='long_prefill']
sites={}
for x in rows:
    key=(int(x['layer']),x['component']); sites.setdefault(key,[]).append(x)
f32=lambda x:struct.unpack('<f',struct.pack('<f',x))[0]
results=[]
for context,run in zip(records['F6E_CACHE_PRECISION_CONTEXT'],records['F6E_PREFIX_DEBT_RUN']):
    assert context['id']==run['id'] and len(run['rows'])==44 and len(run['witnesses'])==1024
    assert len({(x[0],x[1]) for x in run['witnesses']})==1024 and all(x[2] for x in run['witnesses'])
    assert run['site_missing']==run['site_duplicates']==0
    log=context['native_log']['native_load_log'];kind='f32' if context['cache_type']==0 else 'f16'
    assert f'K ({kind})' in log and f'V ({kind})' in log
    assert ('flash_attn            = disabled' if context['flash_attn']==0 else 'flash_attn            = auto') in log
    maximum=0.; count=0
    for before in [x for x in run['rows'] if x['before']]:
        key=(before['layer'],before['component']);config=sites[key]
        direction=[float(x['direction']) for x in config]; coef=float(config[0]['coef'])
        after=[x for x in run['rows'] if not x['before'] and (x['layer'],x['component'],x['source_pos'])==(*key,before['source_pos'])]
        assert len(after)==1
        dot=math.fsum(x*d for x,d in zip(before['values'],direction))
        for value,actual,d in zip(before['values'],after[0]['values'],direction):
            expected=f32(value-(coef*d)*dot); error=abs(actual-expected)/(1+abs(expected))
            assert math.isfinite(error) and error<=2e-6;maximum=max(maximum,error);count+=1
    assert count==256
    results.append({'id':run['id'],'actual_cache_type':kind,'projection_values':count,'projection_scaled_error':maximum,
      'max_activation_reference_error':max(abs(x) for r in run['rows'] for x in r['signed_errors']),
      'max_logit_reference_error':max(map(abs,run['logit_signed_errors'])),'addends':run['failing_coordinate_addends']})
assert records['F6E_CACHE_PRECISION_COMPLETE'][0]['prefix_decode_calls']==3
source_paths=['rebirth/src/rust/rebirth-llm/src/engine.rs','rebirth/src/rust/rebirth-llm/src/projection_prefix_debt_diagnostic.rs']
receipt={'status':'observations_verified','scope':'New Linux CPU cache precision contrast; observations, not production correction/accuracy acceptance',
 'tiny_loads':1,'derived_handles':1,'new_test_contexts':3,'prefix_decode_calls':3,'prefix_tokens':1536,'same_row_comparisons':768,
 'results':results,'source_sha256':{p:hashlib.sha256((repo/p).read_bytes()).hexdigest() for p in source_paths}}
(root/'owner.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'status':receipt['status'],'comparisons':768,'results':[(r['id'],r['max_activation_reference_error']) for r in results]}))
