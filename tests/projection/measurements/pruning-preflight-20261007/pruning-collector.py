"""Strict native7 protocol collector; no inference or native execution on import."""
import csv
import math
import struct

COUNT_KEYS=['independent_values','fixed_schedule_final_values','fixed_schedule_history_values',
 'aligned_replay_final_values','aligned_replay_history_values','grouped_replay_final_values',
 'grouped_replay_history_values','cross_schedule_observation_values']
ARRAYS=['reference_logits','aligned_logits','aligned_replay_logits','aligned_history_logits',
 'aligned_replay_history_logits','grouped_all_logits','grouped_last_logits','grouped_repeat_logits',
 'grouped_all_history_logits','grouped_last_history_logits','grouped_repeat_history_logits']
PAIRS=[('grouped_all_logits','grouped_last_logits','pruning_bitwise_equal'),
 ('grouped_all_history_logits','grouped_last_history_logits','history_bitwise_equal'),
 ('aligned_logits','aligned_replay_logits','aligned_replay_bitwise_equal'),
 ('aligned_history_logits','aligned_replay_history_logits','aligned_history_replay_bitwise_equal'),
 ('grouped_last_logits','grouped_repeat_logits','grouped_replay_bitwise_equal'),
 ('grouped_last_history_logits','grouped_repeat_history_logits','grouped_history_replay_bitwise_equal')]

def chunk_schedule(n):
 return [512]*(n//512)+([n%512] if n%512 else [])

def finite(x):
 assert type(x) in (float,int) and math.isfinite(x)
 return float(x)

def errors(a,b):
 assert len(a)==len(b)==48
 return [abs(finite(x)-finite(y)) for x,y in zip(a,b)]

def same_f32(a,b):
 return all(struct.pack('<f',x)==struct.pack('<f',y) for x,y in zip(a,b))

def error_array(actual,want):
 assert len(actual)==len(want)==48
 for a,b in zip(actual,want):
  assert math.isclose(finite(a),b,rel_tol=1e-12,abs_tol=1e-14),(a,b)

def verify_pruning(row,raw_cases,source,gate):
 assert row['schema']==1 and row['status']=='passed'
 assert row['source_manifest_sha256']==source and row['reference_manifest_sha256']==gate.REFERENCE_HASH
 assert row['model_sha256']==gate.TINY_HASH and row['test_id']==gate.TEST_IDS[6]
 assert type(row['expected_cases']) is type(row['executed_cases']) is int
 assert row['expected_cases']==row['executed_cases']==3
 assert row['counts']=={k:144 for k in COUNT_KEYS}
 assert all(type(n) is int for n in row['counts'].values())
 assert isinstance(row['limitation'],str) and row['limitation']
 with (gate.REPO/'tests/llm-golden/projection/goldens/forward-cases.csv').open() as f:
  cases=[r for r in csv.DictReader(f) if r['case'] in ('long_prefill','mlp_out_last_c1','attn_out_last_c1')]
 with (gate.REPO/'tests/llm-golden/projection/goldens/forward-logits.csv').open() as f: goldens=list(csv.DictReader(f))
 assert row['cases']==raw_cases and len(raw_cases)==3
 assert [r['case'] for r in raw_cases]==[r['case'] for r in cases]
 for r,c in zip(raw_cases,cases):
  for k in ('prefill_tokens','decode_tokens','total_tokens'):
   assert type(r[k]) is int and r[k]==int(c[k])
  pre,dec,total=r['prefill_tokens'],r['decode_tokens'],r['total_tokens']
  assert pre+dec==total and r['n_batch']==512 and r['n_ubatch']==128
  assert r['phase_schedule']==chunk_schedule(pre)+[1]*dec
  assert r['grouped_schedule']==chunk_schedule(total)
  assert type(r['continuation_token_native']) is type(r['continuation_position_native']) is int
  assert r['continuation_token_native']==1 and r['continuation_position_native']==total
  for k in ARRAYS:
   assert len(r[k])==48
   for v in r[k]:finite(v)
  expect=sorted((g for g in goldens if g['case']==c['case'] and int(g['source_pos'])==total),key=lambda g:int(g['token_id_native']))
  assert len(expect)==48 and [int(g['token_id_native']) for g in expect]==list(range(48))
  assert r['reference_logits']==[float(g['logit']) for g in expect]
  independent=errors(r['aligned_logits'],r['reference_logits'])
  error_array(r['independent_abs_errors'],independent);assert max(independent)<=.01
  for a,b,k in PAIRS:
   assert r[k] is True and same_f32(r[a],r[b]),k
  for k,a,b in [('fixed_schedule_final_abs_errors','grouped_all_logits','grouped_last_logits'),('fixed_schedule_history_abs_errors','grouped_all_history_logits','grouped_last_history_logits')]:
   e=errors(r[a],r[b]);error_array(r[k],e);assert max(e)<=.01
  obs=r['cross_schedule_reference'];assert obs['status']=='unaccepted_cross_schedule_observation'
  e=errors(r['grouped_last_logits'],r['reference_logits']);error_array(obs['abs_errors'],e)
  assert obs['outlier_native_tokens']==[i for i,v in enumerate(e) if v>.01]
  assert math.isclose(finite(obs['max_abs_error']),max(e),rel_tol=1e-12,abs_tol=1e-14)
  # Outliers are retained as unaccepted observations, never asserted to pass.
 return dict(status='pruning_protocol_verified',independent_values_within_main_count=144,
             fixed_schedule_final_values=144,fixed_schedule_history_values=144,
             replay_final_and_history_values=576,
             cross_schedule_accuracy_accepted=False,
             cross_schedule_outliers={r['case']:r['cross_schedule_reference']['outlier_native_tokens'] for r in raw_cases})
