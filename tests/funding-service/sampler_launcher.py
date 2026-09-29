#!/usr/bin/env python3
"""Apply optional Linux observer priority before exec, without preexec_fn or sudo."""
import json
import os
from pathlib import Path
import resource
import shutil
import sys


def main():
    if len(sys.argv) < 3:
        raise SystemExit('Usage: sampler_launcher.py METADATA_FILE COMMAND [ARG ...]')
    requested = os.environ.get('RELM_SAMPLER_NICE')
    if requested not in (None, '0', '-10'):
        raise ValueError('RELM_SAMPLER_NICE must be unset, 0 or -10')
    inherited = os.getpriority(os.PRIO_PROCESS, 0)
    if requested is not None:
        if sys.platform != 'linux': raise RuntimeError('Explicit sampler priority is Linux-only')
        # PID zero targets this launcher alone; exec preserves its identity.
        # Permission errors abort rather than silently falling back to nice 0.
        os.setpriority(os.PRIO_PROCESS, 0, int(requested))
    actual = os.getpriority(os.PRIO_PROCESS, 0)
    if requested is not None and actual != int(requested):
        raise RuntimeError('Sampler priority was not applied')
    metadata = dict(scope='External RSS observer only', pid=os.getpid(),
                    uid=os.getuid(), euid=os.geteuid(), inherited_nice=inherited,
                    requested_nice=int(requested) if requested is not None else None,
                    actual_nice=actual,
                    nice_limit=resource.getrlimit(resource.RLIMIT_NICE) if hasattr(resource, 'RLIMIT_NICE') else None)
    Path(sys.argv[1]).write_text(json.dumps(metadata, indent=2) + '\n')
    command = shutil.which(sys.argv[2])
    if not command: raise RuntimeError('Sampler executable not found: ' + sys.argv[2])
    os.execv(command, [command, *sys.argv[3:]])


if __name__ == '__main__':
    main()
