#!/usr/bin/env python3
"""Verify actual HTTPS container recreation with disposable synthetic data."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shutil
import ssl
import subprocess
import tempfile
import time
import urllib.request
import uuid


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', default='chiyo-server-verification:a01')
    parser.add_argument('--upgrade-image', help='Also rehearse upgrade and restoration of a stopped pre-upgrade volume')
    parser.add_argument('--compiled', action='store_true',
                        help='Images use the compiled server entrypoint instead of the verification SDK stage')
    args = parser.parse_args()
    names = []
    copies = []
    with tempfile.TemporaryDirectory(prefix='chiyo-container-') as directory:
        root = Path(directory)
        private = root / 'secrets'
        if args.compiled:
            initialized = run('docker', 'run', '--rm', '--user', f'{os.getuid()}:{os.getgid()}',
                '--mount', f'type=bind,source={root},target=/fixture',
                args.image, 'init-secrets', '/fixture/secrets')
            assert json.loads(initialized) == {'state': 'initialized'}
            before_keys = {p.name: p.read_bytes() for p in private.iterdir()}
            duplicate = subprocess.run(['docker', 'run', '--rm', '--user', f'{os.getuid()}:{os.getgid()}',
                '--mount', f'type=bind,source={root},target=/fixture',
                args.image, 'init-secrets', '/fixture/secrets'], capture_output=True)
            assert duplicate.returncode != 0
            assert {p.name: p.read_bytes() for p in private.iterdir()} == before_keys
        else:
            private.mkdir(mode=0o700)
            for name in ['database.key', 'owner.token', 'server.id']:
                path = private / name
                with path.open('xb') as stream:
                    os.chmod(path, 0o600)
                    stream.write(secrets.token_bytes(32))
        token = base64.urlsafe_b64encode((private / 'owner.token').read_bytes()).decode().rstrip('=')
        def openssl(*params):
            run('openssl', *map(str, params))
        ca, ca_key = root / 'ca.pem', root / 'ca.key'
        cert, key, csr = root / 'server.pem', root / 'server.key', root / 'server.csr'
        openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-keyout', ca_key, '-out', ca, '-subj', '/CN=Chiyo container fixture CA',
                '-addext', 'basicConstraints=critical,CA:TRUE',
                '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
        openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
                '-out', csr, '-subj', '/CN=localhost')
        extensions = root / 'server.ext'
        extensions.write_text('basicConstraints=critical,CA:FALSE\n'
                              'keyUsage=critical,digitalSignature,keyEncipherment\n'
                              'extendedKeyUsage=serverAuth\n'
                              'subjectAltName=IP:127.0.0.1,DNS:localhost\n')
        openssl('x509', '-req', '-in', csr, '-CA', ca, '-CAkey', ca_key,
                '-CAcreateserial', '-days', '1', '-extfile', extensions, '-out', cert)
        os.chmod(key, 0o600)
        (root / 'server.json').write_text(json.dumps({
            'dataDirectory': 'data', 'secretsDirectory': 'secrets',
            'tlsCertificate': 'server.pem', 'tlsPrivateKey': 'server.key',
            'address': '0.0.0.0', 'port': 47126,
        }))
        context = ssl.create_default_context(cafile=str(ca))
        def call(port, method, path, body=None):
            request = urllib.request.Request(f'https://127.0.0.1:{port}{path}', method=method,
                headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
                data=None if body is None else json.dumps(body).encode())
            with urllib.request.urlopen(request, context=context, timeout=3) as response:
                return json.load(response)
        def start(image=None, fixture=None):
            fixture = root if fixture is None else fixture
            name = 'chiyo-fixture-' + uuid.uuid4().hex[:12]
            names.append(name)
            run('docker', 'run', '-d', '--name', name,
                *(['--user', f'{os.getuid()}:{os.getgid()}'] if args.compiled else []), '--mount',
                f'type=bind,source={fixture},target=/fixture', '-p', '127.0.0.1::47126',
                image or args.image,
                *([] if args.compiled else ['dart', 'run', 'bin/server.dart']),
                'serve', '/fixture/server.json')
            port = run('docker', 'port', name, '47126/tcp').rsplit(':', 1)[1]
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if run('docker', 'inspect', '--format', '{{.State.Running}}', name) != 'true':
                    raise RuntimeError('Synthetic service exited before readiness: ' + run('docker', 'logs', name))
                try:
                    return name, port, call(port, 'GET', '/v1/server')
                except (OSError, ValueError):
                    time.sleep(0.2)
            raise RuntimeError('Synthetic container did not become ready')
        try:
            first, port, identity = start()
            body = {'name': 'Container record', 'description': 'synthetic only',
                    'fields': [{'name': 'Address', 'description': '', 'text': 'container.synthetic.invalid'}]}
            receipt = call(port, 'POST', '/v1/owner/saves/container-save', body)
            run('docker', 'stop', '--time', '15', first)
            assert run('docker', 'inspect', '--format', '{{.State.ExitCode}}', first) == '0'
            run('docker', 'rm', first)
            # A rollback copy is coherent only while the service is stopped.
            # Keep it outside the mounted tree so copying cannot recurse.
            rollback = None
            if args.upgrade_image:
                rollback = Path(tempfile.mkdtemp(prefix='chiyo-stopped-rollback-'))
                copies.append(rollback)
                shutil.copytree(root, rollback, dirs_exist_ok=True)
            second, port, reopened_identity = start(args.upgrade_image)
            assert {k: identity[k] for k in ['protocolVersion', 'serverId']} == {
                k: reopened_identity[k] for k in ['protocolVersion', 'serverId']}
            assert call(port, 'GET', '/v1/owner/operations/container-save') == receipt
            assert call(port, 'POST', '/v1/owner/saves/container-save', body) == receipt
            items = call(port, 'GET', '/v1/owner/information')['items']
            assert len(items) == 1 and items[0]['fields'][0]['value'] == 'container.synthetic.invalid'
            if args.upgrade_image:
                assert run('docker', 'image', 'inspect', '--format', '{{.Id}}', args.image) != run(
                    'docker', 'image', 'inspect', '--format', '{{.Id}}', args.upgrade_image)
                run('docker', 'stop', '--time', '15', second)
                assert run('docker', 'inspect', '--format', '{{.State.ExitCode}}', second) == '0'
                run('docker', 'rm', second)
                # Simulate recovering both the persistent library and its
                # matching private keys into a new directory/container. This
                # remains a stopped upgrade rehearsal, not a real deployment.
                recovered = Path(tempfile.mkdtemp(prefix='chiyo-recovered-volume-'))
                copies.append(recovered)
                shutil.copytree(rollback, recovered, dirs_exist_ok=True)
                third, recovery_port, recovered_identity = start(args.upgrade_image, recovered)
                assert {k: recovered_identity[k] for k in ['protocolVersion', 'serverId']} == {
                    k: identity[k] for k in ['protocolVersion', 'serverId']}
                assert call(recovery_port, 'GET', '/v1/owner/operations/container-save') == receipt
                assert call(recovery_port, 'GET', '/v1/owner/information')['items'] == items
                for secret in ['database.key', 'owner.token', 'server.id']:
                    assert (recovered / 'secrets' / secret).read_bytes() == (rollback / 'secrets' / secret).read_bytes()
                run('docker', 'stop', '--time', '15', third)
                assert run('docker', 'inspect', '--format', '{{.State.ExitCode}}', third) == '0'
                run('docker', 'rm', third)
                # Return to the old image with the *unmodified old copy*,
                # never ask an old program to open an upgraded database.
                fourth, rollback_port, rollback_identity = start(args.image, rollback)
                assert {k: rollback_identity[k] for k in ['protocolVersion', 'serverId']} == {
                    k: identity[k] for k in ['protocolVersion', 'serverId']}
                assert call(rollback_port, 'GET', '/v1/owner/information')['items'] == items
                assert call(rollback_port, 'GET', '/v1/owner/operations/container-save') == receipt
                run('docker', 'stop', '--time', '15', fourth)
                assert run('docker', 'inspect', '--format', '{{.State.ExitCode}}', fourth) == '0'
                run('docker', 'rm', fourth)
            print(json.dumps({'containerRecreated': True, 'dataPreserved': True,
                'serverIdentityPreserved': True, 'retryDeduplicated': True,
                'tlsVerified': True, 'syntheticOnly': True,
                'compiledRuntime': args.compiled,
                'runtimeInitializationRefusesReplacement': args.compiled,
                'distinctImageUpgrade': bool(args.upgrade_image),
                'stoppedDataAndKeysRecovered': bool(args.upgrade_image),
                'preUpgradeCopyRollback': bool(args.upgrade_image)}))
        finally:
            for name in names:
                subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, check=False)
            for copy in copies:
                shutil.rmtree(copy)


if __name__ == '__main__':
    main()
