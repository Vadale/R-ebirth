import copy, importlib.util, json
from pathlib import Path
root=Path('/private/tmp/relm-f6e')
s=importlib.util.spec_from_file_location('collector',root/'review-fix-collector.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
spec={'id':'fixture::exact','marker':'F6E_REVIEW_FIX_TEST','expected_marker':{'test':'exact','status':'passed','cases':3,'refusals':1,'private':False,'names':['one','two','three']}}
marker='F6E_REVIEW_FIX_TEST '+json.dumps(spec['expected_marker'])
standalone='running 1 test\ntest fixture::exact ... \n'+marker+'\nok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 24 filtered out;\n'
inline=standalone.replace('test fixture::exact ... \n','test fixture::exact ... ')
for log in [standalone,inline]:c.native(log,spec)
negative=[standalone.replace(marker,''),standalone.replace(marker,marker+'\n'+marker),standalone.replace('fixture::exact','fixture::other'),standalone.replace('1 passed; 0 failed','0 passed; 0 failed'),standalone.replace('0 ignored','1 ignored'),standalone.replace('ok\n',''),standalone.replace('"cases": 3','"cases": true'),standalone.replace('"cases": 3','"cases": 4'),standalone.replace('"cases": 3','"cases": 3, "cases": 3'),standalone.replace('"cases": 3','"cases": NaN'),standalone.replace('"private": false','"private": 0'),standalone.replace('"three"','"other"'),standalone+'warning: unexpected\n',standalone+'ld: warning: unexpected\n',standalone+'test extra ... ok\n']
for index,log in enumerate(negative):
 try:c.native(log,spec)
 except (AssertionError,ValueError):pass
 else:raise AssertionError('negative accepted '+str(index))
print(json.dumps({'scope':'synthetic collector controls only; no native/model execution','positive':2,'negative':len(negative),'status':'passed'}))
