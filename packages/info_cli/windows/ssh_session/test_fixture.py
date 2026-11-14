"""Self-made loopback SSH transport fixture; synthetic identities only.

Requires paramiko==5.1.0 in an isolated QA environment. No shell or system SSH
service is started. The 'echo' command echoes channel bytes and 'wait' waits for
connection termination. The caller owns a fresh directory and stdin lifetime.
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time

import paramiko


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--ssh-keygen', required=True)
    args = parser.parse_args()
    root = args.directory.resolve()
    root.mkdir(exist_ok=False)
    for name in ('client', 'encrypted'):
        subprocess.run([args.ssh_keygen, '-q', '-t', 'ed25519', '-N',
                        'synthetic-key-passphrase' if name == 'encrypted' else '',
                        '-f', str(root / name)], check=True)
    expected = {(root / f'{name}.pub').read_text().split()[1]
                for name in ('client', 'encrypted')}
    host = paramiko.RSAKey.generate(2048)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(16)
    port = listener.getsockname()[1]
    known = root / 'known_hosts'
    known.write_text(f'[127.0.0.1]:{port} {host.get_name()} {host.get_base64()}\n')
    stop = threading.Event()
    transports = []

    class Server(paramiko.ServerInterface):
        def check_auth_password(self, username, password):
            # Never write either supplied or expected authentication values.
            return (paramiko.AUTH_SUCCESSFUL if username == 'fixture' and
                    password == 'synthetic-login-password' else paramiko.AUTH_FAILED)

        def check_auth_publickey(self, username, key):
            return (paramiko.AUTH_SUCCESSFUL if username == 'fixture' and
                    key.get_base64() in expected else paramiko.AUTH_FAILED)

        def get_allowed_auths(self, username):
            return 'password,publickey'

        def check_channel_request(self, kind, chanid):
            return (paramiko.OPEN_SUCCEEDED if kind == 'session' else
                    paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED)

        def check_channel_exec_request(self, channel, command):
            def execute():
                try:
                    if command == b'echo':
                        channel.sendall(b'ready\n')
                        while data := channel.recv(32768):
                            channel.sendall(data)
                        channel.send_exit_status(0)
                    elif command == b'wait':
                        channel.sendall(b'ready\n')
                        while not channel.closed and not stop.wait(0.05):
                            pass
                    else:
                        channel.sendall(b'fixture-output\n')
                        channel.send_exit_status(7 if command == b'nonzero' else 0)
                except (EOFError, OSError):
                    pass
                finally:
                    channel.close()
            threading.Thread(target=execute, daemon=True).start()
            return True

    def connection(client):
        transport = paramiko.Transport(client)
        transports.append(transport)
        try:
            transport.add_server_key(host)
            transport.start_server(server=Server())
            channels = []
            while transport.is_active() and not stop.is_set():
                channel = transport.accept(timeout=0.1)
                if channel is not None:
                    channels.append(channel)
                channels = [channel for channel in channels if not channel.closed]
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            transport.close()

    def accept():
        listener.settimeout(0.2)
        while not stop.is_set():
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=connection, args=(client,), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()
    print(json.dumps({'port': port, 'knownHosts': str(known),
                      'key': str(root / 'client'),
                      'encryptedKey': str(root / 'encrypted')}), flush=True)
    sys.stdin.buffer.read()
    stop.set()
    listener.close()
    for transport in transports:
        transport.close()
    time.sleep(0.1)


if __name__ == '__main__':
    main()
