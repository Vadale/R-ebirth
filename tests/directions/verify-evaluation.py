"""Independent, stdlib-only verification of the frozen F6d-v1 experiment."""
import csv,hashlib,json,math,re,sys
from pathlib import Path
run=Path(sys.argv[1]); root=Path(__file__).resolve().parents[2]
def read(path):
 with path.open(newline='',encoding='utf-8') as f:return list(csv.DictReader(f))
def yes(x):assert x in ('TRUE','FALSE');return x=='TRUE'
def near(a,b):return abs(a-b)<=1e-12*(1+abs(b))
def mean(x):return math.fsum(x)/len(x)
def quantile(x,p):
 x=sorted(x);index=(len(x)-1)*p;lower=int(index);weight=index-lower
 return x[lower]*(1-weight)+x[min(lower+1,len(x)-1)]*weight
prompts=read(root/'tests/directions/evaluation/prompts.csv');lookup={x['item_id']:x for x in prompts if x['split']!='construction'}
assert len(prompts)==38 and len({x['prompt_sha256'] for x in prompts})==38
for x in prompts:assert hashlib.sha256(x['prompt'].encode()).hexdigest()==x['prompt_sha256']
runs=read(run/'runs.csv');assert len(runs)==76
assert sum(x['phase']=='selection' for x in runs)==42 and sum(x['phase']=='evaluation' for x in runs)==32
metrics=['answer','characters','sampled_tokens','empty','truncated','repetition']
for x in runs:
 assert yes(x['success']), (x['run_id'],x['error'])
 events=read(run/(x['run_id']+'-events.csv'))
 assert [int(e['event_id']) for e in events]==list(range(1,len(events)+1))
 text=''.join(e['text'] for e in events if e['event']=='text');assert text==x['text']
 tokens=[e for e in events if e['event']=='token'];ends=[e for e in events if e['event']=='prompt_end'];assert len(ends)==1
 assert int(x['sampled_tokens'])==len(tokens) and int(x['characters'])==len(text)
 assert [int(e['token_pos']) for e in tokens]==list(range(1,len(tokens)+1))
 assert x['finish_reason']==ends[0]['finish_reason']
 assert yes(x['truncated'])==(x['finish_reason']=='length') and yes(x['empty'])==(not text.strip())
 words=text.strip().lower().split();assert int(x['repetition'])==sum(a==b for a,b in zip(words,words[1:]))
 if x['phase']!='visualization':
  pattern=lookup[x['item_id']]['required_pattern']
  answer=any((m.start()==0 or not text[m.start()-1].isalnum()) and (m.end()==len(text) or not text[m.end()].isalnum()) for m in re.finditer('('+pattern+')',text,re.I))
  assert answer==yes(x['answer']),x['run_id']
sel=[x for x in runs if x['phase']=='selection'];base=[x for x in sel if x['setting']=='baseline']
coefficients=[-2,-1,1,2];scores=[]
def number(x,metric):return int(yes(x[metric])) if metric in ['answer','empty','truncated'] else float(x[metric])
for coefficient in coefficients:
 rows=[x for x in sel if x['setting']=='learned-'+str(coefficient)]
 assert len(rows)==6 and [x['item_id'] for x in rows]==[x['item_id'] for x in base]
 eligible=all(number(a,'answer')>=number(b,'answer') and all(number(a,k)<=number(b,k) for k in ['empty','truncated','repetition']) for a,b in zip(rows,base)) and mean([number(x,'characters') for x in rows])<mean([number(x,'characters') for x in base])
 scores.append(dict(coefficient=coefficient,eligible=eligible,mean_characters=mean([number(x,'characters') for x in rows])))
saved=read(run/'selection-scores.csv')
for a,b in zip(scores,saved):
 assert a['coefficient']==float(b['coefficient']) and a['eligible']==yes(b['eligible']) and near(a['mean_characters'],float(b['mean_characters']))
allowed=[x for x in scores if x['eligible']];chosen=min(allowed,key=lambda x:(x['mean_characters'],abs(x['coefficient']),x['coefficient']))['coefficient'] if allowed else 0
assert chosen==float((run/'chosen-coefficient.txt').read_text())
final=[x for x in runs if x['phase']=='evaluation'];base=[x for x in final if x['setting']=='baseline']
indices=read(run/'bootstrap-indices.csv');assert len(indices)==2000
index_rows=[[int(v)-1 for v in row.values()] for row in indices];assert all(len(i)==8 and all(0<=j<8 for j in i) for i in index_rows)
intervals=read(run/'paired-intervals.csv');assert len(intervals)==18
for setting in ['zero','selected','random']:
 other=[x for x in final if x['setting']==setting];assert [x['item_id'] for x in other]==[x['item_id'] for x in base]
 assert all(float(x['coefficient'])==(chosen if setting=='selected' else 1 if setting=='random' else 0) for x in other)
 for metric in metrics:
  delta=[number(a,metric)-number(b,metric) for a,b in zip(other,base)]
  draws=[mean([delta[i] for i in ids]) for ids in index_rows]
  row=next(x for x in intervals if x['setting']==setting and x['metric']==metric)
  assert near(float(row['mean_difference']),mean(delta)) and near(float(row['lower']),quantile(draws,.025)) and near(float(row['upper']),quantile(draws,.975))
# New checked zero adapter must preserve seeded text and actual token IDs.
for phase in ['selection','evaluation']:
 group=[x for x in runs if x['phase']==phase]
 for base_row in [x for x in group if x['setting']=='baseline']:
  zero=next(x for x in group if x['setting']=='zero' and x['item_id']==base_row['item_id'])
  assert zero['text']==base_row['text']
  a=read(run/(base_row['run_id']+'-events.csv'));b=read(run/(zero['run_id']+'-events.csv'))
  assert [x['token_id'] for x in a if x['event']=='token']==[x['token_id'] for x in b if x['event']=='token']
# Reconstruct the new direction independently from retained bounded real captures.
values=read(run/'construction-values.csv');width=max(int(x['neuron']) for x in values)
assert len(values)==12*width
by_neuron=[[] for _ in range(width)]
for x in values:by_neuron[int(x['neuron'])-1].append(float(x['target'])-float(x['control']))
avg=[mean(x) for x in by_neuron];scale=max(abs(x) for x in avg);norm=scale*math.sqrt(math.fsum((x/scale)**2 for x in avg))
expected=[x/norm for x in avg];actual=read(run/'direction-values.csv')
assert [int(x['neuron']) for x in actual]==list(range(1,width+1))
error=max(abs(float(x['value'])-y) for x,y in zip(actual,expected));assert error<=1e-12
for path in ['selection.pdf','holdout.pdf','comparison.pdf','timeline.pdf','selection.png','holdout.png','comparison.png','timeline.png']:
 assert (run/path).is_file() and (run/path).stat().st_size>100
sources=json.loads((run/'source-manifest.json').read_text())
assert all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in sources.items())
receipt=dict(status='passed',runs=len(runs),selection_runs=42,holdout_runs=32,visualization_runs=2,chosen_coefficient=chosen,construction_values=len(values),width=width,independent_direction_max_error=error,bootstrap_resamples=2000,paired_intervals=18,source_hashes=len(sources),scope='Fixed synthetic/hand-authored protocol on one cached CPU model. Conditional intervals, literal answer checks, recorded provenance; no general quality claim. Plot existence only; visual inspection remains separate.')
(run/'independent-verification.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
