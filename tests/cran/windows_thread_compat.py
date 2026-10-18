#!/usr/bin/env python3
"""Compile only the Windows declaration adapter; never build an engine or model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'rebirth/src/rust/rebirth-llm/native'
HEADER = NATIVE / 'windows_thread_compat.h'
HOOK = NATIVE / 'windows_compat.cmake'


def run(args, *, expect_failure=False):
    result = subprocess.run([str(x) for x in args], text=True, capture_output=True)
    print('$', ' '.join(str(x) for x in args), flush=True)
    print(result.stdout + result.stderr, end='', flush=True)
    if expect_failure:
        assert result.returncode != 0 and 'THREAD_POWER_THROTTLING_STATE' in result.stderr
    else:
        assert result.returncode == 0, f'command failed: {result.returncode}'
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    gcc = shutil.which('gcc')
    assert gcc, 'Use the configured native compiler (Rtools GCC on Windows)'
    real_windows = os.name == 'nt'
    modes = ['actual-sdk'] if real_windows else ['missing-declarations', 'existing-declarations']
    for mode in modes:
        root = output / (mode + ' path with spaces')
        source = root / 'ggml/src/ggml-cpu/ggml-cpu.c'
        source.parent.mkdir(parents=True)
        headers = root / 'headers'
        headers.mkdir()
        version, mask = (7, 32) if mode == 'existing-declarations' else (1, 1)
        if not real_windows:
            sdk = '#ifndef TEST_WINDOWS_H\n#define TEST_WINDOWS_H\ntypedef unsigned int ULONG;\n'
            if mode == 'existing-declarations':
                sdk += ('#define THREAD_POWER_THROTTLING_CURRENT_VERSION 7\n'
                        '#define THREAD_POWER_THROTTLING_EXECUTION_SPEED 32\n'
                        'typedef struct { ULONG Version, ControlMask, StateMask; } THREAD_POWER_THROTTLING_STATE;\n')
            (headers / 'windows.h').write_text(sdk + '#endif\n')
        source.write_text(f'''#include <windows.h>
#include <stddef.h>
#include <stdio.h>
_Static_assert(sizeof(ULONG) == 4, "Windows ULONG ABI");
_Static_assert(sizeof(THREAD_POWER_THROTTLING_STATE) == 12, "thread state ABI");
_Static_assert(offsetof(THREAD_POWER_THROTTLING_STATE, Version) == 0, "version offset");
_Static_assert(offsetof(THREAD_POWER_THROTTLING_STATE, ControlMask) == 4, "control offset");
_Static_assert(offsetof(THREAD_POWER_THROTTLING_STATE, StateMask) == 8, "state offset");
_Static_assert(THREAD_POWER_THROTTLING_CURRENT_VERSION == {version}, "preserve header version");
_Static_assert(THREAD_POWER_THROTTLING_EXECUTION_SPEED == {mask}, "preserve header flag");
int unaffected(void);
int main(void) {{
    THREAD_POWER_THROTTLING_STATE t = {{THREAD_POWER_THROTTLING_CURRENT_VERSION,
        THREAD_POWER_THROTTLING_EXECUTION_SPEED, 0}};
#ifdef RELM_REAL_WINDOWS
    BOOL (WINAPI *function)(HANDLE, THREAD_INFORMATION_CLASS, LPVOID, DWORD) = SetThreadInformation;
    (void) function; /* link/signature only; no scheduling policy change */
#endif
    if (t.Version != {version} || t.ControlMask != {mask} || t.StateMask != 0 || unaffected()) return 1;
    puts("RELM_THREAD_COMPAT_OK {mode} size=12 offsets=0,4,8 version={version} mask={mask}");
    return 0;
}}
''')
        (root / 'ggml/src/unaffected.c').write_text('''#ifdef RELM_WINDOWS_THREAD_COMPAT_H
#error "compatibility header leaked into an unrelated source"
#endif
int unaffected(void) { return 0; }
''')
        definitions = 'RELM_REAL_WINDOWS' if real_windows else '_WIN32 __MINGW32__'
        (root / 'ggml/src/CMakeLists.txt').write_text(f'''add_executable(ggml-cpu ggml-cpu/ggml-cpu.c unaffected.c)
target_include_directories(ggml-cpu PRIVATE "${{CMAKE_SOURCE_DIR}}/headers")
target_compile_definitions(ggml-cpu PRIVATE {definitions})
target_compile_options(ggml-cpu PRIVATE -std=c11 -Wall -Wextra -Werror -pedantic)
''')
        # On Linux only the CMake selection is emulated; the SDK is explicitly a
        # fixture. On Windows this uses the actual Rtools headers and compiler.
        selection = '' if real_windows else 'set(WIN32 TRUE)\n'
        (root / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.28)
project(relm_thread_compat_control C)
{selection}include("{HOOK.as_posix()}")
add_subdirectory(ggml/src)
''')
        if mode == 'missing-declarations':
            run([gcc, '-std=c11', '-I', headers, '-c', source, '-o', root / 'refused.o'], expect_failure=True)
        build = root / 'build'
        generator = 'MSYS Makefiles' if real_windows else 'Unix Makefiles'
        run(['cmake', '-S', root, '-B', build, '-G', generator, '-DCMAKE_C_COMPILER=' + gcc])
        run(['cmake', '--build', build, '--parallel', '2'])
        exe = build / 'ggml/src' / ('ggml-cpu.exe' if real_windows else 'ggml-cpu')
        result = run([exe])
        assert f'RELM_THREAD_COMPAT_OK {mode}' in result.stdout
    if not real_windows:
        noop = output / 'non-windows.c'
        noop.write_text('#ifdef THREAD_POWER_THROTTLING_CURRENT_VERSION\n#error "Windows declarations leaked"\n#endif\nint main(void) { return 0; }\n')
        run([gcc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-include', HEADER,
             noop, '-o', output / 'non-windows'])
        run([output / 'non-windows'])
    receipt = {'status': 'passed', 'real_windows_sdk': real_windows, 'modes': modes,
               'negative_missing_type': not real_windows, 'non_windows_noop': not real_windows,
               'unrelated_source_header_absence': True, 'engine_builds': 0, 'model_calls': 0,
               'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [HEADER, HOOK, Path(__file__).resolve()]}}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
