import copy,importlib.util,json,ast
from pathlib import Path
root=Path('/private/tmp/relm-f6e');spec=importlib.util.spec_from_file_location('c',root/'ledger-collector.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
# All existing parser functions are byte-for-byte AST equivalent to their saved
# first-attempt source. No need to rerun their39 accepted synthetic controls.
old=ast.parse((root/'public-ledger-20261008-003048/ledger-collector.py').read_text());new=ast.parse((root/'ledger-collector.py').read_text())
a={x.name:ast.dump(x,include_attributes=False) for x in old.body if isinstance(x,ast.FunctionDef)}
b={x.name:ast.dump(x,include_attributes=False) for x in new.body if isinstance(x,ast.FunctionDef)}
for k,v in a.items():assert b[k]==v,k
t={'id':'projection_profile_ffi_descriptors_and_schema_are_exact','expected_cases':47,'expected_rejections':19}
r={'test':t['id'],'status':'passed','expected_cases':47,'executed_cases':47,'expected_rejections':19,'rejected_cases':19}
marker='F6E_PROJECTION_LEDGER_TEST '+json.dumps(r)+'\n';end='F6E_PROJECTION_R_HOSTED_SUCCESS cases=47 rejections=19 models=0\n';log=marker+end
assert c.hosted_test(log,t)==r;n=1
badlogs=[marker,end,log+end,log+marker,end+marker,log+'test result: ok. 1 passed; 0 failed; 0 ignored;\n',log.replace('models=0','models=1')]
for key,value in [('status','failed'),('test','another'),('executed_cases',46),('rejected_cases',18),('expected_cases',True),('expected_rejections',0)]:
 bad=copy.deepcopy(r);bad[key]=value;badlogs.append('F6E_PROJECTION_LEDGER_TEST '+json.dumps(bad)+'\n'+end)
for bad in badlogs:
 try:c.hosted_test(bad,t)
 except AssertionError:n+=1
 else:raise AssertionError('accepted invalid hosted receipt')
print(json.dumps({'status':'passed','new_hosted_controls':n,'unchanged_parser_functions':list(a),'carried_controls':39,'native_execution':False}))
