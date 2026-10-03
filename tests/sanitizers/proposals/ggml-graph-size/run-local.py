"""Bounded standalone verification; preserve every command and outcome."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

OUT = Path(__file__).resolve().parent
ROOT = Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
flags = ['-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function',
         '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-fno-omit-frame-pointer']
records = []
env = dict(os.environ, UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1',
           ASAN_OPTIONS='halt_on_error=1:abort_on_error=0')

def run(name, command):
    result = subprocess.run(command, text=True, capture_output=True, timeout=30, env=env)
    (OUT / (name + '.out')).write_text(result.stdout)
    (OUT / (name + '.err')).write_text(result.stderr)
    records.append({'name': name, 'command': command, 'exit_code': result.returncode})
    (OUT / 'local-commands.json').write_text(json.dumps(records, indent=2) + '\n')
    return result

assert run('compiler-version', ['clang', '--version']).returncode == 0
for stem in ('null-offset', 'layout-check'):
    command = ['clang', *flags, '-I' + str(ROOT / 'rebirth/src/llama.cpp/ggml/include'),
               '-I' + str(ROOT / 'rebirth/src/llama.cpp/ggml/src'),
               str(OUT / (stem + '.c')), '-o', str(OUT / stem)]
    result = run(stem + '-compile', command)
    if result.returncode != 0:
        raise RuntimeError(result.stderr)
original = run('null-offset-run', [str(OUT / 'null-offset')])
assert original.returncode == 1, original
assert 'applying non-zero offset 96 to null pointer' in original.stderr
assert not original.stdout
candidate = run('layout-check-run', [str(OUT / 'layout-check')])
assert candidate.returncode == 0, candidate.stderr
assert candidate.stdout.startswith('PASS: 68 layout cases;')
assert not candidate.stderr, candidate.stderr
assert run('patch-check', ['git', '-C', str(ROOT), 'apply', '--check',
                           str(OUT.parent / 'ggml-size-proposal.patch')]).returncode == 0
hashes = {str(path.relative_to(OUT)): hashlib.sha256(path.read_bytes()).hexdigest()
          for path in OUT.iterdir() if path.is_file() and path.name != 'local-sha256.json'}
(OUT / 'local-sha256.json').write_text(json.dumps(hashes, indent=2) + '\n')
print('Expected UBSan null+96 failure reproduced; candidate passed 68 standalone ASan/UBSan layout cases; proposal applies cleanly (not applied).')
