#!/usr/bin/env python3
"""Persisted read/read-write directory scopes, real panels and hosted AWS workers.

Isolated bundle/profile and synthetic SQLCipher key; never asks for Keychain.
Production settings and native panels must be operated with computer use.
Credential approval uses the synthetic QA owner API, not a claimed UI approval.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
ENTRY = 'apps/desktop/integration_test/macos_directory_manual.dart'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    assert os.uname().sysname == 'Darwin'
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    source = output / 'source'
    logs = output / 'logs'
    source.mkdir()
    logs.mkdir()
    owner = uuid.uuid4().hex
    identity = 'org.shijijs.agent-info-manage.qa.directory.' + owner
    bookmarks = Path.home() / 'Library/Containers' / identity / 'Data/Library/Application Support/AgentInfoManage/tool-access/directories.json'
    state = {'complete': False, 'scope': __doc__, 'bundleIdentifier': identity,
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'commands': [], 'cases': [], 'inputSourceHashes': {}}
    processes = []
    app = receiver = root = None
    controller = output / 'controller.json'
    external = output / 'external'
    external.mkdir(mode=0o700)
    selected = [external / '读取 中文 空格', external / '读写 中文 空格']
    for path in selected:
        path.mkdir(mode=0o700)
        (path / '对象 名称.txt').write_text('fixture-object')

    def save():
        (output / 'result.json').write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')

    def run(label, command, cwd=source):
        with (logs / (label + '.txt')).open('wb') as log:
            result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        state['commands'].append({'label': label, 'exitCode': result.returncode, 'command': command})
        save()
        print(label, result.returncode, flush=True)
        assert result.returncode == 0, label

    def wait_for(check, process, timeout=120):
        deadline = time.monotonic() + timeout
        while True:
            value = check()
            if value:
                return value
            assert process.poll() is None, 'Process exited before expected evidence'
            if time.monotonic() > deadline:
                raise TimeoutError('Observation deadline')
            time.sleep(0.15)

    def report(mode):
        try:
            return json.loads((root / (mode + '.json')).read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    try:
        names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages', 'scripts', 'integrations', 'third_party'], cwd=ROOT).decode().split('\0')
        for name in sorted(set(filter(None, names)) | {ENTRY, 'scripts/qa/macos-directory-ui.py'}):
            path = ROOT / name
            assert path.is_file() and not path.is_symlink()
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            state['inputSourceHashes'][name] = digest(path)
        for name in ['.tools', '.downloads']:
            (source / name).symlink_to(ROOT / name, target_is_directory=True)
        (source / '.cache').mkdir()
        (source / '.cache/pub').symlink_to(ROOT / '.cache/pub', target_is_directory=True)
        config = source / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
        old = 'PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop'
        assert config.read_text().count(old) == 1
        config.write_text(config.read_text().replace(old, 'PRODUCT_BUNDLE_IDENTIFIER = ' + identity))
        state['qaBundleConfigSha256'] = digest(config)
        launcher = str(source / 'scripts/dev-macos.sh')
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile'], source / 'packages' / package)
        desktop = source / 'apps/desktop'
        run('pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile'], desktop)
        run('analyze', [launcher, 'flutter', 'analyze', '--no-pub', '--fatal-infos', '--fatal-warnings'], desktop)
        run('build', [launcher, 'build', '--target=integration_test/macos_directory_manual.dart'])
        original = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        app = desktop / 'build/relocated/目录 测试/info_desktop.app'
        app.parent.mkdir(parents=True)
        shutil.move(original, app)
        run('signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        run('entitlements', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])
        binary = app / 'Contents/MacOS/info_desktop'
        state['binarySha256'] = digest(binary)
        state['workerSha256'] = digest(app / 'Contents/MacOS/info-runtime-worker')
        receiver_root = output / 'receiver'
        with (logs / 'receiver.txt').open('wb') as log:
            receiver = subprocess.Popen([str(ROOT / '.tools/qa-python/bin/python'), str(source / 'scripts/qa/macos-aws-file-receiver.py'), str(receiver_root)], stdout=log, stderr=subprocess.STDOUT)
        wait_for(lambda: (receiver_root / 'fixture.json').exists(), receiver)
        port = json.loads((receiver_root / 'fixture.json').read_text())['port']
        payload_base64 = base64.b64encode((receiver_root / 'expected.bin').read_bytes()).decode()
        payload_sha = digest(receiver_root / 'expected.bin')
        state['expectedPayloadSha256'] = payload_sha
        last_hash = None
        for mode in ['choose', 'reopen', 'change', 'reopen-changed', 'remove', 'denied']:
            environment = {k: os.environ[k] for k in ['HOME', 'USER', 'LOGNAME', 'LANG'] if k in os.environ}
            environment.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',
                               MAC_DIRECTORY_MODE=mode, MAC_DIRECTORY_OWNER=owner,
                               MAC_DIRECTORY_READ=str(selected[0]), MAC_DIRECTORY_WRITE=str(selected[1]),
                               MAC_DIRECTORY_PORT=str(port), MAC_DIRECTORY_PAYLOAD_BASE64=payload_base64)
            if root is not None:
                environment['MAC_DIRECTORY_ROOT'] = str(root)
            logpath = logs / (mode + '.txt')
            with logpath.open('wb') as log:
                process = subprocess.Popen([str(binary)], cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)

            def locate():
                found = re.findall(r'DIRECTORY_ROOT=([^\r\n]+)', logpath.read_text(errors='replace'))
                if not found:
                    return None
                candidate = Path(found[-1])
                assert candidate.is_absolute() and not candidate.is_symlink() and candidate.name.startswith('aim-directory-')
                assert (candidate / '.qa-owner').read_text() == owner
                if root is not None:
                    assert candidate.resolve() == root
                return candidate.resolve()
            root = wait_for(locate, process)
            wait_for(lambda: report(mode), process)
            controller.write_text(json.dumps({'mode': mode, 'pid': process.pid, 'app': str(app), 'root': str(root),
                'readDirectory': str(selected[0]), 'writeDirectory': str(selected[1]), 'bookmarkFile': str(bookmarks)}))
            state['waitingForActualUI'] = mode
            save()
            print('DIRECTORY_UI_READY=' + mode, flush=True)
            observed = False
            deadline = time.monotonic() + 1500
            while process.poll() is None:
                current = report(mode)
                if current and current.get('complete') and not observed:
                    print('DIRECTORY_FLOW_PASSED=' + mode, flush=True)
                    observed = True
                if time.monotonic() > deadline:
                    raise TimeoutError('Actual UI quit deadline')
                time.sleep(0.15)
            facts = report(mode)
            assert process.returncode == 0 and facts and facts.get('complete') and not facts.get('failed'), facts
            assert facts['libraryCloses'] == 1 and facts['flutterErrors'] == 0
            for execution in facts.get('executions', []):
                if execution['exitCode'] == 0:
                    assert hashlib.sha256(base64.b64decode(execution['dataBase64'])).hexdigest() == payload_sha
            record = {'exitCode': process.returncode, **facts}
            (output / (mode + '.json')).write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
            state['cases'].append(record)
            assert bookmarks.is_file() and not bookmarks.is_symlink() and bookmarks.stat().st_mode & 0o777 == 0o600
            data = json.loads(bookmarks.read_text())
            # Never copy bookmark bytes into public evidence.
            metadata = {'version': data['version'], 'entries': [
                {k: row[k] for k in ['id', 'path', 'permission']} for row in data['entries']]}
            (output / (mode + '-archive-metadata.json')).write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
            current_hash = digest(bookmarks)
            if mode in ['reopen', 'reopen-changed', 'denied']:
                assert current_hash == last_hash, 'Read-only startup rewrote bookmark archive'
            last_hash = current_hash
            controller.unlink()
            state.pop('waitingForActualUI', None)
            save()
            print('DIRECTORY_CASE_PASSED=' + mode, flush=True)
        result = json.loads((receiver_root / 'receiver-result.json').read_text())
        assert result['valid'] == 4 and result['invalid'] == 0, result
        state['receiver'] = result
        state['complete'] = True
    except Exception as error:
        state['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
                state['forcedFailureCleanup'] = True
        if receiver is not None and receiver.poll() is None:
            receiver.terminate()
            receiver.wait(timeout=10)
            state['receiverExitCode'] = receiver.returncode
        if root is not None and root.exists():
            assert not root.is_symlink() and (root / '.qa-owner').read_text() == owner
            for path in root.glob('*.json'):
                shutil.copy2(path, output / ('last-' + path.name))
            shutil.rmtree(root)
        if bookmarks.exists():
            assert identity.startswith('org.shijijs.agent-info-manage.qa.directory.') and not bookmarks.is_symlink()
            bookmarks.unlink()
        controller.unlink(missing_ok=True)
        if app is not None and app.exists():
            result = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)], capture_output=True, timeout=30)
            state['unregisterExitCode'] = result.returncode
        removed = []
        for tail in ['apps/desktop/build', 'apps/desktop/.dart_tool/flutter_build', 'apps/desktop/.dart_tool/hooks_runner']:
            path = source / tail
            if path.exists():
                assert path.resolve().is_relative_to(source) and not path.is_symlink()
                shutil.rmtree(path)
                removed.append(tail)
        for path in selected:
            if path.exists():
                assert not path.is_symlink() and path.parent == external
                shutil.rmtree(path)
        if receiver is not None:
            (output / 'receiver/expected.bin').unlink(missing_ok=True)
        state['generatedArtifactsRemoved'] = removed
        state['ownedFixturesRemoved'] = all(not path.exists() for path in selected) and (root is None or not root.exists())
        save()


if __name__ == '__main__':
    main()
