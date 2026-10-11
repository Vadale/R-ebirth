from pathlib import Path
import csv,hashlib,json,math,struct
root=Path(__file__).parent;repo=Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
f32=lambda x:struct.unpack('<f',struct.pack('<f',x))[0]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources=json.loads((root/'source-hashes.json').read_text());assert all(sha(repo/n)==v for n,v in sources.items())
projection=list(csv.DictReader((repo/'tests/llm-golden/projection/goldens/forward-projections.csv').open()))
artifacts={}
for label,cases,values,same in [('forward',15,34748,2944),('microbatches',3,10042,704)]:
 text=(root/(label+'.log')).read_text();assert 'test result: ok. 1 passed; 0 failed; 0 ignored;' in text and 'warning:' not in text
 def markers(k):return [json.loads(l.split(' ',1)[1]) for l in text.splitlines() if l.startswith(k+' ')]
 terminal,=markers('F6E_PROJECTION_TEST');assert (terminal['executed_cases'],terminal['compared_values'])==(cases,values)
 row,=markers('F6E_PROJECTION_SAME_ROW');assert row['compared_values']==same and row['max_scaled_error']<=2e-6
 guard,=markers('F6E_DEFAULT_LONG_PREFILL');assert guard['whole_forward_reference_acceptance'] is False
 assert (guard['rows'],guard['tokens'],guard['witnesses'],guard['same_row_values'])==(66,514,1028,384)
 assert len(guard['observed'])==66
 count=0;maximum=0.
 for before in [x for x in guard['observed'] if x['before']]:
  cfg=[x for x in projection if x['case']=='long_prefill' and int(x['layer'])==before['layer']+1 and x['component']==before['component']]
  assert len(cfg)==32
  d=[float(x['direction']) for x in cfg];coef=float(cfg[0]['coef'])
  after,=[x for x in guard['observed'] if not x['before'] and (x['layer'],x['component'],x['position'])==(before['layer'],before['component'],before['position'])]
  dot=math.fsum(a*b for a,b in zip(before['values'],d))
  for a,actual,direction in zip(before['values'],after['values'],d):
   expected=f32(a-(coef*direction)*dot);error=abs(actual-expected)/(1+abs(expected));assert error<=2e-6;maximum=max(error,maximum);count+=1
 assert count==384
 precision,=markers('F6E_REFERENCE_PRECISION');assert precision['case']=='long_prefill' and precision['cache']=='f32' and precision['attention']=='disabled' and precision['absolute_bound']==.01
 native=precision['context']['native_load_log'];assert 'K (f32)' in native and 'V (f32)' in native and 'flash_attn            = disabled' in native
 zero=[l for l in text.splitlines() if l.startswith('F6E_ZERO_POLICY_IDENTITY ')]
 assert len(zero)==(3 if label=='microbatches' else 0)
 artifacts[label]={'cases':cases,'oracle_values':values,'same_input_values':same,'default_long_prefill_values':count,'default_independent_scaled_error':maximum,'oracle_max_abs':terminal['max_abs_error'],'zero_policies':6 if label=='microbatches' else 0,'zero_values':576 if label=='microbatches' else 0}
assert all(x['exit_code']==0 for x in json.loads((root/'status.json').read_text())['stages'])
assert 'warning:' not in (root/'clippy.log').read_text()
receipt={'status':'passed','scope':'Affected Mac CPU tests; only long_prefill oracle path uses F32/unfused; default operator guard remains separate; Linux final CI pending','results':artifacts,'source_sha256':sources,'reference_manifest_sha256':sha(repo/'tests/llm-golden/projection/goldens/manifest.csv'),'log_sha256':{p.name:sha(p) for p in root.glob('*.log')}}
assert receipt['reference_manifest_sha256']=='78729e5fe710e30dffa83e76a9d084ee15091a0ef7074230172c3293f2463959'
(root/'owner.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'status':receipt['status'],'results':artifacts}))
