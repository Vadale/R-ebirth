#!/usr/bin/env python3
"""Model-free regression of the exact bundled grammar, position and index code.

Linux and macOS Rust CI run this. Metal arithmetic is evaluated as C++ with
matching scalar types; this does not execute a GPU kernel or prove GPU support.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def segment(text, start, end):
    assert text.count(start) == 1, start
    a = text.index(start)
    return text[a:text.index(end, a)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--cxx', default='clang++')
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=False)
    vendor = args.source_root / 'rebirth/src/llama.cpp'
    state = {'status': 'running', 'commands': [], 'sources': {},
             'limits': 'Source-derived units, no model or GPU execution.'}

    def read(name):
        data = (vendor / name).read_bytes()
        state['sources'][name] = hashlib.sha256(data).hexdigest()
        return data.decode()

    def run(name, command, stack=False):
        def limits():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            if stack:
                resource.setrlimit(resource.RLIMIT_STACK, (2097152, 2097152))
        result = subprocess.run(command, capture_output=True, timeout=60,
                                preexec_fn=limits,
                                env=dict(os.environ, TMPDIR=str(out),
                                         ASAN_OPTIONS='abort_on_error=0',
                                         UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1'))
        (out / (name + '.stdout')).write_bytes(result.stdout)
        (out / (name + '.stderr')).write_bytes(result.stderr)
        state['commands'].append({'name': name, 'command': command,
                                  'exit_code': result.returncode})
        (out / 'result.json').write_text(json.dumps(state, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError(f'{name} failed; see retained stderr (exit {result.returncode})')
        return result

    try:
        grammar = read('src/llama-grammar.cpp')
        read('src/llama-grammar.h')
        helper = segment(grammar, 'static bool llama_grammar_is_end_of_sequence(',
                         'static bool llama_grammar_detect_left_recursion(')
        start = ('// checks the code point at depth of each candidate'
                 if '// checks the code point at depth of each candidate' in grammar
                 else 'llama_grammar_candidates llama_grammar_reject_candidates_for_stack(')
        candidates = segment(grammar, start, '\n////////////////////')
        preamble = r"""#include "llama-grammar.h"
#include <algorithm>
#include <numeric>
#include <set>
#include <cstdio>
#include <cstdlib>
#include <cassert>
extern "C" void ggml_abort(const char *, int, const char *, ...) { abort(); }
"""
        grammar_test = (Path(__file__).with_name('grammar.cpp')).read_text()
        (out / 'grammar.cpp').write_text(preamble + helper + candidates + grammar_test)

        clip = read('tools/mtmd/clip.cpp')
        clip = clip[clip.index('// set inputs'):]
        clip = clip[:clip.index('        case PROJECTOR_TYPE_MIMOVL:')]
        image_parts = []
        for tag, end, name in [('QWEN2VL', 'STEP3VL', 'qwen'),
                               ('PADDLEOCR', 'MINIMAX_M3', 'paddle')]:
            block = segment(clip, '        case PROJECTOR_TYPE_' + tag + ':',
                            '        case PROJECTOR_TYPE_' + end + ':')
            block = block[block.index('            {'):block.rindex('} break;')+1]
            image_parts.append('std::vector<int> ' + name + '(int w,int h,int merge){\n'
                'struct{int n_merge;} hparams{merge};\n'
                'const int image_size_width=w,image_size_height=h,patch_size=1;\n'
                'const int num_patches=w*h,n_pos=num_patches;\n'
                'std::vector<int> result;\n'
                'auto set_input_i32=[&](const char *,const std::vector<int>&v){result=v;};\n'
                + block + '\nreturn result;}\n')
        window = segment(clip, '                const int mpow = merge_ratio * merge_ratio;',
                         '                set_input_i32("positions", positions);')
        image_parts.append('std::vector<int> windowed(int w,int h,const std::vector<int>&idx){\n'
            'const int merge_ratio=2, pw=w/2,ph=h/2,ipw=w,iph=h,num_patches=w*h,n_pos=w*h;\n'
            + window + '\nreturn positions;}\n')
        (out / 'image.cpp').write_text('#include <vector>\n#include <cassert>\n#include <cstdio>\n'
            + ''.join(image_parts) + Path(__file__).with_name('image.cpp').read_text())

        metal = read('ggml/src/ggml-metal/kernels/mul_mm.metal')
        impl = read('ggml/src/ggml-metal/ggml-metal-impl.h')
        structs = []
        for name in ['ggml_metal_kargs_mul_mm', 'ggml_metal_kargs_mul_mm_id']:
            end = impl.index('} ' + name + ';') + len('} ' + name + ';')
            structs.append(impl[impl.rfind('typedef struct {', 0, end):end])
        def line(pattern):
            found = re.findall(pattern, metal, re.M)
            assert len(found) == 1, pattern
            return found[0]
        i12 = line(r'^    (const (?:short|int) +i12 = \(id / args.ne20\);)$')
        idt = line(r'^        (const (?:short|int) +idt = id / args.ne20;)$')
        full = line(r'\(r0 \+ 32\*\(sgitg &  1\)\) \+ \\\n            ([^;]+);')
        edge = line(r'dst \+ r0 \+ ([^;]+);\n                device float4')
        store = line(r'C \+ 8\*\(i%4\) \+ ([^,]+), args.ne0, 0, false\);')
        moe = line(r'dst \+ r0 \+ ([^;]+);\n        device float4')
        metal_test = Path(__file__).with_name('metal.cpp').read_text()
        for token, value in [('I12',i12),('IDT',idt),('FULL',full),('EDGE',edge),
                             ('STORE',store),('MOE',moe)]:
            metal_test = metal_test.replace('@'+token+'@',value)
        (out/'metal.cpp').write_text('#include <cstdint>\n#include <cassert>\n#include <cstdio>\n'
                                    + '\n'.join(structs) + '\n' + metal_test)
        flags = ['-std=c++17','-O1','-g','-fsanitize=address,undefined',
                 '-fno-sanitize-recover=all','-fno-omit-frame-pointer']
        for name in ['grammar','image','metal']:
            run(name+'-compile',[args.cxx,*flags,'-I'+str(vendor/'src'),
                '-I'+str(vendor/'include'),'-I'+str(vendor/'ggml/include'),
                str(out/(name+'.cpp')),'-o',str(out/name)])
            run(name,[str(out/name)],stack=(name=='grammar'))
        state['status']='passed'
    except Exception as error:
        state['status']='failed'
        state['error']=str(error)
        raise
    finally:
        (out/'result.json').write_text(json.dumps(state,indent=2)+'\n')
    print('PASS grammar, image positions and Metal arithmetic; no model/GPU execution')


if __name__ == '__main__':
    main()
