"""Session-scoped SSH broker. No service, system changes, or secret files.

Protocol is JSON lines on stdin/stdout. One persistent Shell reads a private
command pipe; terminal input NEVER enters that pipe. A controlling PTY supports
/dev/tty. Its input queue is flushed with the input gate closed before each run.
"""
import base64
import errno
import fcntl
import hashlib
import json
import os
import pty
import selectors
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import uuid

MAX_FRAME = 262144


def emit(value):
    sys.stdout.write(json.dumps(value, separators=(',', ':')) + '\n')
    sys.stdout.flush()


def peer_pid(connection):
    if hasattr(socket, 'SO_PEERCRED'):
        return struct.unpack('3i', connection.getsockopt(
            socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
    # Darwin LOCAL_PEERPID; no terminal text is accepted as identity evidence.
    return struct.unpack('i', connection.getsockopt(0, 2, 4))[0]


def parent_pid(pid):
    result = subprocess.run(['ps', '-o', 'ppid=', '-p', str(pid)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return int(result.stdout.strip() or b'0')


def rpc(path, payload):
    connection = socket.socket(socket.AF_UNIX)
    connection.connect(path)
    connection.sendall((json.dumps(payload) + '\n').encode())
    return connection


def process_identity(pid):
    result = subprocess.run(['ps', '-o', 'lstart=', '-p', str(pid)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return result.stdout.strip().decode()


def process_alive(pid, identity):
    return bool(identity) and process_identity(pid) == identity


def client_mode(mode):
    if mode == '--askpass':
        connection = rpc(os.environ['CHIYO_SUDO_SOCKET'], {
            'kind': 'askpass', 'action': os.environ['CHIYO_SUDO_ACTION']})
        stream = connection.makefile('rb')
        response = json.loads(stream.readline(MAX_FRAME))
        if response.get('status') != 'delivered':
            return 1
        # Only sudo owns this stdout pipe. Never use the terminal as fallback.
        os.write(1, base64.b64decode(response['data']) + b'\n')
        return 0
    connection = rpc(os.environ['CHIYO_SUDO_SOCKET'], {'kind': 'sudo', 'argv': sys.argv[2:]})
    stream = connection.makefile('rb')
    result = json.loads(stream.readline(MAX_FRAME))
    if result.get('status') != 'prepared':
        return 125
    env = dict(os.environ)
    env['SUDO_ASKPASS'] = result['askpass']
    env['CHIYO_SUDO_ACTION'] = result['actionId']
    # sudo belongs to the Shell process group, has its controlling terminal, and
    # receives exactly the caller's cwd/env/stdio. The broker never sees env.
    process = subprocess.Popen([result['executable'], '-A', *sys.argv[2:]], env=env)
    connection.sendall((json.dumps({'pid': process.pid,
                                   'identity': process_identity(process.pid)}) + '\n').encode())
    code = process.wait()
    connection.close()
    return code if code >= 0 else 128 - code


class Broker:
    def __init__(self, synthetic_sudo=None):
        self.synthetic_sudo = synthetic_sudo
        self.selector = selectors.DefaultSelector()
        self.root = tempfile.mkdtemp(prefix='chiyo-ssh-')
        os.chmod(self.root, 0o700)
        self.path = os.path.join(self.root, 'helper.py')
        source = globals().get('CHIYO_SOURCE')
        if source is None:
            with open(__file__, 'r') as source_file:
                source = source_file.read()
        with open(self.path, 'w') as target:
            target.write('#!' + sys.executable + '\n' + source)
        os.chmod(self.path, 0o700)
        self.listener = socket.socket(socket.AF_UNIX)
        self.socket_path = os.path.join(self.root, 'sudo.sock')
        self.listener.bind(self.socket_path)
        self.listener.listen(8)
        self.listener.setblocking(False)
        self.master, self.slave = pty.openpty()
        self.tty = os.ttyname(self.slave)
        self.run = None
        self.draining = False
        self.inputs = {}
        self.actions = {}
        self.clients = {}
        self.writes = []
        self.stdin_buffer = b''
        self.control_buffer = b''
        shell = shutil.which('bash')
        if not shell:
            raise RuntimeError('missing_bash')

        def child_setup():
            os.setsid()
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)

        environment = dict(os.environ)
        environment['CHIYO_SUDO_SOCKET'] = self.socket_path
        environment['HISTFILE'] = '/dev/null'
        self.shell = subprocess.Popen(
            [shell, '--noprofile', '--norc'], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, preexec_fn=child_setup, pass_fds=(self.slave,))
        setup = "set -m\ntrap ':' INT\nchiyo_sudo() { " + shlex.quote(sys.executable)
        setup += ' ' + shlex.quote(self.path) + ' --sudo "$@"; }\nsudo() { chiyo_sudo "$@"; }\n'
        self.shell.stdin.write(setup.encode())
        self.shell.stdin.flush()
        for fd, kind in [(0, 'input'), (self.master, 'terminal'),
                         (self.shell.stdout.fileno(), 'control'),
                         (self.shell.stderr.fileno(), 'diagnostic'),
                         (self.listener.fileno(), 'listener')]:
            os.set_blocking(fd, False)
            self.selector.register(fd, selectors.EVENT_READ, kind)

    def reply(self, request, status, **fields):
        emit({'type': 'reply', 'id': request.get('id'),
              'status': status, **fields})

    def finish(self, code):
        current = self.run
        if current is None:
            return
        # Close the input gate before flushing; event processing is single-threaded.
        self.drain_terminal(current)
        self.run = None
        self.writes.clear()
        termios.tcflush(self.slave, termios.TCIFLUSH)
        for action in list(self.actions.values()):
            if action['runId'] == current:
                self.end_action(action)
        emit({'type': 'exited', 'runId': current, 'exitCode': code})

    def drain_terminal(self, run_id):
        while True:
            try:
                data = os.read(self.master, 8192)
            except (BlockingIOError, OSError):
                return
            if not data:
                return
            emit({'type': 'output', 'runId': run_id,
                  'data': base64.b64encode(data).decode()})

    def end_action(self, action):
        for key in ('receiver', 'pendingReceiver'):
            receiver = action.get(key)
            if receiver and receiver.fileno() >= 0:
                self.send_client(receiver, {'status': 'expired'})
        self.actions.pop(action['id'], None)

    def send_client(self, client, response):
        try:
            client.sendall((json.dumps(response) + '\n').encode())
        except OSError:
            pass
        self.close_client(client)

    def close_client(self, client):
        self.clients.pop(client.fileno(), None)
        try:
            self.selector.unregister(client.fileno())
        except (KeyError, ValueError):
            pass
        client.close()

    def command(self, request):
        op = request.get('op')
        if op == 'run':
            if self.draining:
                return self.reply(request, 'closed')
            if self.run is not None:
                return self.reply(request, 'busy')
            command = request.get('command')
            run_id = request.get('runId')
            if not isinstance(command, str) or not isinstance(run_id, str):
                return self.reply(request, 'invalid_request')
            # Idle terminal bytes cannot become the next program's input.
            termios.tcflush(self.slave, termios.TCIFLUSH)
            self.run = run_id
            self.inputs.clear()
            self.writes.clear()
            script = 'eval ' + shlex.quote(command)
            script += ' <' + shlex.quote(self.tty) + ' >' + shlex.quote(self.tty)
            script += ' 2>&1\nprintf "%s\\n" "$?"\n'
            self.shell.stdin.write(script.encode())
            self.shell.stdin.flush()
            self.reply(request, 'accepted', runId=self.run)
        elif op in ('input', 'interrupt', 'credential'):
            if self.run is None or request.get('runId') != self.run:
                return self.reply(request, 'stale_run')
            if op == 'interrupt':
                os.killpg(os.tcgetpgrp(self.master), signal.SIGINT)
                return self.reply(request, 'sent')
            if op == 'credential':
                action = self.actions.get(request.get('actionId'))
                receiver = action and action.get('receiver')
                if (not receiver or action['runId'] != self.run or
                        not process_alive(action.get('pid', 0), action.get('identity', ''))):
                    return self.reply(request, 'stale_receiver')
                # Recheck that the ASKPASS peer remains the registered sudo child.
                try:
                    live = (parent_pid(peer_pid(receiver)) == action['pid'])
                except (OSError, ValueError):
                    live = False
                if not live:
                    self.end_action(action)
                    return self.reply(request, 'stale_receiver')
                data = base64.b64decode(request['data'], validate=True)
                if b'\n' in data or b'\r' in data or b'\x00' in data:
                    return self.reply(request, 'invalid_credential')
                self.send_client(receiver, {'status': 'delivered', 'data': request['data']})
                action['receiver'] = None
                action['used'] = True
                return self.reply(request, 'delivered')
            input_id = request.get('inputId')
            data = base64.b64decode(request['data'], validate=True)
            if not isinstance(input_id, str) or len(data) > 16384 or len(self.inputs) >= 4096:
                return self.reply(request, 'input_limit')
            if input_id in self.inputs:
                status = 'duplicate' if self.inputs[input_id] == hashlib.sha256(data).digest() else 'input_conflict'
                return self.reply(request, status)
            self.inputs[input_id] = hashlib.sha256(data).digest()
            self.writes.append(memoryview(data))
            self.reply(request, 'accepted')
        elif op == 'resize':
            rows, columns = int(request['rows']), int(request['columns'])
            if not (1 <= rows <= 1000 and 1 <= columns <= 1000):
                return self.reply(request, 'invalid_request')
            fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                        struct.pack('HHHH', rows, columns, 0, 0))
            self.reply(request, 'ok')
        elif op == 'close':
            self.draining = True
            self.reply(request, 'draining' if self.run else 'closed')
            if request.get('force'):
                raise EOFError()
        else:
            self.reply(request, 'invalid_request')

    def sudo_client(self, client, message):
        state = self.clients[client.fileno()]
        if state[2] == 'register':
            action = self.actions.get(state[3])
            pid = message.get('pid', 0)
            identity = message.get('identity', '')
            if (not action or action['runId'] != self.run or
                    parent_pid(pid) != action['wrapperPid'] or
                    not process_alive(pid, identity)):
                if action:
                    self.end_action(action)
                return self.close_client(client)
            action['pid'], action['identity'] = pid, identity
            state[2] = 'waiting'
            receiver = action.get('pendingReceiver')
            if receiver:
                self.receive_askpass(receiver, action)
            self.selector.register(client.fileno(), selectors.EVENT_READ, 'client')
            return
        if message.get('kind') == 'sudo':
            if not self.run:
                return self.send_client(client, {'status': 'stale_run'})
            sudo = self.synthetic_sudo or shutil.which('sudo')
            if not sudo:
                return self.send_client(client, {'status': 'sudo_unavailable'})
            info = os.stat(sudo)
            if not self.synthetic_sudo and (info.st_uid != 0 or info.st_mode & 0o022):
                return self.send_client(client, {'status': 'sudo_identity_untrusted'})
            action_id = uuid.uuid4().hex
            action = {'id': action_id, 'runId': self.run, 'wrapper': client,
                      'wrapperPid': peer_pid(client), 'used': False, 'argv': message.get('argv', [])}
            self.actions[action_id] = action
            state[2], state[3] = 'register', action_id
            client.sendall((json.dumps({'status': 'prepared', 'actionId': action_id,
                                      'askpass': self.path, 'executable': sudo}) + '\n').encode())
            self.selector.register(client.fileno(), selectors.EVENT_READ, 'client')
            return
        if message.get('kind') != 'askpass':
            return self.close_client(client)
        action = self.actions.get(message.get('action'))
        if not action or action['runId'] != self.run or action.get('used'):
            return self.send_client(client, {'status': 'expired'})
        if 'pid' not in action:
            action['pendingReceiver'] = client
            return
        self.receive_askpass(client, action)

    def receive_askpass(self, client, action):
        if (not process_alive(action['pid'], action['identity']) or
                parent_pid(peer_pid(client)) != action['pid']):
            return self.send_client(client, {'status': 'expired'})
        action['receiver'] = client
        emit({'type': 'credential', 'runId': self.run,
              'actionId': action['id'], 'purpose': 'sudo', 'argv': action['argv']})

    def loop(self):
        emit({'type': 'ready', 'protocol': 1, 'capabilities': {
            'shell': 'bash', 'pty': True, 'controllingTerminal': True,
            'managedSudo': bool(self.synthetic_sudo or shutil.which('sudo')), 'mergedOutput': True}})
        while True:
            if self.shell.poll() is not None:
                # exit/exec/EOF are explicit Shell termination, never a new Shell.
                if self.run:
                    self.finish(self.shell.returncode)
                emit({'type': 'closed', 'reason': 'shell_exited'})
                return
            for key, _ in self.selector.select(0.02):
                fd, kind = key.fd, key.data
                if kind == 'listener':
                    client, _ = self.listener.accept()
                    client.setblocking(False)
                    self.clients[client.fileno()] = [client, b'', 'new', None]
                    self.selector.register(client.fileno(), selectors.EVENT_READ, 'client')
                    continue
                if kind == 'client':
                    client, buffer, _, _ = self.clients[fd]
                    chunk = client.recv(MAX_FRAME)
                    if not chunk:
                        self.close_client(client)
                        continue
                    buffer += chunk
                    if len(buffer) > MAX_FRAME:
                        self.close_client(client)
                    elif b'\n' in buffer:
                        self.selector.unregister(fd)
                        self.sudo_client(client, json.loads(buffer.split(b'\n', 1)[0]))
                    else:
                        self.clients[fd][1] = buffer
                    continue
                try:
                    data = os.read(fd, 8192)
                except OSError as error:
                    if error.errno == errno.EIO:
                        data = b''
                    else:
                        raise
                if not data:
                    if kind == 'input':
                        raise EOFError()
                    self.selector.unregister(fd)
                    continue
                if kind == 'input':
                    self.stdin_buffer += data
                    if len(self.stdin_buffer) > MAX_FRAME:
                        raise ValueError('frame_too_large')
                    while b'\n' in self.stdin_buffer:
                        line, self.stdin_buffer = self.stdin_buffer.split(b'\n', 1)
                        self.command(json.loads(line))
                elif kind == 'control':
                    self.control_buffer += data
                    while b'\n' in self.control_buffer:
                        line, self.control_buffer = self.control_buffer.split(b'\n', 1)
                        self.finish(int(line))
                elif kind == 'terminal':
                    emit({'type': 'output', 'runId': self.run,
                          'data': base64.b64encode(data).decode()})
                # Shell startup stderr is not a trusted completion channel.
            if self.writes and self.run:
                data = self.writes[0]
                try:
                    count = os.write(self.master, data)
                    if count == len(data):
                        self.writes.pop(0)
                    else:
                        self.writes[0] = data[count:]
                except BlockingIOError:
                    pass
            if self.draining and self.run is None:
                return

    def close(self):
        for client, _, _, _ in list(self.clients.values()):
            self.close_client(client)
        try:
            os.killpg(self.shell.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.close(self.master)
        os.close(self.slave)
        self.shell.wait(timeout=5)
        self.listener.close()
        self.selector.close()
        shutil.rmtree(self.root)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--sudo':
        return client_mode('--sudo')
    if os.environ.get('CHIYO_SUDO_ACTION'):
        return client_mode('--askpass')
    broker = Broker()
    try:
        broker.loop()
    except EOFError:
        pass
    finally:
        broker.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
