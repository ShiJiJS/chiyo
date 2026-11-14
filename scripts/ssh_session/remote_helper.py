"""Session-scoped SSH broker. No service, system changes, or secret files.

Protocol is JSON lines on stdin/stdout. One persistent Shell reads a private
command pipe; terminal input NEVER enters that pipe. A controlling PTY supports
/dev/tty. Its input queue is flushed with the input gate closed before each run.
"""
import array
import base64
import ctypes
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
import stat
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


def process_stat(pid):
    with open('/proc/%d/stat' % pid, 'r') as source:
        value = source.read()
    return value[value.rfind(')') + 2:].split()


def parent_pid(pid):
    return int(process_stat(pid)[1])


def rpc(path, payload):
    connection = socket.socket(socket.AF_UNIX)
    connection.connect(path)
    connection.sendall((json.dumps(payload) + '\n').encode())
    return connection


def process_identity(pid):
    try:
        with open('/proc/sys/kernel/random/boot_id', 'r') as source:
            boot = source.read().strip()
        return boot + ':' + process_stat(pid)[19]
    except (OSError, IndexError, ValueError):
        return ''


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
    connection = socket.socket(socket.AF_UNIX)
    connection.connect(os.environ['CHIYO_SUDO_SOCKET'])
    payload = {'kind': 'sudo', 'argv': sys.argv[2:], 'cwd': os.getcwd(), 'env': dict(os.environ)}
    connection.sendmsg([(json.dumps(payload) + '\n').encode()],
                       [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [0, 1, 2]))])
    result = json.loads(connection.makefile('rb').readline(MAX_FRAME))
    return int(result.get('exitCode', 125))


def require_descendant_supervision():
    # Without kernel adoption of orphaned descendants, an old setsid/double-fork
    # reader could be invisible. Never continue a shared PTY on that assumption.
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(libc, 'prctl', None)
    if prctl is None or prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise RuntimeError('missing_descendant_subreaper')
    children(os.getpid())


def children(pid):
    with open('/proc/%d/task/%d/children' % (pid, pid), 'r') as source:
        return [int(value) for value in source.read().split()]


def session_leader():
    if os.getsid(0) == os.getpid():
        return
    try:
        os.setsid()
    except PermissionError:
        child = os.fork()
        if child:
            _, status = os.waitpid(child, 0)
            sys.exit(os.waitstatus_to_exitcode(status))
        os.setsid()


class Broker:
    def __init__(self, synthetic_sudo=None):
        require_descendant_supervision()
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
        fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        self.run = None
        self.draining = False
        self.unusable = False
        self.close_requested = False
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
            os.setpgid(0, 0)
            signal.signal(signal.SIGTTOU, signal.SIG_DFL)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            signal.signal(signal.SIGQUIT, signal.SIG_DFL)
            signal.signal(signal.SIGHUP, signal.SIG_DFL)

        environment = dict(os.environ)
        environment['CHIYO_SUDO_SOCKET'] = self.socket_path
        environment['HISTFILE'] = '/dev/null'
        environment['HISTSIZE'] = '0'
        environment['PS1'] = ''
        environment['PS2'] = ''
        self.shell = subprocess.Popen(
            [shell, '--noprofile', '--norc', '-i'], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, preexec_fn=child_setup, pass_fds=(self.slave,))
        os.tcsetpgrp(self.slave, self.shell.pid)
        os.kill(self.shell.pid, signal.SIGCONT)
        setup = "set -m\n_chiyo_evaluate() { eval \"$1\"; }\ntrap 'return 130' INT\nchiyo_sudo() { " + shlex.quote(sys.executable)
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
        if self.shell.poll() is None:
            # Freeze the only process allowed to create a new run. Kernel child
            # lists plus subreaper adoption account for ordinary, setsid, and
            # double-fork descendants, including inherited terminal descriptors.
            os.kill(self.shell.pid, signal.SIGSTOP)
            os.waitpid(self.shell.pid, os.WUNTRACED)
            try:
                leftovers = children(self.shell.pid)
                while True:
                    try:
                        reaped, _ = os.waitpid(-1, os.WNOHANG)
                        if reaped <= 0:
                            break
                    except ChildProcessError:
                        break
                leftovers += [p for p in children(os.getpid()) if p != self.shell.pid]
                if leftovers:
                    self.draining = True
                    self.unusable = True

            finally:
                os.kill(self.shell.pid, signal.SIGCONT)


        emit({'type': 'exited', 'runId': current, 'exitCode': code, 'reusable': not self.draining and self.shell.poll() is None})
        if self.unusable:
            emit({'type': 'unusable', 'reason': 'terminal_descendants_active'})

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
        state = self.clients.pop(client.fileno(), None)
        if state:
            for descriptor in state[4]:
                os.close(descriptor)
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
            script = '_chiyo_evaluate ' + shlex.quote(command)
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
            if sum(len(value) for value in self.writes) + len(data) > 65536:
                return self.reply(request, 'input_backpressure')
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
            self.close_requested = True
            self.reply(request, 'draining' if self.run else 'closed')
            if request.get('force'):
                raise EOFError()
        else:
            self.reply(request, 'invalid_request')

    def sudo_client(self, client, message):
        if message.get('kind') == 'sudo':
            if not self.run:
                return self.send_client(client, {'exitCode': 125})
            sudo = self.synthetic_sudo or shutil.which('sudo')
            if sudo:
                sudo = os.path.realpath(sudo)
            if not sudo:
                return self.send_client(client, {'exitCode': 127})
            info = os.stat(sudo)
            if not self.synthetic_sudo and (info.st_uid != 0 or info.st_mode & 0o022 or not info.st_mode & stat.S_ISUID or os.path.basename(sudo) != 'sudo'):
                return self.send_client(client, {'exitCode': 126})
            if not self.synthetic_sudo:
                parent = os.path.dirname(sudo)
                while True:
                    info = os.stat(parent)
                    if info.st_uid != 0 or info.st_mode & 0o022:
                        return self.send_client(client, {'exitCode': 126})
                    if parent == '/':
                        break
                    parent = os.path.dirname(parent)
            argv, cwd, env = message.get('argv'), message.get('cwd'), message.get('env')
            if (not isinstance(argv, list) or not argv or
                    any(not isinstance(a, str) for a in argv) or
                    not isinstance(cwd, str) or not isinstance(env, dict)):
                return self.send_client(client, {'exitCode': 125})
            wrapper_pid = peer_pid(client)
            # The wrapper must belong to this active Shell's process tree.
            ancestor = wrapper_pid
            for _ in range(128):
                if ancestor == self.shell.pid:
                    break
                ancestor = parent_pid(ancestor)
                if ancestor <= 1:
                    return self.send_client(client, {'exitCode': 125})
            else:
                return self.send_client(client, {'exitCode': 125})
            action_id = uuid.uuid4().hex
            env['SUDO_ASKPASS'] = self.path
            env['CHIYO_SUDO_ACTION'] = action_id
            env['CHIYO_SUDO_SOCKET'] = self.socket_path
            group = os.getpgid(wrapper_pid)
            def sudo_setup():
                os.setpgid(0, group)
                signal.signal(signal.SIGTTOU, signal.SIG_DFL)
                signal.signal(signal.SIGINT, signal.SIG_DFL)
                signal.signal(signal.SIGQUIT, signal.SIG_DFL)
                signal.signal(signal.SIGHUP, signal.SIG_DFL)
            # The broker creates and holds the actual selected sudo process.
            # No run-owned client can nominate or register an authentication PID.
            descriptors = self.clients[client.fileno()][4]
            if len(descriptors) != 3:
                return self.send_client(client, {'exitCode': 125})
            process = subprocess.Popen([sudo, '-A', *argv], cwd=cwd, env=env,
                                       stdin=descriptors[0], stdout=descriptors[1],
                                       stderr=descriptors[2], preexec_fn=sudo_setup)
            for descriptor in descriptors:
                os.close(descriptor)
            self.clients[client.fileno()][4] = []
            self.actions[action_id] = {
                'id': action_id, 'runId': self.run, 'wrapper': client,
                'pid': process.pid, 'identity': process_identity(process.pid),
                'process': process, 'used': False, 'argv': argv}
            return
        if message.get('kind') != 'askpass':
            return self.close_client(client)
        action = self.actions.get(message.get('action'))
        if not action or action['runId'] != self.run or action.get('used'):
            return self.send_client(client, {'status': 'expired'})
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
            'managedSudo': bool(self.synthetic_sudo or shutil.which('sudo')), 'mergedOutput': True, 'descendantSupervision': True}})
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
                    try:
                        client, _ = self.listener.accept()
                    except BlockingIOError:
                        continue
                    client.setblocking(False)
                    self.clients[client.fileno()] = [client, b'', 'new', None, []]
                    self.selector.register(client.fileno(), selectors.EVENT_READ, 'client')
                    continue
                if kind == 'client':
                    client, buffer, _, _, descriptors = self.clients[fd]
                    try:
                        chunk, ancillary, flags, _ = client.recvmsg(MAX_FRAME, socket.CMSG_SPACE(3 * 4))
                    except BlockingIOError:
                        continue
                    for level, kind, payload in ancillary:
                        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                            received = array.array('i')
                            received.frombytes(payload[:len(payload) - len(payload) % received.itemsize])
                            descriptors.extend(received)
                    if flags & socket.MSG_CTRUNC or len(descriptors) > 3:
                        self.close_client(client)
                        continue
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
                except BlockingIOError:
                    continue
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
            for action in list(self.actions.values()):
                code = action['process'].poll()
                if code is not None:
                    self.send_client(action['wrapper'], {'exitCode': code if code >= 0 else 128 - code})
                    self.end_action(action)
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
            if self.draining and self.run is None and (not self.unusable or self.close_requested):
                return

    def close(self):
        for client, _, _, _, _ in list(self.clients.values()):
            self.close_client(client)
        try:
            os.kill(self.shell.pid, signal.SIGKILL)
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
    session_leader()
    # SSH EOF owns broker lifetime; terminal job-control hangups must not bypass
    # its explicit unusable/close protocol. Child processes retain normal HUP.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    try:
        broker = Broker()
    except RuntimeError as error:
        emit({'type': 'unsupported', 'capability': str(error)})
        return 78
    try:
        broker.loop()
    except EOFError:
        pass
    finally:
        broker.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
