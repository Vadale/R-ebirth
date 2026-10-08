import ast,hashlib,importlib.util,json
from pathlib import Path
root=Path('/private/tmp/relm-f6e');p=root/'combined-collector.py';spec=importlib.util.spec_from_file_location('c',p);c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
old=ast.parse((root/'combined-collector-initial.py').read_text());new=ast.parse(p.read_text())
for name in ['marker','mode_receipt','combined_rows','materialized']:
 a=next(x for x in old.body if isinstance(x,ast.FunctionDef) and x.name==name);b=next(x for x in new.body if isinstance(x,ast.FunctionDef) and x.name==name)
 assert ast.dump(a)==ast.dump(b)
raw=(root/'combined-binding-20261008-031008/native-bridge-frame.log').read_text()
expected=json.loads((root/'combined-binding-20261008-031008/native-bridge-receipt-recovered.json').read_text())
assert c.bridge_native(raw)==expected
prefix='test tests::projection_bridge_compiled_frame ... '
assert c.bridge_native(raw.replace(prefix,''))==expected
count=2
bad=[raw.replace(prefix,'test tests::wrong ... '),raw.replace(prefix,'log '+prefix),raw.replace('"executed_cases":2','"executed_cases":0'),raw.replace('"bridge_frame_bytes":320','"bridge_frame_bytes":321'),raw.replace('1 passed; 0 failed','0 passed; 1 failed'),raw.replace('0 ignored','1 ignored'),raw+raw,raw.replace('F6E_PROJECTION_BRIDGE_TEST','OTHER'),raw.replace(prefix,prefix+'junk '),raw.replace('"status":"passed"','"status":"failed"')]
for log in bad:
 try:c.bridge_native(log)
 except (AssertionError,ValueError):count+=1
 else:raise AssertionError('negative libtest log accepted')
assert count==12
print('F6E_COMBINED_LIBTEST_COLLECTOR passed=12 negatives=10 unchanged_functions=4 native_tests=0 models=0')
