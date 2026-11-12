"""Synthetic Windows transport checks; no Chiyo grants or real services.

Requires the EXCLUDE_FROM_ALL credential_receiver_fixture target. Optional SSH
checks use Paramiko on loopback with a fresh pinned host key, never user keys,
ssh config, known_hosts, or an installed sshd. This proves OS receiver behavior,
not the shared request-use/run-use integration or file ACL implementation.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receiver', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--ssh', type=Path)
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('Run these native checks on Windows')
    receiver = args.receiver.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    facts = []

    def record(name, **value):
        fact = {'check': name, **value}
        facts.append(fact)
        print(json.dumps(fact), flush=True)
        (output / 'results.json').write_text(json.dumps(facts, indent=2), encoding='utf-8')

    environment = {k: v for k, v in os.environ.items()
                   if not k.upper().startswith(('SSH_', 'CHIYO_QA_'))}
    value = '  Synthetic-' + secrets.token_hex(16) + '-中文🧭  '
    for label, secret in [('unicode-spaces', value), ('newlines', value + '\r\nline\n')]:
        env = {**environment, 'CHIYO_QA_EXPECTED': secret}
        material = output / ('合成材料 ' + label + '.txt')
        material.write_bytes(secret.encode('utf-8'))
        try:
            for mode in ('stdin', 'env', 'file'):
                child_env = dict(env)
                if mode == 'env':
                    child_env['CHIYO_QA_DELIVERY'] = secret
                command = [str(receiver), mode]
                if mode == 'file':
                    command.append(str(material))
                result = subprocess.run(command, input=secret.encode('utf-8') if mode == 'stdin' else b'',
                                        env=child_env, capture_output=True, timeout=10,
                                        creationflags=subprocess.CREATE_NO_WINDOW)
                passed = result.returncode == 0 and result.stderr == b'' and json.loads(result.stdout) == {'matches': True}
                record(mode + '-' + label, passed=passed, exitCode=result.returncode)
                if not passed:
                    raise AssertionError('Synthetic receiver mismatch')
        finally:
            material.unlink()

    if args.ssh:
        import paramiko
        ssh = args.ssh.resolve(strict=True)
        host = paramiko.RSAKey.generate(2048)
        lock = threading.Lock()
        attempts = []
        active = []
        stopped = threading.Event()

        class Server(paramiko.ServerInterface):
            def check_auth_password(self, username, password):
                accepted = username == 'fixture' and password == value
                with lock:
                    attempts.append(accepted)
                return paramiko.AUTH_SUCCESSFUL if accepted else paramiko.AUTH_FAILED

            def get_allowed_auths(self, username):
                return 'password'

            def check_channel_request(self, kind, chanid):
                return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

            def check_channel_exec_request(self, channel, command):
                if command != b'/usr/bin/true':
                    return False
                def finish():
                    channel.send_exit_status(0)
                    channel.shutdown_write()
                threading.Thread(target=finish, daemon=True).start()
                return True

        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(4)
        listener.settimeout(.2)
        port = listener.getsockname()[1]
        known = output / 'known_hosts'
        known.write_text(f'[127.0.0.1]:{port} {host.get_name()} {host.get_base64()}\n', encoding='ascii')

        def connection(client):
            transport = paramiko.Transport(client)
            with lock:
                active.append(transport)
            try:
                transport.add_server_key(host)
                transport.start_server(server=Server())
                channel = transport.accept(timeout=10)
                if channel:
                    stopped.wait(10)
                    channel.close()
            except (EOFError, OSError, paramiko.SSHException):
                pass
            finally:
                transport.close()

        def accept():
            while not stopped.is_set():
                try:
                    client, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                threading.Thread(target=connection, args=(client,), daemon=True).start()

        thread = threading.Thread(target=accept, daemon=True)
        thread.start()
        command = [str(ssh), '-F', 'NUL', '-T', '-o', 'StrictHostKeyChecking=yes',
                   '-o', 'UserKnownHostsFile=' + str(known), '-o', 'GlobalKnownHostsFile=NUL',
                   '-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=password',
                   '-o', 'NumberOfPasswordPrompts=1', '-o', 'ConnectTimeout=5',
                   '-p', str(port), 'fixture@127.0.0.1', '/usr/bin/true']
        try:
            version = subprocess.run([str(ssh), '-V'], capture_output=True, timeout=5)
            record('ssh-version', version=version.stderr.decode('utf-8', errors='replace').strip())
            for mode in ('stdin', 'askpass'):
                env = {**environment, 'SSH_ASKPASS_REQUIRE': 'never'}
                if mode == 'askpass':
                    env.update(SSH_ASKPASS=str(receiver), SSH_ASKPASS_REQUIRE='force',
                               CHIYO_QA_MODE='askpass', CHIYO_QA_EXPECTED=value)
                with lock:
                    before = len(attempts)
                timed_out = False
                try:
                    result = subprocess.run(command, input=(value + '\n').encode() if mode == 'stdin' else b'',
                                            env=env, capture_output=True, timeout=15,
                                            creationflags=subprocess.CREATE_NO_WINDOW)
                except subprocess.TimeoutExpired as error:
                    if mode != 'stdin':
                        raise
                    # A hidden native ssh can wait for its console password
                    # prompt while ignoring the pipe. Record the bounded
                    # negative observation; do not call it a returned refusal.
                    timed_out = True
                    result = subprocess.CompletedProcess(command, None, error.stdout or b'', error.stderr or b'')
                with lock:
                    accepted = any(attempts[before:])
                passed = (result.returncode == 0 and accepted) if mode == 'askpass' else (result.returncode != 0 and not accepted)
                assert value.encode() not in result.stdout + result.stderr
                record('ssh-' + mode, passed=passed, exitCode=result.returncode,
                       authenticated=accepted, timedOut=timed_out)
                if not passed:
                    raise AssertionError('Unexpected native SSH receiver behavior')
        finally:
            stopped.set()
            listener.close()
            thread.join(timeout=2)
            with lock:
                for transport in active:
                    transport.close()
            known.unlink()
    record('complete', passed=True, scope='OS transports only; no grant integration or private-ACL claim')


if __name__ == '__main__':
    main()
