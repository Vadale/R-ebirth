import copy,csv,importlib.util,json,sys
from pathlib import Path
root=Path('/private/tmp/relm-f6e')
def imp(name,file):
 s=importlib.util.spec_from_file_location(name,root/file);m=importlib.util.module_from_spec(s);sys.modules[name]=m;s.loader.exec_module(m);return m
p=imp('p','pruning-collector.py');g=imp('g','verify-feasibility-pruning.py')
source='synthetic-control-only'
with (g.REPO/'tests/llm-golden/projection/goldens/forward-cases.csv').open() as f: cases=[x for x in csv.DictReader(f) if x['case'] in ('long_prefill','mlp_out_last_c1','attn_out_last_c1')]
with (g.REPO/'tests/llm-golden/projection/goldens/forward-logits.csv').open() as f:goldens=list(csv.DictReader(f))
rows=[]
for c in cases:
 pre,dec,total=[int(c[k]) for k in ('prefill_tokens','decode_tokens','total_tokens')]
 v=[float(x['logit']) for x in sorted((x for x in goldens if x['case']==c['case'] and int(x['source_pos'])==total),key=lambda x:int(x['token_id_native']))]
 grouped=v.copy();grouped[0]+=.02
 r=dict(case=c['case'],prefill_tokens=pre,decode_tokens=dec,total_tokens=total,n_batch=512,n_ubatch=128,phase_schedule=p.chunk_schedule(pre)+[1]*dec,grouped_schedule=p.chunk_schedule(total),continuation_token_native=1,continuation_position_native=total)
 for k in p.ARRAYS:r[k]=(grouped if k.startswith('grouped') else v).copy()
 for _,_,k in p.PAIRS:r[k]=True
 r.update(independent_abs_errors=[0.]*48,fixed_schedule_final_abs_errors=[0.]*48,fixed_schedule_history_abs_errors=[0.]*48)
 err=p.errors(grouped,v);r['cross_schedule_reference']=dict(status='unaccepted_cross_schedule_observation',abs_errors=err,outlier_native_tokens=[0],max_abs_error=max(err))
 rows.append(r)
base=dict(schema=1,status='passed',source_manifest_sha256=source,reference_manifest_sha256=g.REFERENCE_HASH,model_sha256=g.TINY_HASH,test_id=g.TEST_IDS[6],expected_cases=3,executed_cases=3,counts={k:144 for k in p.COUNT_KEYS},cases=rows,limitation='Synthetic controls; grouped cross-schedule outliers are not acceptance.')
results=[]
def test(name,mut=None,reject=True,rawmut=None):
 r=copy.deepcopy(base)
 if mut:mut(r)
 raw=copy.deepcopy(r['cases'])
 if rawmut:rawmut(raw)
 try:p.verify_pruning(r,raw,source,g)
 except (AssertionError,KeyError,TypeError,ValueError,OverflowError):assert reject,name
 else:assert not reject,name
 results.append(dict(name=name,passed=True,expected_rejection=reject))
test('valid-including-unaccepted-cross-schedule-outlier',reject=False)
def setpath(r,path,val):
 for k in path[:-1]:r=r[k]
 r[path[-1]]=val
for name,path,val in [
 ('wrong-source',['source_manifest_sha256'],'bad'),('wrong-model',['model_sha256'],'bad'),('wrong-reference',['reference_manifest_sha256'],'bad'),('wrong-test',['test_id'],g.TEST_IDS[5]),
 ('missing-case',['executed_cases'],2),('false-value-count',['counts','independent_values'],0),('false-parity-count',['counts','fixed_schedule_history_values'],0),
 ('wrong-prefill',['cases',0,'prefill_tokens'],4),('wrong-phase-schedule',['cases',0,'phase_schedule'],[5]),('wrong-grouped-schedule',['cases',0,'grouped_schedule'],[3,1,1]),
 ('wrong-context-setting',['cases',0,'n_ubatch'],512),('wrong-history-token',['cases',0,'continuation_token_native'],2),('wrong-history-position',['cases',0,'continuation_position_native'],0),
 ('empty-values',['cases',0,'aligned_logits'],[]),('nonfinite-values',['cases',0,'aligned_logits',0],float('nan')),
 ('wrong-reference-value',['cases',0,'reference_logits',0],123.),('independent-bound-exceeded',['cases',0,'aligned_logits',0],123.),
 ('false-pruning-equality',['cases',0,'pruning_bitwise_equal'],False),('mismatched-history',['cases',0,'grouped_all_history_logits',0],123.),
 ('mismatched-replay',['cases',0,'aligned_replay_logits',0],123.),('mismatched-grouped-replay',['cases',0,'grouped_repeat_logits',0],123.),
 ('hidden-outlier',['cases',0,'cross_schedule_reference','outlier_native_tokens'],[]),('false-observation-acceptance',['cases',0,'cross_schedule_reference','status'],'passed'),
 ('wrong-observation-error',['cases',0,'cross_schedule_reference','max_abs_error'],0.)]:
 test(name,lambda r,path=path,val=val:setpath(r,path,val))
test('missing-raw-case',rawmut=lambda r:r.pop());test('duplicate-raw-case',rawmut=lambda r:r.append(r[0]))
test('raw-value-mismatch',rawmut=lambda r:r[0]['aligned_logits'].__setitem__(0,123.))
(root/'pruning-collector-controls.json').write_text(json.dumps(dict(status='passed',scope='synthetic protocol collector controls; no native or model execution',count=len(results),controls=results,collector_sha256=g.digest(root/'pruning-collector.py'),driver_sha256=g.digest(root/'verify-feasibility-pruning.py')),indent=2)+'\n')
print(json.dumps(dict(status='passed',count=len(results))))
