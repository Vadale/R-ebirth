#!/usr/bin/env python3
"""Fresh-process environment/supervisor boundaries; no model inference."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / 'examples/funding-service'

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('source-library', 'model', 'model-alias', 'backend', 'work-dir'):
        p.add_argument('--' + name, required=True)
    a = p.parse_args()
    work = Path(a.work_dir).resolve()
    work.mkdir(parents=True, exist_ok=False, mode=0o700)
    environment = work / 'environment'
    def run(args, success=True):
        result = subprocess.run(['Rscript', '--vanilla', *map(str, args)], cwd=ROOT,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        if (result.returncode == 0) != success:
            raise AssertionError(result.stdout)
        return result.stdout
    run([SERVICE/'setup.R', '--source-library', a.source_library, '--model', a.model,
         '--model-alias', a.model_alias, '--backend', a.backend, '--environment', environment])
    check = work / 'verify.R'
    check.write_text("args <- commandArgs(TRUE)\nsource(args[1])\np <- svc_environment(args[2])\nstopifnot(length(p$manifest$packages)==25L)\ncat('verified\\n')\n")
    command = [check, SERVICE/'common.R', environment]
    run(command)
    receipt = environment/'environment.json'
    original = receipt.read_bytes()
    def changed_receipt(mutate):
        obj = json.loads(original)
        mutate(obj)
        receipt.write_text(json.dumps(obj))
        try:
            run(command, False)
        finally:
            receipt.write_bytes(original)
    changed_receipt(lambda x: x.update(platform='foreign-platform'))
    changed_receipt(lambda x: x['model'].update(sha256='0'*64))
    changed_receipt(lambda x: x['service_sources'].update(unknown='0'*64))
    changed_receipt(lambda x: x['packages'].pop('ps'))
    prompt = environment/'prompt.txt'
    old_prompt = prompt.read_bytes()
    prompt.write_bytes(old_prompt + b'changed')
    try:
        run(command, False)
    finally:
        prompt.write_bytes(old_prompt)
    description = environment/'library/jsonlite/DESCRIPTION'
    original_description = description.read_bytes()
    description.write_bytes(original_description + b'\nTampered: yes\n')
    try:
        run(command, False)
    finally:
        description.write_bytes(original_description)
    package = environment/'library/ps'
    renamed = environment/'library/ps-held'
    package.rename(renamed)
    try:
        run(command, False)  # Ambient libraries must never fill a missing pin.
    finally:
        renamed.rename(package)
    run(command)
    for manager, extension in [('launchd', 'plist'), ('systemd-user', 'service')]:
        output = work / ('boundary.' + extension)
        run([SERVICE/'supervisor.R', '--manager', manager, '--name', 'relm-boundary',
             '--environment', environment, '--store', work/'store %literal $dollar space', '--output', output])
        if manager == 'launchd':
            unit = plistlib.loads(output.read_bytes())
            assert unit['Label'] == 'relm-boundary'
            assert str(work/'store %literal $dollar space') in unit['ProgramArguments']
            assert unit['ExitTimeOut'] == 15 and not unit['AbandonProcessGroup']
        else:
            unit = output.read_text()
            assert '%%literal $$dollar space' in unit and 'KillMode=control-group' in unit
        assert output.stat().st_mode & 0o777 == 0o600
    result = dict(status='passed', cases=11, model_loaded=False, scope='fresh-process environment refusal and generated supervisor escaping; actual manager acceptance separate')
    (work/'acceptance.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))

if __name__ == '__main__':
    main()
