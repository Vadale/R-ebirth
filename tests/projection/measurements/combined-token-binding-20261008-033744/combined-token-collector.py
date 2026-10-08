import csv,importlib.util,json,math,re
from pathlib import Path
spec=importlib.util.spec_from_file_location('base',Path(__file__).with_name('combined-collector.py'));base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
combined_rows=base.combined_rows
materialized=base.materialized

def token_native(text):
 name='projection_combined_test::tests::fixed_fixture_shape'
 assert name in text
 assert len(re.findall(r'test result: ok\. 1 passed; 0 failed; 0 ignored; 0 measured;',text))==1
 text=re.sub(r'^test '+re.escape(name)+r' \.\.\. (?=F6E_PROJECTION_COMBINED_TOKEN_TEST )','',text,flags=re.M)
 r=base.marker(text,'F6E_PROJECTION_COMBINED_TOKEN_TEST')
 assert r==dict(test='fixed_fixture_shape',status='passed',expected_cases=6,executed_cases=6,expected_rejections=4,rejected_cases=4,model_count=0)
 return r

def mode_receipt(text,mode):
 assert mode in ['default','private']
 r=base.marker(text,'F6E_PROJECTION_COMBINED_TOKEN_R')
 assert r==dict(mode=mode,status='passed',expected_cases=2,executed_cases=2,expected_rejections=1,rejected_cases=1,model_count=0)
 return r

def token_rows(rows,text):
 assert len(rows)==240 and all(set(r)=={'call','vocab','value'} for r in rows)
 values=[]
 for index,r in enumerate(rows):
  assert r['call']==str(index//48+1) and r['vocab']==str(index%48)
  value=float(r['value']);assert math.isfinite(value);values.append(value)
 groups=[values[i*48:(i+1)*48] for i in range(5)]
 assert groups[0]==groups[1]==groups[4] and groups[2]==groups[3]
 assert text.count('F6E_COMBINED_TOKEN_LOGITS calls=5 values=240 fixed_tokens=1,7,13 numerical_oracle=FALSE')==1
 return dict(calls=5,values=240,fixed_token_ids=[1,7,13],source_reset_equal=True,parent_close_equal=True,independent_numerical_oracle=False)
