import copy,importlib.util,json
from pathlib import Path
root=Path(__file__).parent;spec=importlib.util.spec_from_file_location('c',root/'combined-token-collector.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
name='projection_combined_test::tests::fixed_fixture_shape';prefix='test '+name+' ... '
r=dict(test='fixed_fixture_shape',status='passed',expected_cases=6,executed_cases=6,expected_rejections=4,rejected_cases=4,model_count=0)
marker='F6E_PROJECTION_COMBINED_TOKEN_TEST '+json.dumps(r,separators=(',',':'))
log=prefix+marker+'\nok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured;\n'
count=0;bad=0
def yes(fn,*args):
 global count
 fn(*args);count+=1
def no(fn,*args):
 global count,bad
 try:fn(*args)
 except (AssertionError,ValueError,KeyError):count+=1;bad+=1
 else:raise AssertionError('corrupted receipt accepted')
yes(c.token_native,log);yes(c.token_native,name+'\n'+marker+'\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured;\n')
for corrupted in [log.replace(prefix,'test wrong ... '),log.replace('executed_cases":6','executed_cases":5'),log.replace('rejected_cases":4','rejected_cases":3'),log.replace('model_count":0','model_count":1'),log.replace('1 passed; 0 failed','0 passed; 1 failed'),log.replace('0 ignored','1 ignored'),log+log,log.replace(marker,'OTHER'),log.replace(prefix,prefix+'junk '),log.replace('status":"passed','status":"failed')]:no(c.token_native,corrupted)
for mode in ['default','private']:
 rr=dict(mode=mode,status='passed',expected_cases=2,executed_cases=2,expected_rejections=1,rejected_cases=1,model_count=0)
 text='F6E_PROJECTION_COMBINED_TOKEN_R '+json.dumps(rr)+'\n';yes(c.mode_receipt,text,mode)
 no(c.mode_receipt,text,'private' if mode=='default' else 'default');no(c.mode_receipt,text+text,mode)
rows=[dict(call=str(i//48+1),vocab=str(i%48),value=str((i%48)/8+(1 if i//48 in [2,3] else 0))) for i in range(240)]
text='F6E_COMBINED_TOKEN_LOGITS calls=5 values=240 fixed_tokens=1,7,13 numerical_oracle=FALSE\n';yes(c.token_rows,rows,text)
for index,key,value in [(0,'call','2'),(50,'vocab','3'),(0,'value','nan'),(48,'value','2'),(144,'value','2'),(239,'value','2')]:
 rr=copy.deepcopy(rows);rr[index][key]=value;no(c.token_rows,rr,text)
no(c.token_rows,rows[:-1],text);no(c.token_rows,rows,text+text);no(c.token_rows,rows,text.replace('FALSE','TRUE'))
assert (count,bad)==(28,23),(count,bad)
print(f'F6E_COMBINED_TOKEN_COLLECTOR controls={count} negatives={bad} native=0 models=0')
