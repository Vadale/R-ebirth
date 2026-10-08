import csv,json,re
CASES=['actual_model_shape','actual_budget_above_public_minimum','combined_R_charge','all_native_R_terms','combined_budget_minus_one','minus_one_before_constructor','source_unchanged_after_refusal','combined_exact_budget_constructed','actual_candidate_metadata','actual_unhashed_candidate_state','actual_R_materialization_within_bound','five_array_bytes','exact_candidate_closed','projected_handle_configured','duplicate_site_before_transfer','duplicate_never_constructed','steering_inherits_static_projection','new_residual_probe_charged','mixed_accumulated_entries','mixed_five_arrays_measured','descendant_survives_parent_close','closed_source_refused','delivered_handle_R_failure','delivered_native_owner_closed','original_reset_exact','derived_close_idempotent','original_closed']
REFUSALS={'combined_budget_minus_one','duplicate_site_before_transfer','closed_source_refused','delivered_handle_R_failure'}
def marker(text,prefix):
 lines=[s[len(prefix)+1:] for s in text.splitlines() if s.startswith(prefix+' ')]
 assert len(lines)==1,(prefix,len(lines));return json.loads(lines[0])
def bridge_native(text):
 assert 'tests::projection_bridge_compiled_frame' in text
 assert re.search(r'test result: ok\. 1 passed; 0 failed; 0 ignored; 0 measured;',text)
 # libtest may write its exact test prefix without a newline before output.
 # Normalize only this named test/prefix; unexpected labels remain rejected.
 text=re.sub(r'^test tests::projection_bridge_compiled_frame \.\.\. (?=F6E_PROJECTION_BRIDGE_TEST )','',text,flags=re.M)
 r=marker(text,'F6E_PROJECTION_BRIDGE_TEST')
 assert set(r)=={'test','status','expected_cases','executed_cases','expected_rejections','rejected_cases','bridge_frame_bytes','ffi_command_bytes'}
 assert r['test']=='projection_bridge_compiled_frame' and r['status']=='passed'
 assert (r['expected_cases'],r['executed_cases'],r['expected_rejections'],r['rejected_cases'])==(2,2,0,0)
 assert type(r['bridge_frame_bytes']) is int and r['bridge_frame_bytes']>0
 assert r['ffi_command_bytes']==424+r['bridge_frame_bytes'];return r
def mode_receipt(text,mode):
 r=marker(text,'F6E_PROJECTION_BRIDGE_R')
 assert r==dict(mode=mode,status='passed',expected_cases=2,executed_cases=2,expected_rejections=1,rejected_cases=1,model_count=0);return r
def combined_rows(rows,text):
 assert len(rows)==27 and [r['case'] for r in rows]==CASES
 assert all(r['status']=='passed' and r['refusal']==('TRUE' if r['case'] in REFUSALS else 'FALSE') for r in rows)
 assert text.count('F6E_COMBINED_R_BINDING cases=27 refusals=4 constructor_calls=5 model_loads=1 source_reset=TRUE closed=TRUE')==1
 assert re.findall(r'^F6E_BINDING_CASE (\S+) refusal=(?:TRUE|FALSE)$',text,re.M)==CASES
 return dict(cases=27,refusals=4,constructor_calls=5,model_loads=1)
def materialized(row):
 x={k:float(v) for k,v in row.items()}
 assert set(x)=={'exact_budget','actual_R_bytes','R_bound_bytes','workspace_bytes','model_skeleton_bytes','state_extra_bytes','flat_bytes','mixed_flat_bytes','construct_calls','model_loads'}
 assert all(v>0 and v.is_integer() for v in x.values())
 assert 2**20<x['exact_budget']<64*2**20
 assert x['actual_R_bytes']<=x['R_bound_bytes']<x['exact_budget']
 assert x['model_skeleton_bytes']>1200000 and x['state_extra_bytes']==1272
 assert x['workspace_bytes']>0 and x['mixed_flat_bytes']>x['flat_bytes']
 assert x['construct_calls']==5 and x['model_loads']==1;return x
