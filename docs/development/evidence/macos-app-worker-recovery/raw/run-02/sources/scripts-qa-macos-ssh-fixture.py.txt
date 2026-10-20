"""Loopback SSH fixture; fresh keys, fixed synthetic commands, no user profile.

Run with a NEW project-local directory. Requires the QA venv's paramiko.
Prints the loopback port after generating keys; Ctrl-C stops the fixture.
"""
import argparse
import json
from pathlib import Path
import shlex
import socket
import subprocess
import threading
import time

import paramiko


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--lifecycle-gate', action='store_true',
                        help='Allow one synthetic wait command until the owned release file exists')
    args = parser.parse_args()
    root = args.directory.resolve()
    root.mkdir(exist_ok=False)
    root.chmod(0o700)
    for name in ('client', 'wrong-client'):
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '',
                        '-f', str(root / name)], check=True)
    host = paramiko.RSAKey.generate(2048)
    (root / 'host.pub').write_text(f'{host.get_name()} {host.get_base64()} synthetic\n')
    expected = (root / 'client.pub').read_text().split()[1]
    counter_lock = threading.Lock()
    command_count = 0

    class Server(paramiko.ServerInterface):
        def check_auth_publickey(self, username, key):
            return (paramiko.AUTH_SUCCESSFUL if username == 'fixture' and
                    key.get_base64() == expected else paramiko.AUTH_FAILED)

        def get_allowed_auths(self, username):
            return 'publickey'

        def check_channel_request(self, kind, chanid):
            return (paramiko.OPEN_SUCCEEDED if kind == 'session' else
                    paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED)

        def check_channel_exec_request(self, channel, command):
            def execute():
                nonlocal command_count
                try:
                    argv = shlex.split(command.decode('utf-8'))
                    if argv in (['/usr/bin/true'], ['/usr/bin/false']):
                        code = int(argv[0].endswith('false'))
                    elif len(argv) == 3 and argv[:2] == ['/usr/bin/printf', '%s']:
                        channel.sendall(argv[2].encode('utf-8'))
                        code = 0
                    elif argv == ['/bin/sleep', '2']:
                        time.sleep(2)
                        code = 0
                    elif args.lifecycle_gate and argv == ['/fixture/wait']:
                        with counter_lock:
                            command_count += 1
                            (root / 'command-count').write_text(str(command_count))
                        deadline = time.monotonic() + 120
                        while not (root / 'release').exists() and time.monotonic() < deadline:
                            time.sleep(0.05)
                        code = 0 if (root / 'release').exists() else 124
                    else:
                        code = 126
                    channel.send_exit_status(code)
                finally:
                    channel.close()
            threading.Thread(target=execute, daemon=True).start()
            return True

    def connection(client):
        transport = paramiko.Transport(client)
        try:
            transport.add_server_key(host)
            transport.start_server(server=Server())
            channels = []
            while transport.is_active():
                channel = transport.accept(timeout=1)
                if channel is not None:
                    channels.append(channel)
                channels = [channel for channel in channels if not channel.closed]
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            transport.close()

    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(8)
        facts = {'directory': str(root), 'port': listener.getsockname()[1]}
        (root / 'fixture.json').write_text(json.dumps(facts))
        print(json.dumps(facts), flush=True)
        while True:
            client, _ = listener.accept()
            threading.Thread(target=connection, args=(client,), daemon=True).start()


if __name__ == '__main__':
    main()
