"""Strict fixed-schema collector for the scoped Metal correction. No inference."""
from collections import Counter
import json
import re

PHASES=('probe_baseline','probe_edited','projected')
TINY_SITES={(0,0):8,(2,0):1,(0,1):6,(2,1):1,(1,0):2,(1,1):1}
FIELDS=set('schema phase width depth layer_native component_code kind is_host usage device_type flags device_index type_name_bytes device_name_bytes registry_name_bytes rows bytes dtype_f32 view_offset data_nonnull contiguous no_staging_supported decode_failed'.split())

def integer(value,lo=0):
 assert type(value) is int and value>=lo,value
 return value

def name(value,length):
 assert type(value) is list and len(value)==length
 assert all(type(x) is int and 0<=x<=255 for x in value)
 assert 0 in value
 end=value.index(0)
 assert end>0 and not any(value[end:])
 return bytes(value[:end]).decode('ascii')

def expected_counts():
 counts=Counter()
 for phase in PHASES:
  for (layer,component),n in TINY_SITES.items():counts[(32,3,phase,layer,component)]=n
 for phase in PHASES[:2]:
  for layer,n in ((0,1),(12,3),(23,1)):counts[(896,24,phase,layer,0)]=n
 for layer,n in ((0,1),(12,2),(23,1)):counts[(896,24,'projected',layer,0)]=n
 return counts

def verify_buffers(rows,bench):
 assert len(rows)==71,len(rows)
 actual=Counter();devices=set()
 for r in rows:
  assert type(r) is dict and set(r)==FIELDS
  for k,v in {'schema':1,'kind':2,'is_host':0,'device_type':1,'flags':255,'view_offset':0}.items():assert integer(r[k])==v,(k,r[k])
  assert integer(r['usage']) in (0,2)
  for k in ('dtype_f32','data_nonnull','contiguous','no_staging_supported'):assert r[k] is True,k
  assert r['decode_failed'] is False
  width=integer(r['width'],1);depth=integer(r['depth'],1)
  layer=integer(r['layer_native']);component=integer(r['component_code'])
  assert layer<depth and component in (0,1)
  phase=r['phase'];assert phase in PHASES
  n=integer(r['rows'],1);assert integer(r['bytes'],1)==n*width*4
  if phase!='projected':assert n==1
  assert n<=128
  index=integer(r['device_index']);assert index<=4294967295
  typename=name(r['type_name_bytes'],32);device=name(r['device_name_bytes'],32);registry=name(r['registry_name_bytes'],16)
  assert typename==device=='MTL'+str(index) and registry=='MTL'
  assert re.fullmatch(r'MTL(?:0|[1-9][0-9]*)',device)
  proof=bench['tiny_forward']['backend'] if width==32 else bench['hooked_backend']
  assert device in [x.split()[0] for x in proof['selected_devices']]
  assert any(x==device and y>0 for x,y in proof['compute_buffers_mib'])
  actual[(width,depth,phase,layer,component)]+=1;devices.add(device)
 assert actual==expected_counts(),{'actual':sorted(actual.items()),'expected':sorted(expected_counts().items())}
 return {'status':'verified','receipt_count':len(rows),'tiny_receipts':57,'qwen_receipts':14,'devices':sorted(devices),'scope':'actual registered default shared Metal buffers; flags are native pointer-identity observations, not authentication','counts':[{'key':list(k),'count':v} for k,v in sorted(actual.items())]}

def verify_ledger(rows):
 assert len(rows)==1
 r=rows[0]
 keys=set('width sites direction_bytes plan_bytes runtime_bytes probe_bytes frame_bytes total runtime_size site_size probe_size projection_info_size buffer_info_size proof_size proof_slots access_frame_bytes'.split())
 assert set(r)==keys
 for k in keys:integer(r[k],1)
 assert r['width']==65536 and r['sites']==r['proof_slots']==32
 # These are explicit C/repr(C) POD widths, separate from platform-owned Rust sizes.
 assert r['buffer_info_size']==6*4+32+32+16==104
 assert r['projection_info_size']==2*8+2*4+r['buffer_info_size']==128
 assert r['proof_size']>=r['projection_info_size']
 assert r['runtime_size']>=32*r['proof_size']
 assert r['frame_bytes']>=2*r['projection_info_size']+r['access_frame_bytes']
 assert r['direction_bytes']==32*(8*65536+16)
 assert r['runtime_bytes']>=2*(4*65536+r['runtime_size'])
 assert r['probe_bytes']>=20*65536+r['runtime_size']+r['probe_size']
 assert r['total']==sum(r[k] for k in ('direction_bytes','plan_bytes','runtime_bytes','probe_bytes','frame_bytes'))
 assert r['total']<64*1024**2
 return {'status':'verified','compiled':r,'scope':'private native admission; not public R/FFI resource acceptance'}
