#!/usr/bin/env python3
"""Staged CLI acceptance for an explicitly isolated synthetic normal-App profile.

Never launches/installs an App, creates a grant, changes permissions, reads a
password value, or retries a setter. Owner setup/approval and Archive Utility
submission remain separate visible UI steps. See native_background/README.md.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlparse
import uuid

ROOT = Path(__file__).resolve().parents[2]
PASSWORD = 'Synthetic-Zip-42!'
CONTENT = b'Synthetic native background product proof. No personal data.\n'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    temporary = path.with_name('.' + path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['prepare', 'request', 'run', 'status', 'business'])
    parser.add_argument('output', type=Path, help='Owned QA directory under this checkout build/')
    parser.add_argument('--cli', type=Path, help='Explicit same-source AOT chiyo under build/')
    parser.add_argument('--connection-directory', type=Path, help='Exact named synthetic profile directory')
    parser.add_argument('--app-id', default='com.apple.archiveutility', help='Actual synthetic archive receiver bundle ID (request only)')
    args = parser.parse_args()
    out = args.output.absolute()
    out.parent.resolve().relative_to((ROOT / 'build').resolve())
    if out.is_symlink():
        parser.error('QA directory cannot be redirected')
    if args.stage == 'prepare':
        out.mkdir(mode=0o700, exist_ok=False)
        nonce = uuid.uuid4().hex
        state = {'format': 1, 'kind': 'synthetic-native-product-qa', 'nonce': nonce,
                 'profileName': 'native-background-qa-' + nonce[:16],
                 'credentialName': 'Native product QA ' + nonce[:16],
                 'archiveName': 'NativeBackgroundProofProduct-' + nonce[:16] + '.zip',
                 'requestOperation': 'native-request-' + nonce,
                 'runOperation': 'native-run-' + nonce, 'runAttempted': False}
        source = out / 'input'
        source.mkdir(mode=0o700)
        (source / 'native-background-proof.txt').write_bytes(CONTENT)
        subprocess.run(['/usr/bin/zip', '-j', '-P', PASSWORD, str(out / state['archiveName']),
                        str(source / 'native-background-proof.txt')], check=True, stdout=subprocess.DEVNULL)
        write(out / 'qa.json', state)
        print(json.dumps({'prepared': True, 'profileName': state['profileName'],
                          'credentialName': state['credentialName'], 'archive': str(out / state['archiveName'])}))
        return
    if not out.is_dir() or out.stat().st_uid != os.getuid() or out.stat().st_mode & 0o077:
        parser.error('Expected private owned QA directory')
    lock = (out / '.flow.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    state = json.loads((out / 'qa.json').read_text())
    if state.get('kind') != 'synthetic-native-product-qa' or not re.fullmatch(r'[0-9a-f]{32}', state.get('nonce', '')):
        parser.error('Missing QA ownership marker')
    if args.stage == 'business':
        result = out / 'native-background-proof.txt'
        status = json.loads((out / 'status.json').read_text())['reply']['data']
        if status.get('executionState') != 'filled' or status.get('itemResults') != {'b1': 'sent'}:
            raise RuntimeError('No confirmed sent operation; business result cannot pass')
        exact = result.is_file() and result.read_bytes() == CONTENT
        write(out / 'business.json', {'passed': exact, 'sourceSHA256': hashlib.sha256(CONTENT).hexdigest(),
                                      'extractedSHA256': digest(result) if result.is_file() else None,
                                      'setterIsNotBusinessProof': True})
        if not exact:
            raise RuntimeError('Synthetic extracted content missing or different')
        print(json.dumps({'businessPassed': True}))
        return
    if args.stage == 'request':
        if not args.cli or not args.connection_directory:
            parser.error('request needs explicit CLI and synthetic connection directory')
        cli = args.cli.resolve(strict=True)
        cli.relative_to((ROOT / 'build').resolve())
        connection = args.connection_directory.resolve(strict=True)
        if connection.name != state['profileName'] or connection.parent.name != 'profiles':
            parser.error('Default or unrelated App profile refused')
        identity = json.loads((connection / 'local-library.json').read_text())
        active = connection / 'active.json'
        if active.exists():
            pointer = json.loads(active.read_text())
            if (set(pointer) != {'version', 'generation'} or pointer['version'] != 1 or
                    not re.fullmatch(r'[0-9a-f]{32}', pointer.get('generation', ''))):
                parser.error('Invalid synthetic profile generation')
            agent = connection / 'connections' / pointer['generation'] / 'agent/agent-connection.json'
        else:
            agent = connection / 'agent-connection.json'
        profile = json.loads(agent.read_text())
        address = urlparse(profile.get('address', ''))
        if (profile.get('role') != 'local-agent' or address.scheme != 'http' or address.hostname != '127.0.0.1'
                or profile.get('serverId') != 'local-' + identity.get('libraryId', '')):
            parser.error('Expected the named synthetic local library')
        if state.get('requestAttempted'):
            parser.error('Request already attempted; query its stable operation instead of creating another')
        state.update(cli=str(cli), cliSHA256=digest(cli), appId=args.app_id, connectionDirectory=str(connection),
                     agentConnectionFile=str(agent), libraryId=identity['libraryId'])
        write(out / 'qa.json', state)
    cli = Path(state['cli'])
    if digest(cli) != state['cliSHA256']:
        raise RuntimeError('CLI changed since request preparation')
    connection = Path(state['connectionDirectory'])
    env = {k: v for k, v in os.environ.items() if k not in
           ['CHIYO_CONTEXT', 'CHIYO_CHAT_ID', 'CODEX_THREAD_ID', 'CHIYO_CONNECTION_DIRECTORY']}
    env['CHIYO_CONNECTION_DIRECTORY'] = str(connection)
    context = out / 'chat/context.json'
    if context.exists():
        env['CHIYO_CONTEXT'] = str(context)

    def call(name, words):
        p = subprocess.run([str(cli), *words, '--json'], env=env, capture_output=True, timeout=30)
        if len(p.stdout) > 1024 * 1024 or PASSWORD.encode() in p.stdout:
            raise RuntimeError('Unexpected or secret-bearing public CLI output discarded')
        value = json.loads(p.stdout)
        write(out / (name + '.json'), {'exit': p.returncode, 'reply': value,
                                      'stderrDiscarded': bool(p.stderr)})
        return p.returncode, value

    def successful(name, words):
        code, value = call(name, words)
        if code != 0 or value.get('ok') is not True:
            raise RuntimeError('CLI phase did not succeed: ' + name + '; see private receipt')
        return value['data']

    if args.stage == 'request':
        (out / 'chat').mkdir(mode=0o700, exist_ok=False)
        successful('chat', ['chat', 'start', '--agent', 'Synthetic Native QA', '--id', 'native-qa-' + state['nonce'],
                            '--label', 'Synthetic native product acceptance', '--context-out', str(context),
                            '--connection', state['agentConnectionFile']])
        env['CHIYO_CONTEXT'] = str(context)
        doctor = successful('doctor', ['doctor'])
        if doctor.get('fill', {}).get('native', {}).get('available') is not True:
            raise RuntimeError('Product Launcher/native capability is not ready')
        catalog = successful('credentials', ['credentials', 'list'])['credentials']
        if (len(catalog) != 1 or catalog[0]['name'] != state['credentialName'] or
                catalog[0].get('form') != 'string' or catalog[0].get('availability') != 'available'):
            raise RuntimeError('Expected only the one synthetic public credential')
        targets = successful('targets', ['fill', 'targets', '--via', 'native', '--app', state['appId']])['targets']
        if len(targets) != 1 or state['archiveName'] not in (targets[0]['windowTitle'] + ' ' + targets[0]['fieldLabel']):
            raise RuntimeError('Expected only the live synthetic archive password prompt, identified by window/field description')
        state['requestAttempted'] = True
        write(out / 'qa.json', state)  # Freeze the stable submission ID before RPC.
        code, reply = call('request', ['fill', 'request', '--credential', catalog[0]['credentialId'],
                    '--version', str(catalog[0]['version']), '--via', 'native', '--target', targets[0]['targetId'],
                    '--purpose', 'Synthetic native product proof', '--operation', state['requestOperation']])
        requested = reply.get('data', {})
        if code not in [0, 6] or requested.get('status') != 'pending' or not isinstance(requested.get('requestId'), str):
            raise RuntimeError('Expected a newly pending request; query its stable operation before continuing')
        state['requestId'] = requested['requestId']
        write(out / 'qa.json', state)
        print(json.dumps({'requestId': state['requestId'], 'next': 'Approve only b1 in the visible normal App; approval does not run'}))
    elif args.stage == 'run':
        if state['runAttempted']:
            parser.error('Setter already attempted; use status, never rerun or change operation ID')
        approved = successful('approval', ['requests', 'wait', state['requestId'], '--timeout', '0'])
        if approved.get('status') != 'approved':
            raise RuntimeError('Expected an actually approved single-item request')
        state['runAttempted'] = True
        write(out / 'qa.json', state)  # Set before dispatch, including process/transport timeout.
        call('run', ['fill', 'run', '--request', state['requestId'], '--item', 'b1', '--operation', state['runOperation']])
        print(json.dumps({'attempted': True, 'next': 'Query status before any separate Archive Utility submission'}))
    elif args.stage == 'status':
        operation = state['runOperation'] if state['runAttempted'] else state['requestOperation']
        value = successful('status', ['operations', 'show', operation])
        print(json.dumps({'queried': True, 'operationId': operation,
                          'executionState': value.get('executionState'), 'itemResults': value.get('itemResults')}))


if __name__ == '__main__':
    main()
