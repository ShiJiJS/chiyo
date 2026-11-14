#!/usr/bin/env python3
"""Staged public CLI proof for an isolated normal Windows App and 7-Zip.

Creates only synthetic files under this checkout's build/. Owner setup,
credential creation, approval and archive submission remain normal UI actions.
Never calls Owner APIs, reads password controls, changes permissions, installs,
or repeats a setter. All private association files belong to this QA profile.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlparse
import uuid

ROOT = Path(__file__).resolve().parents[2]
PASSWORD = 'Synthetic-Zip-42!'  # Public test material, never a real credential.
CONTENT = b'Synthetic Windows native product proof. No personal data.\n'
RECEIVER_SHA256 = '5eb5d21003927be4d53401b9b6bbe8a787caabb38eaafaf0d429a136d7031621'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def under(path, root):
    path = path.resolve()
    path.relative_to(root.resolve())
    return path


def write(path, value):
    temporary = path.with_name('.' + path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


@contextmanager
def exclusive(out):
    with (out / '.flow.lock').open('a+b') as lock:
        lock.seek(0)
        if not lock.read(1):
            lock.write(b'\0')
            lock.flush()
        lock.seek(0)
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        try:
            yield
        finally:
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


def prepare(out, receiver):
    under(out.parent, ROOT / 'build')
    if out.exists() or out.is_symlink():
        raise ValueError('QA output must be new')
    receiver = under(receiver, ROOT / 'build')
    if receiver.name.lower() != '7zg.exe' or digest(receiver) != RECEIVER_SHA256:
        raise ValueError('Expected the verified build-local official 7-Zip receiver')
    out.mkdir(exist_ok=False)
    (out / 'appdata').mkdir()
    (out / 'localappdata').mkdir()
    nonce = uuid.uuid4().hex
    (out / 'native-background-proof.txt').write_bytes(CONTENT)
    state = {
        'format': 1, 'kind': 'synthetic-windows-native-product-qa', 'nonce': nonce,
        'profileName': 'native-background-qa-' + nonce[:16],
        'credentialName': 'Native Windows QA ' + nonce[:16],
        'archiveName': 'NativeBackgroundProof-' + nonce[:16] + '.7z',
        'requestOperation': 'native-request-' + nonce,
        'runOperation': 'native-run-' + nonce, 'runAttempted': False,
        'receiver': str(receiver), 'receiverSHA256': RECEIVER_SHA256,
        'appData': str(out / 'appdata'), 'localAppData': str(out / 'localappdata'),
    }
    write(out / 'qa.json', state)
    return state


def claim_run(out, state):
    if state.get('runAttempted'):
        raise ValueError('Setter already attempted; use status, never run again')
    state['runAttempted'] = True
    write(out / 'qa.json', state)  # Written before process creation/RPC.


def candidate_files(root, source_commit):
    root = root.resolve(strict=True)
    if 'build' not in [part.lower() for part in root.parts] or not re.fullmatch(r'[0-9a-f]{40}', source_commit):
        raise ValueError('Expected an explicit build candidate and exact frozen source commit')
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8-sig'))
    if (manifest.get('format') != 2 or manifest.get('sourceCommit') != source_commit or
            manifest.get('sourceDirty') is not False or manifest.get('architecture') != 'windows-x64' or
            manifest.get('cliEntrypoint') != 'cli/chiyo.exe'):
        raise ValueError('Candidate source identity does not match the frozen commit')
    files = {entry['path']: entry for entry in manifest['files']}
    paths = {}
    for name in ['app/info_desktop.exe', 'cli/chiyo.exe', 'app/info-native-background-broker.exe']:
        path = under(root / name, root)
        entry = files[name]
        if path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
            raise ValueError('Required candidate payload differs from its manifest')
        paths[name] = path
    native = manifest['nativeBackgroundFill']
    helper_digest = digest(paths['app/info-native-background-broker.exe'])
    if (native.get('helperProtocol') != 1 or native.get('helper') != 'app/info-native-background-broker.exe' or
            native.get('sha256') != helper_digest or
            helper_digest.encode() not in paths['app/info_desktop.exe'].read_bytes()):
        raise ValueError('Candidate helper is not bound into its runner')
    return paths['app/info_desktop.exe'], paths['cli/chiyo.exe']


def safe_output(output):
    if len(output) > 1024 * 1024 or any(value in output for value in [
        PASSWORD.encode(), base64.b64encode(PASSWORD.encode()),
        b'"privateProof"', b'"sessionSecret"',
    ]):
        raise ValueError('Secret-bearing or oversized public output discarded')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=['prepare', 'request', 'run', 'status', 'business'])
    parser.add_argument('output', type=Path)
    parser.add_argument('--receiver', type=Path, help='Verified build-local 7zG.exe, prepare only')
    parser.add_argument('--candidate-root', type=Path, help='Delivery-owned extracted AgentInfoManage under build/')
    parser.add_argument('--source-commit', help='Exact frozen candidate commit; manifest is provenance, not runtime authority')
    parser.add_argument('--connection-directory', type=Path, help='Exact named synthetic profile')
    args = parser.parse_args(argv)
    out = args.output.absolute()
    under(out.parent, ROOT / 'build')
    if args.stage == 'prepare':
        if not args.receiver:
            parser.error('prepare requires the verified receiver')
        state = prepare(out, args.receiver)
        print(json.dumps({
            'prepared': True, 'profileName': state['profileName'],
            'credentialName': state['credentialName'],
            'archive': str(out / state['archiveName']),
            'input': str(out / 'native-background-proof.txt'),
            'receiver': state['receiver'],
            'appData': state['appData'], 'localAppData': state['localAppData'],
        }))
        return
    if out.is_symlink() or not out.is_dir():
        parser.error('Expected an owned QA output directory')
    with exclusive(out):
        state = json.loads((out / 'qa.json').read_text(encoding='utf-8'))
        if state.get('kind') != 'synthetic-windows-native-product-qa' or not re.fullmatch(r'[0-9a-f]{32}', state.get('nonce', '')):
            raise ValueError('Missing synthetic QA ownership marker')
        if args.stage == 'run' and state['runAttempted']:
            raise ValueError('Setter already attempted; use status, never run again')
        receiver = under(Path(state['receiver']), ROOT / 'build')
        if digest(receiver) != state['receiverSHA256']:
            raise ValueError('7-Zip receiver changed')
        if args.stage == 'request':
            if not args.candidate_root or not args.source_commit or not args.connection_directory:
                parser.error('request needs delivery candidate root, exact source commit and synthetic connection directory')
            app, cli = candidate_files(args.candidate_root, args.source_commit)
            connection = args.connection_directory.resolve(strict=True)
            expected = out / 'appdata/Chiyo/online/profiles' / state['profileName']
            if connection != expected.resolve(strict=True):
                raise ValueError('Default or unrelated profile/App refused')
            identity = json.loads((connection / 'local-library.json').read_text(encoding='utf-8'))
            profile = json.loads((connection / 'agent/agent-connection.json').read_text(encoding='utf-8'))
            address = urlparse(profile.get('address', ''))
            if (profile.get('role') != 'local-agent' or address.scheme != 'http' or
                    address.hostname != '127.0.0.1' or profile.get('serverId') != 'local-' + identity.get('libraryId', '')):
                raise ValueError('Expected the named synthetic local library')
            if state.get('requestAttempted'):
                raise ValueError('Request already attempted; query the stable operation')
            state.update(cli=str(cli), cliSHA256=digest(cli), app=str(app), appSHA256=digest(app),
                         connectionDirectory=str(connection), libraryId=identity['libraryId'],
                         candidateRoot=str(args.candidate_root.resolve()), sourceCommit=args.source_commit)
            write(out / 'qa.json', state)
        cli = Path(state['cli'])
        if digest(cli) != state['cliSHA256'] or digest(Path(state['app'])) != state['appSHA256']:
            raise ValueError('CLI or ordinary App changed since request preparation')
        connection = Path(state['connectionDirectory'])
        env = {key: value for key, value in os.environ.items() if key not in
               ['CHIYO_CONTEXT', 'CHIYO_CHAT_ID', 'CODEX_THREAD_ID', 'CHIYO_CONNECTION_DIRECTORY']}
        env['CHIYO_CONNECTION_DIRECTORY'] = str(connection)
        env['APPDATA'] = str(out / 'appdata')
        env['LOCALAPPDATA'] = str(out / 'localappdata')
        context = out / 'chat/context.json'
        if context.exists():
            env['CHIYO_CONTEXT'] = str(context)

        def call(name, words):
            result = subprocess.run([str(cli), *words, '--json'], env=env, capture_output=True, timeout=30)
            safe_output(result.stdout)
            safe_output(result.stderr)
            value = json.loads(result.stdout)
            write(out / (name + '.json'), {'exit': result.returncode, 'reply': value,
                                          'stderrDiscarded': bool(result.stderr)})
            return result.returncode, value

        def successful(name, words):
            code, value = call(name, words)
            if code != 0 or value.get('ok') is not True:
                raise ValueError('CLI phase did not succeed: ' + name)
            return value['data']

        if args.stage == 'request':
            (out / 'chat').mkdir(exist_ok=False)
            successful('chat', ['chat', 'start', '--agent', 'Synthetic Native Windows QA',
                '--id', 'native-windows-qa-' + state['nonce'], '--label', 'Synthetic native product proof',
                '--context-out', str(context), '--connection', str(connection / 'agent/agent-connection.json')])
            env['CHIYO_CONTEXT'] = str(context)
            doctor = successful('doctor', ['doctor'])
            if doctor.get('fill', {}).get('native', {}).get('available') is not True:
                raise ValueError('Ordinary App native capability is not ready')
            credentials = successful('credentials', ['credentials', 'list'])['credentials']
            if (len(credentials) != 1 or credentials[0]['name'] != state['credentialName'] or
                    credentials[0].get('form') != 'string' or credentials[0].get('availability') != 'available'):
                raise ValueError('Expected only the one synthetic public credential')
            targets = successful('targets', ['fill', 'targets', '--via', 'native', '--app', str(receiver)])['targets']
            targets.sort(key=lambda target: target['fieldLabel'])
            if (len(targets) != 2 or len({target['windowId'] for target in targets}) != 1 or
                    not targets[0]['fieldLabel'].startswith('[120]') or not targets[1]['fieldLabel'].startswith('[121]') or
                    any(target['controlKind'] != 'win32_password' or target['application']['sha256'] != RECEIVER_SHA256 for target in targets)):
                raise ValueError('Expected only the two verified live 7-Zip password controls')
            business = {'purpose': 'Synthetic Windows native product proof', 'items': [{
                'credentialId': credentials[0]['credentialId'], 'version': credentials[0]['version'],
                'destination': {'via': 'native', 'targetId': target['targetId']},
            } for target in targets]}
            write(out / 'fill-plan.json', business)
            state['requestAttempted'] = True
            write(out / 'qa.json', state)
            code, reply = call('request', ['fill', 'request', '--input', str(out / 'fill-plan.json'),
                                          '--operation', state['requestOperation']])
            requested = reply.get('data', {})
            if code not in [0, 6] or requested.get('status') != 'pending' or not isinstance(requested.get('requestId'), str):
                raise ValueError('Expected pending request; query stable operation before proceeding')
            state['requestId'] = requested['requestId']
            write(out / 'qa.json', state)
            print(json.dumps({'requestId': state['requestId'], 'next': 'Approve b1 and b2 in the normal App. Approval must not run.'}))
        elif args.stage == 'run':
            approved = successful('approval', ['requests', 'wait', state['requestId'], '--timeout', '0'])
            if approved.get('status') != 'approved':
                raise ValueError('Expected an actual owner-approved request')
            claim_run(out, state)
            call('run', ['fill', 'run', '--request', state['requestId'], '--item', 'b1', '--item', 'b2',
                         '--operation', state['runOperation']])
            print(json.dumps({'attempted': True, 'next': 'Query status; submit the archive separately after observation ends.'}))
        elif args.stage == 'status':
            operation = state['runOperation'] if state['runAttempted'] else state['requestOperation']
            result = successful('status', ['operations', 'show', operation])
            print(json.dumps({'queried': True, 'operationId': operation,
                              'executionState': result.get('executionState'), 'itemResults': result.get('itemResults')}))
        elif args.stage == 'business':
            status = json.loads((out / 'status.json').read_text(encoding='utf-8'))['reply']['data']
            if status.get('executionState') != 'filled' or status.get('itemResults') != {'b1': 'sent', 'b2': 'sent'}:
                raise ValueError('No confirmed two-item sent operation')
            archive = out / state['archiveName']
            seven = receiver.with_name('7z.exe')
            def test(password):
                result = subprocess.run([str(seven), 't', str(archive), '-sccUTF-8'],
                    input=(password + '\n').encode(), env=env, capture_output=True, timeout=30)
                safe_output(result.stdout)
                safe_output(result.stderr)
                return result.returncode
            correct, wrong = test(PASSWORD), test('Incorrect-Synthetic-Test-Password')
            listing = subprocess.run([str(seven), 'l', '-slt', str(archive)], env=env, capture_output=True, timeout=30)
            safe_output(listing.stdout)
            safe_output(listing.stderr)
            extracted = out / 'verified-content'
            extracted.mkdir(exist_ok=True)
            extraction = subprocess.run([str(seven), 'e', str(archive), 'native-background-proof.txt',
                '-o' + str(extracted), '-y', '-sccUTF-8'], input=(PASSWORD + '\n').encode(),
                env=env, capture_output=True, timeout=30)
            safe_output(extraction.stdout)
            safe_output(extraction.stderr)
            content = extracted / 'native-background-proof.txt'
            exact = extraction.returncode == 0 and content.is_file() and content.read_bytes() == CONTENT
            passed = (correct == 0 and wrong == 2 and b'Encrypted = +' in listing.stdout and
                      b'native-background-proof.txt' in listing.stdout and exact)
            write(out / 'business.json', {'passed': passed, 'correctPasswordExit': correct,
                'wrongPasswordExit': wrong, 'archiveSHA256': digest(archive),
                'syntheticSourceSHA256': hashlib.sha256(CONTENT).hexdigest(),
                'extractedSHA256': digest(content) if content.is_file() else None,
                'setterIsNotBusinessProof': True})
            if not passed:
                raise ValueError('Synthetic encrypted archive proof failed')
            print(json.dumps({'businessPassed': True}))


if __name__ == '__main__':
    main()
