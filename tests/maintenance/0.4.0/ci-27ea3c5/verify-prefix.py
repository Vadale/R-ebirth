from pathlib import Path
import hashlib, json, math, struct, subprocess
r=Path('/private/tmp/relm-maintenance-040/ci-27ea3c5')
records={}
for line in (r/'prefix/diagnostic.log').read_text().splitlines():
    if line.startswith('F6E_PREFIX_DEBT_'):
        key, value=line.split(' ',1);records.setdefault(key,[]).append(json.loads(value))
assert {k:len(v) for k,v in records.items()} == {'F6E_PREFIX_DEBT_START':1,'F6E_PREFIX_DEBT_RUN':7,'F6E_PREFIX_DEBT_PAIR':5,'F6E_PREFIX_DEBT_COMPLETE':1}
runs={v['id']:v for v in records['F6E_PREFIX_DEBT_RUN']}
default=runs['active/default']
f32=lambda x:struct.unpack('<f',struct.pack('<f',x))[0]
audited=[x for x in runs.values() if x['audit']]
assert len(audited)==5
for run in audited:
    assert len(run['rows'])==44 and sum(len(x['values']) for x in run['rows'])==1408
    assert len(run['witnesses'])==1024 and len({(x[0],x[1]) for x in run['witnesses']})==1024
    assert all(math.isfinite(x) for row in run['rows'] for x in row['values'])
    assert run['same_row_values']==256 and run['same_row_max_scaled_error']==0
    a=run['failing_coordinate_addends']['values']
    assert f32(f32(a[0]+a[1])+a[2])==a[3]
for right in ['active/repeat','active/four_calls','active/no_audit']:
    assert default['final_logits']==runs[right]['final_logits']
assert runs['zero/audit']['final_logits']==runs['ordinary']['final_logits']
assert default['rows']==runs['active/repeat']['rows'] and default['witnesses']==runs['active/repeat']['witnesses']
assert sum(v['decode_calls'] for v in runs.values())==521
tree=subprocess.check_output(['git','rev-parse','27ea3c5^{tree}'],text=True).strip()
assert json.loads((r/'merge-commit.json').read_text())['tree']['sha']==tree
assert (r/'prefix/source-tree.txt').read_text().strip()==tree
summary={'status':'observations_verified','acceptance':False,'head':'27ea3c523e72dab29204ae394fef2a67ab89ab83','tree':tree,
 'native_test_result':'170 passed, 2 failed, 5 ignored; release/no-spill stages skipped',
 'source_merge':(r/'prefix/source-sha.txt').read_text().strip(),
 'counts':{'runs':7,'decode_calls':521,'prefix_tokens':3584,'audited_rows':220,'audit_values':7040,'witnesses':5120,'same_row_comparisons':1280},
 'default_addends':default['failing_coordinate_addends'],
 'same_input_projection_error':0,'default_repeat_four_calls_noaudit_logits_identical':True,'zero_ordinary_logits_identical':True,
 'default_tokenwise_logit_delta':max(abs(a-b) for a,b in zip(default['final_logits'],runs['active/token_at_a_time']['final_logits'])),
 'default_reference_max_activation_error':max(abs(x) for row in default['rows'] for x in row['signed_errors']),
 'tokenwise_reference_max_activation_error':max(abs(x) for row in runs['active/token_at_a_time']['rows'] for x in row['signed_errors']),
 'cpu':'AMD EPYC 9V74; actual lscpu retained','cause':'Unresolved; upstream signed errors accumulate before residual publication. Cache/fused-attention precision is the next controlled contrast, not an established cause.',
 'next_scope':'Three new cache/attention configurations; no replay of the seven retained runs and no changed production policy/reference/tolerance'}
(r/'owner.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
