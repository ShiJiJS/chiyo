"""Windows controller for the disposable common SSH/sudo fixture.

Build scripts/qa/ssh-session-fixture first. Host private keys remain inside a
container tmpfs (DrvFS cannot preserve their Unix permissions). Native Windows
ssh-keygen creates the synthetic client key; only the public host key is exported.
Creating directory/stop ends the owned container and WSL keepalive normally.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--image', required=True)
    parser.add_argument('--distribution', default='Ubuntu-24.04')
    args = parser.parse_args()
    root = args.directory.resolve()
    root.mkdir(exist_ok=False)
    label = f'chiyo-ssh-session-windows-{time.time_ns()}'
    command = ['wsl.exe', '-d', args.distribution, '--exec', 'docker']

    def docker(*argv, input=None):
        result = subprocess.run(command + list(argv), capture_output=True,
                                timeout=40, check=True, input=input)
        return result.stdout

    hold = subprocess.Popen(['wsl.exe', '-d', args.distribution, '--exec',
                             '/usr/bin/python3', '-c',
                             'import sys;sys.stdin.buffer.read()'],
                            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    container = None
    try:
        container = docker('run', '--rm', '-d', '--label', f'chiyo.task={label}',
                           '-p', '127.0.0.1::2222', '--tmpfs',
                           '/output:rw,noexec,nosuid,size=1m,mode=0755',
                           args.image).decode().strip()
        for _ in range(100):
            try:
                if docker('exec', container, 'test', '-f', '/output/ready') == b'':
                    break
            except subprocess.CalledProcessError:
                time.sleep(0.1)
        else:
            raise RuntimeError('fixture readiness failed')
        binding = docker('port', container, '2222/tcp').decode().strip()
        if not binding.startswith('127.0.0.1:') or '\n' in binding:
            raise RuntimeError('fixture must bind loopback only')
        port = int(binding.split(':')[-1])
        # Native ssh-keygen sets the correct owner-only Windows key ACL. Never
        # copy a private key out of a Linux bind mount with inherited NTFS ACLs.
        keygen = Path(os.environ['SystemRoot']) / 'System32/OpenSSH/ssh-keygen.exe'
        subprocess.run([str(keygen), '-q', '-t', 'ed25519', '-N', '',
                        '-f', str(root / 'client')], check=True)
        docker('exec', '-i', container, '/bin/sh', '-c', 'cat > /output/client.pub',
               input=(root / 'client.pub').read_bytes())
        host = docker('exec', container, 'cat', '/output/host.pub').decode().strip()
        (root / 'host.pub').write_text(host + '\n', encoding='ascii')
        (root / 'known_hosts').write_text(f'[127.0.0.1]:{port} {host}\n', encoding='ascii')
        facts = {'port': port, 'container': container, 'loopback': True}
        (root / 'facts.json').write_text(json.dumps(facts))
        print(json.dumps(facts), flush=True)
        while not (root / 'stop').exists():
            if hold.poll() is not None:
                raise RuntimeError('fixture runtime ended')
            time.sleep(0.1)
    finally:
        try:
            if container:
                actual = docker('inspect', container, '--format', '{{index .Config.Labels "chiyo.task"}}').decode().strip()
                if actual != label:
                    raise RuntimeError('container ownership differs; retained')
                docker('stop', '-t', '2', container)
        finally:
            hold.stdin.close()
            hold.wait(timeout=15)


if __name__ == '__main__':
    main()
