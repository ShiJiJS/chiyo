"""Loopback-only authentication fixture; no shell or real credentials.

Offer keyboard-interactive with OpenSSH's ordinary password prompt text. Stdin
lifetime belongs to the test, and the audit contains only an attempt count.
"""
import json
from pathlib import Path
import socket
import sys
import threading

import paramiko


def main():
    root = Path(sys.argv[1])
    host = paramiko.RSAKey.generate(2048)
    stop = threading.Event()
    transports = []
    attempts = 0
    audit = root / 'attempts.json'
    audit.write_text('0')

    class Server(paramiko.ServerInterface):
        def get_allowed_auths(self, username):
            return 'keyboard-interactive'

        def check_auth_interactive(self, username, submethods):
            nonlocal attempts
            attempts += 1
            audit.write_text(json.dumps(attempts))
            return paramiko.InteractiveQuery(
                '', '', ("fixture@127.0.0.1's password: ", False))

        def check_auth_interactive_response(self, responses):
            return paramiko.AUTH_FAILED

    def connection(client):
        transport = paramiko.Transport(client)
        transports.append(transport)
        try:
            transport.add_server_key(host)
            transport.start_server(server=Server())
            while transport.is_active() and not stop.wait(0.05):
                pass
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            transport.close()

    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(4)
        listener.settimeout(0.1)
        port = listener.getsockname()[1]
        known = root / 'known_hosts'
        known.write_text(
            f'[127.0.0.1]:{port} {host.get_name()} {host.get_base64()}\n')

        def accept():
            while not stop.is_set():
                try:
                    client, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                threading.Thread(target=connection, args=(client,), daemon=True).start()

        thread = threading.Thread(target=accept, daemon=True)
        thread.start()
        print(json.dumps({'port': port, 'knownHosts': str(known)}), flush=True)
        sys.stdin.buffer.read()
        stop.set()
        thread.join(timeout=1)
        for transport in transports:
            transport.close()


if __name__ == '__main__':
    main()
