"""Real OS egress boundary for the native operational (G6) acceptance suite."""
import errno
import os
import platform
import socket
import sys

PROFILE = ('(version 1)(allow default)(deny network*)'
           '(allow network-inbound (local ip "localhost:*"))'
           '(allow network-outbound (remote ip "localhost:*"))'
           '(allow network* (local unix-socket) (remote unix-socket))')


def ensure_offline():
    system = platform.system()
    marker = os.environ.get('RELM_SERVICE_OFFLINE_BOUNDARY')
    if not marker:
        env = os.environ.copy()
        env['RELM_SERVICE_OFFLINE_BOUNDARY'] = system
        command = [sys.executable, *sys.argv]
        if system == 'Darwin':
            os.execve('/usr/bin/sandbox-exec', ['/usr/bin/sandbox-exec', '-p', PROFILE, *command], env)
        if system == 'Linux':
            # This script executes before the service/tests exist. Only loopback
            # is brought up; then root privileges are dropped for the entire run.
            env['RELM_SERVICE_HOST_NETNS'] = os.readlink('/proc/self/ns/net')
            script = ('ip link set lo up; '
                      'exec setpriv --reuid="$1" --regid="$2" --init-groups -- "${@:3}"')
            argv = ['sudo', '-n', '--preserve-env=PATH,RELM_SERVICE_OFFLINE_BOUNDARY,RELM_SERVICE_HOST_NETNS,RELM_SAMPLER_NICE',
                    'unshare', '--net', '--', 'bash', '-eu', '-c', script, 'service-offline',
                    str(os.getuid()), str(os.getgid()), *command]
            os.execvpe(argv[0], argv, env)
        raise RuntimeError('G6 offline boundary is supported only on Mac/Linux')
    if marker != system:
        raise RuntimeError('Offline boundary platform mismatch')
    if system == 'Linux':
        if os.readlink('/proc/self/ns/net') == os.environ.get('RELM_SERVICE_HOST_NETNS'):
            raise RuntimeError('The acceptance process did not enter a private network namespace')
        # sysfs can retain the host's mount-associated network namespace after
        # unshare --net. Query the current process namespace through sockets.
        if {name for _, name in socket.if_nameindex()} != {'lo'}:
            raise RuntimeError('A non-loopback interface exists inside the offline namespace')
    try:
        with socket.create_connection(('1.1.1.1', 443), timeout=2):
            raise AssertionError('Non-loopback connection unexpectedly succeeded')
    except OSError as error:
        allowed = {errno.EPERM, errno.EACCES} if system == 'Darwin' else {errno.ENETUNREACH, errno.EHOSTUNREACH}
        if error.errno not in allowed:
            raise RuntimeError(f'No positive OS-denial evidence: {error}') from error
        rejection = dict(errno=error.errno, reason=os.strerror(error.errno))
    with socket.socket() as server:
        server.bind(('127.0.0.1', 0)); server.listen(1)
        with socket.create_connection(server.getsockname(), timeout=2):
            accepted, _ = server.accept(); accepted.close()
    return dict(boundary='sandbox-exec loopback-only' if system == 'Darwin' else 'private loopback-only network namespace',
                non_loopback_probe=rejection, loopback_probe='passed', inherited_by_service_and_worker=True)


if __name__ == '__main__':
    import json
    print(json.dumps(ensure_offline()))
