import importlib.util,json,pathlib
p=pathlib.Path(__file__).with_name('budget-class-collector.py');s=importlib.util.spec_from_file_location('c',p);c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
n='test '+c.NATIVE+' ... F6E_PROJECTION_LEDGER_TEST '+json.dumps(c.BASE)+'\nok\ntest result: ok. 1 passed; 0 failed; 0 ignored;\n'
h='F6E_PROJECTION_BUDGET_CLASS_TEST '+json.dumps({**c.HOST,'error_response_bytes':800})+'\nF6E_BUDGET_R_TWIN terms=14 exact_budget=1 minus_one_oom=1 payloads=3 models=0 inference=0\nF6E_BUDGET_R_HOSTED_SUCCESS cases=8 refusals=3 models=0 inference=0\n'
checks=[]
def ok(name,fn,raw):fn(raw);checks.append({'name':name,'expected':'accepted','passed':True})
def no(name,fn,raw):
 try:fn(raw)
 except (AssertionError,ValueError,StopIteration):checks.append({'name':name,'expected':'refused','passed':True})
 else:raise AssertionError(name)
ok('native_positive',c.native,n);ok('hosted_positive',c.registration,h)
for name,raw in [('zero_tests',n.replace('1 passed','0 passed')),('ignored',n.replace('0 ignored','1 ignored')),('wrong_name',n.replace(c.NATIVE,'wrong')),('missing_marker',n.replace('F6E_PROJECTION_LEDGER_TEST','wrong')),('duplicate_marker',n+n),('wrong_cases',n.replace('"executed_cases": 11','"executed_cases": 10')),('boolean_count',n.replace('"executed_cases": 11','"executed_cases": true')),('duplicate_json_key',n.replace('"status": "passed"','"status": "passed", "status": "passed"'))]:no(name,c.native,raw)
for name,raw in [('hosted_no_completion',h.replace('F6E_BUDGET_R_HOSTED_SUCCESS','wrong')),('hosted_fake_libtest',h+'test result: ok.'),('hosted_frame_excess',h.replace('"error_response_bytes": 800','"error_response_bytes": 1513')),('hosted_models',h.replace('"model_loads": 0','"model_loads": 1')),('hosted_wrong_class_counts',h.replace('"rejected_cases": 3','"rejected_cases": 2')),('hosted_warning',h+'Warning: synthetic\n'),('hosted_no_twin',h.replace('F6E_BUDGET_R_TWIN','wrong')),('hosted_wrong_profile',h.replace('"ffi_response_bytes": 1512','"ffi_response_bytes": 1500'))]:no(name,c.registration,raw)
assert len(checks)==18
print(json.dumps({'status':'passed','controls':18,'positive':2,'negative':16,'checks':checks},indent=2))
