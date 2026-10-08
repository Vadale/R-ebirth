"""Strict new budget-class outcome collector; import performs no execution."""
import json,re
NATIVE='projection_profile::tests::projection_budget_oom_class_preserves_arithmetic_and_error_capacity'
BASE={'test':'projection_budget_oom_class_preserves_arithmetic_and_error_capacity','status':'passed','expected_cases':11,'executed_cases':11,'expected_rejections':7,'rejected_cases':7}
HOST={**BASE,'test':'projection_budget_error_rhost','expected_cases':8,'executed_cases':8,'expected_rejections':3,'rejected_cases':3,'error_response_bytes':1,'ffi_response_bytes':1512,'error_format_bytes':150,'model_loads':0,'inference_calls':0}
def pairs(xs):
 d={}
 for k,v in xs:
  assert k not in d,'duplicate marker key';d[k]=v
 return d
def marker(log,key,expected):
 assert log.count(key+' ')==1,'missing/duplicate marker'
 line=next(s for s in log.splitlines() if key+' ' in s)
 r=json.loads(line.split(key+' ',1)[1],object_pairs_hook=pairs,parse_constant=lambda x:(_ for _ in ()).throw(AssertionError('nonfinite')))
 assert set(r)==set(expected),'field set'
 for k,v in expected.items():
  assert type(r[k]) is type(v),k
  if k!='error_response_bytes':assert r[k]==v,(k,r[k],v)
 assert not re.search(r'^(?:warning(?:\[|:)|Warning:|Error|error\[|ld: warning:)',log,re.M),'warning/error'
 return r
def native(log,test=None):
 assert re.findall(r'test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored;',log)==[('1','0','0')]
 assert re.search(r'test '+re.escape(NATIVE)+r' \.\.\. ',log)
 return marker(log,'F6E_PROJECTION_LEDGER_TEST',BASE)
def registration(log,ready=None):
 assert 'test result:' not in log
 for s in ['F6E_BUDGET_R_TWIN terms=14 exact_budget=1 minus_one_oom=1 payloads=3 models=0 inference=0','F6E_BUDGET_R_HOSTED_SUCCESS cases=8 refusals=3 models=0 inference=0']:
  assert log.splitlines().count(s)==1
 r=marker(log,'F6E_PROJECTION_BUDGET_CLASS_TEST',HOST)
 assert 0<r['error_response_bytes']<=r['ffi_response_bytes']
 assert log.index('F6E_PROJECTION_BUDGET_CLASS_TEST ')<log.index('F6E_BUDGET_R_TWIN ')<log.index('F6E_BUDGET_R_HOSTED_SUCCESS ')
 return r
