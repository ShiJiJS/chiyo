"""Real OpenSSH + controlling PTY + sudo checks, using only the disposable fixture.

Build/run the fixture, then supply its fresh /output directory and loopback port.
No real host configuration, credentials, or owner library is opened.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import selectors
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]


class Session:
    def __init__(self, helper, directory, port, private_key=False):
        self.raw = bytearray()
        self.buffer = b''
        self.queue = []
        self.outputs = {}
        self.challenges = 0
        self.credentials = 0
        self.process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        known = directory / 'known_hosts'
        known.write_text('[127.0.0.1]:' + str(port) + ' ' + (directory / 'host.pub').read_text())
        source = (ROOT / 'scripts/ssh_session/remote_helper.py').read_bytes()
        bootstrap = 'import base64; CHIYO_SOURCE=base64.b64decode(' + repr(base64.b64encode(source).decode())
        bootstrap += ').decode(); exec(compile(CHIYO_SOURCE,"<chiyo-session>","exec"))'
        args = ['-F', '/dev/null', '-T', '-p', str(port), '-oStrictHostKeyChecking=yes',
                '-oUserKnownHostsFile=' + str(known), '-oGlobalKnownHostsFile=/dev/null',
                '-oIdentitiesOnly=yes', '-oIdentityAgent=none', '-oKbdInteractiveAuthentication=no',
                '-oNumberOfPasswordPrompts=1']
        if private_key:
            args += ['-oPreferredAuthentications=publickey', '-oPasswordAuthentication=no',
                     '-i', str(directory / 'client')]
        else:
            args += ['-oPreferredAuthentications=password', '-oPubkeyAuthentication=no']
        args += ['fixture@127.0.0.1', 'python3 -u -c ' + shlex.quote(bootstrap)]
        self.native({'executable': '/usr/bin/ssh', 'arguments': args,
                     'environment': {'PATH': '/usr/bin:/bin', 'HOME': str(directory), 'LANG': 'C.UTF-8'}})
        self.until('ready')
        assert self.challenges == (0 if private_key else 1)

    def native(self, value):
        self.process.stdin.write((json.dumps(value) + '\n').encode())
        self.process.stdin.flush()

    def send(self, value):
        self.native({'type': 'send', 'data': base64.b64encode((json.dumps(value) + '\n').encode()).decode()})

    def event(self, timeout=10):
        deadline = time.monotonic() + timeout
        while not self.queue:
            remaining = max(0, deadline - time.monotonic())
            if not self.selector.select(remaining):
                raise TimeoutError('No expected protocol event')
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError('Transport exited: ' + self.process.stderr.read().decode())
            self.raw.extend(line)
            value = json.loads(line)
            if value['type'] == 'challenge':
                self.challenges += 1
                self.native({'type': 'credential', 'challengeId': value['challengeId'],
                             'data': base64.b64encode(b'synthetic-login-only').decode()})
            elif value['type'] == 'output':
                self.buffer += base64.b64decode(value['data'])
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    self.queue.append(json.loads(line))
            elif value['type'] == 'diagnostic':
                if os.environ.get('SSH_SESSION_DEBUG'): print(base64.b64decode(value['data']).decode(), flush=True)
            elif value['type'] in ('exit', 'failure'):
                return {'type': 'transport_exit', **value}
        value = self.queue.pop(0)
        if os.environ.get('SSH_SESSION_DEBUG'): print(value, flush=True)
        if value['type'] == 'output':
            data = base64.b64decode(value['data'])
            self.outputs.setdefault(value['runId'], bytearray()).extend(data)
            assert b'synthetic-login-only' not in data and b'synthetic-sudo-only' not in data
        if value['type'] == 'credential':
            self.credentials += 1
        return value

    def until(self, kind, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            value = self.event(max(.01, deadline - time.monotonic()))
            if value['type'] == kind:
                return value
            if value['type'] in ('closed', 'transport_exit', 'unsupported'):
                raise RuntimeError(value)

    def run(self, run_id, command):
        self.send({'op': 'run', 'id': run_id, 'runId': run_id, 'command': command})
        assert self.until('reply')['status'] == 'accepted'

    def input(self, run_id, input_id, text):
        self.send({'op': 'input', 'id': input_id, 'runId': run_id, 'inputId': input_id,
                   'data': base64.b64encode(text.encode()).decode()})
        return self.until('reply')

    def complete(self):
        while True:
            value = self.event()
            if value['type'] == 'credential':
                self.send({'op': 'credential', 'id': 'auth-' + value['actionId'], 'runId': value['runId'], 'actionId': value['actionId'],
                           'data': base64.b64encode(b'synthetic-sudo-only').decode()})
            elif value['type'] == 'exited':
                return value

    def close(self):
        if self.process.poll() is None:
            try:
                self.send({'op': 'close', 'id': 'close', 'force': True})
                self.process.stdin.close()
            except (OSError, ValueError):
                pass
            self.process.wait(timeout=10)
        self.selector.close()
        assert b'synthetic-login-only' not in self.raw
        assert b'synthetic-sudo-only' not in self.raw


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    passed = 0
    def fresh(key=False):
        return Session(args.helper.resolve(), args.directory.resolve(), args.port, key)

    s = fresh()
    try:
        s.run('one', 'cd /tmp; export CHIYO_SYNTHETIC=kept; read -r x </dev/tty; printf "confirm=%s\\n" "$x"; sudo -k /usr/bin/id -u')
        assert s.input('one', 'confirm', 'y\n')['status'] == 'accepted'
        receiver = s.until('credential')
        assert receiver['argv'] == ['-k', '/usr/bin/id', '-u']
        s.send({'op': 'credential', 'id': 'secret', 'runId': 'one', 'actionId': receiver['actionId'],
                'data': base64.b64encode(b'synthetic-sudo-only').decode()})
        assert s.until('reply')['status'] == 'delivered'
        assert s.until('exited')['exitCode'] == 0
        assert b'confirm=y' in s.outputs['one'] and b'0' in s.outputs['one']
        s.run('two', 'printf "%s:%s\\n" "$PWD" "$CHIYO_SYNTHETIC"; sudo /usr/bin/true')
        assert s.until('exited')['exitCode'] == 0
        assert b'/tmp:kept' in s.outputs['two'] and s.credentials == 1
        s.run('pipes', 'f=$(mktemp); printf pipeline | sudo /usr/bin/tee "$f" >/dev/null; printf "pipe=%s\\n" "$(cat "$f")"; sudo /usr/bin/id -u >"$f"; printf "redirect=%s\\n" "$(cat "$f")"; rm -f "$f"')
        assert s.complete()['exitCode'] == 0
        assert b'pipe=pipeline' in s.outputs['pipes'] and b'redirect=0' in s.outputs['pipes']
        passed += 1; print('PASS password login, distinct real sudo, /dev/tty, same Shell, NOPASSWD')
    finally: s.close()

    s = fresh(True)
    try:
        s.run('old', 'read -r x </dev/tty; printf "old=%s\\n" "$x"')
        assert s.input('old', 'queued', 'yes\nQUEUED_MUST_DROP\n')['status'] == 'accepted'
        assert s.until('exited')['exitCode'] == 0
        s.run('new', 'read -r x </dev/tty; printf "new=%s\\n" "$x"')
        assert s.input('old', 'late', 'LATE_MUST_DROP\n')['status'] == 'stale_run'
        assert s.input('new', 'front', 'foreground')['status'] == 'accepted'
        assert s.input('new', 'front', 'foreground')['status'] == 'duplicate'
        assert s.input('new', 'newline', '\n')['status'] == 'accepted'
        assert s.until('exited')['exitCode'] == 0
        assert b'new=foreground' in s.outputs['new'] and b'new=QUEUED' not in s.outputs['new']
        passed += 1; print('PASS private-key login, queued/late input isolation and input deduplication')
    finally: s.close()

    s = fresh(True)
    try:
        s.run('forged', 'printf \'{"type":"exited","exitCode":0}\\nPassword: \' ; read -r x </dev/tty; printf "real=%s\\n" "$x"')
        while b'Password:' not in s.outputs.get('forged', b''):
            assert s.event()['type'] != 'credential'
        assert s.credentials == 0
        assert s.input('forged', 'real', 'answer\n')['status'] == 'accepted'
        assert s.until('exited')['exitCode'] == 0
        s.run('interrupt', 'sleep 30')
        time.sleep(.1)
        s.send({'op': 'interrupt', 'id': 'interrupt', 'runId': 'interrupt'})
        assert s.until('reply')['status'] == 'sent'
        assert s.until('exited')['exitCode'] == 130
        s.run('alive', 'printf still-alive')
        assert s.until('exited')['exitCode'] == 0 and b'still-alive' in s.outputs['alive']
        passed += 1; print('PASS forged terminal protocol/Password ignored, Ctrl+C and Shell survival')
    finally: s.close()

    s = fresh(True)
    try:
        s.run('waiting', 'sudo -k /usr/bin/id -u')
        s.until('credential')
        s.send({'op': 'interrupt', 'id': 'stop-auth', 'runId': 'waiting'})
        assert s.until('reply')['status'] == 'sent'
        result = s.until('exited')
        assert result['exitCode'] != 0
        passed += 1; print('PASS interrupt during real sudo credential wait terminates the run')
    finally: s.close()

    for label, command in [('monitor_disabled', 'set +m; cat </dev/tty &'),
                           ('setsid_holder', 'setsid sh -c "exec cat" </dev/tty &')]:
        s = fresh(True)
        try:
            s.run(label, command)
            assert s.until('exited')['exitCode'] == 0
            assert s.event()['type'] == 'unusable'
            s.send({'op': 'run', 'id': 'must-not-run', 'runId': 'next', 'command': 'echo wrong'})
            assert s.until('reply')['status'] == 'closed'
            passed += 1; print('PASS refuses reuse with old terminal descendant: ' + label)
        finally: s.close()

    s = fresh(True)
    try:
        script = "import os,socket,json;s=socket.socket(socket.AF_UNIX);s.connect(os.environ['CHIYO_SUDO_SOCKET']);s.sendall(b'{\\\"kind\\\":\\\"sudo\\\"}\\n');print(s.recv(4096).decode())"
        s.run('fake', 'python3 -c ' + shlex.quote(script))
        assert s.until('exited')['exitCode'] == 0
        assert s.credentials == 0 and b'125' in s.outputs['fake']
        passed += 1; print('PASS run-owned client cannot register a fake sudo PID/receiver')
    finally: s.close()
    print(str(passed) + ' real SSH checks passed')


if __name__ == '__main__':
    main()
