#!/usr/bin/env python3
"""Actual external-tool panels, sandbox workers and bookmark process restarts.

Only synthetic credentials/libraries. GH is an invalid-token HTTP401 check;
AWS authenticates against a separate loopback SigV4 receiver. No user auth is
read or inherited. Generated app/caches, scopes and owned fixtures are cleaned.
"""
import argparse
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
ENTRY = 'apps/desktop/integration_test/macos_tools_manual.dart'
GH = ROOT / '.tools/gh-2.102.0/gh_2.102.0_macOS_arm64/bin/gh'
AWS = ROOT / '.tools/aws-cli-2.38.1-package/aws-cli.pkg/Payload/aws-cli/aws'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--bundled', action='store_true',
                        help='Verify production assembled tools inside the signed app')
    args = parser.parse_args()
    if os.uname().sysname != 'Darwin':
        parser.error('macOS required')
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    source, logs = output / 'source', output / 'logs'
    source.mkdir()
    logs.mkdir()
    owner = uuid.uuid4().hex
    identity = 'org.shijijs.agent-info-manage.qa.tools.' + uuid.uuid4().hex
    state = {'complete': False, 'scope': __doc__, 'commands': [], 'cases': [],
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'bundleIdentifier': identity,
             'tools': [{'path': str(p), 'sha256': digest(p)} for p in [GH, AWS]]}
    app, receiver = None, None
    processes, roots = [], set()
    controller = output / 'controller.json'
    bookmarks = Path.home() / 'Library/Containers' / identity / 'Data/Library/Application Support/AgentInfoManage/tool-access/directories.json'

    def save():
        (output / 'result.json').write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')

    def run(label, command, cwd=source):
        with (logs / (label + '.txt')).open('wb') as log:
            result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        state['commands'].append({'label': label, 'exitCode': result.returncode, 'command': command})
        save()
        print(label, result.returncode, flush=True)
        if result.returncode:
            raise RuntimeError(label + ' failed')

    def wait_for(check, process, timeout=60):
        deadline = time.monotonic() + timeout
        while True:
            value = check()
            if value:
                return value
            if process.poll() is not None:
                raise RuntimeError('Process exited before expected evidence')
            if time.monotonic() > deadline:
                raise TimeoutError('Observation deadline')
            time.sleep(0.1)

    def read_report(root, mode):
        try:
            return json.loads((root / (mode + '-result.json')).read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    try:
        names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages', 'scripts', 'integrations', 'third_party'], cwd=ROOT).decode().split('\0')
        state['inputSourceHashes'] = {}
        extra = {ENTRY, 'scripts/qa/macos-tools-ui.py', 'scripts/qa/macos-aws-receiver.py'}
        for name in sorted(set(filter(None, names)) | extra):
            path = ROOT / name
            assert path.is_file() and not path.is_symlink()
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            state['inputSourceHashes'][name] = digest(path)
        (source / '.tools').symlink_to(ROOT / '.tools', target_is_directory=True)
        (source / '.downloads').symlink_to(ROOT / '.downloads', target_is_directory=True)
        (source / '.cache').mkdir()
        (source / '.cache/pub').symlink_to(ROOT / '.cache/pub', target_is_directory=True)
        config = source / 'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
        original = 'PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop'
        assert config.read_text().count(original) == 1
        config.write_text(config.read_text().replace(original, 'PRODUCT_BUNDLE_IDENTIFIER = ' + identity))
        state['copyModifications'] = {str(config.relative_to(source)): digest(config)}
        save()
        launcher = str(source / 'scripts/dev-macos.sh')
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile'], source / 'packages' / package)
        desktop = source / 'apps/desktop'
        run('pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile'], desktop)
        run('analyze', [launcher, 'flutter', 'analyze', '--no-pub', '--fatal-infos', '--fatal-warnings'], desktop)
        run('build-release', [launcher, 'build', '--target=integration_test/macos_tools_manual.dart'])
        app = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        if args.bundled:
            moved = desktop / 'build/relocated/移动 中文 空格/info_desktop.app'
            moved.parent.mkdir(parents=True)
            shutil.move(app, moved)
            app = moved
            state['productionAppMovedBeforeLaunch'] = True
        selected_gh, selected_aws = GH, AWS
        if args.bundled:
            tools = app / 'Contents/Resources/ThirdParty'
            selected_gh, selected_aws = tools / 'gh/bin/gh', tools / 'aws-cli/aws'
            assert digest(selected_gh) == digest(GH) and digest(selected_aws) == digest(AWS)
            state['productionBundledTools'] = {'gh': str(selected_gh), 'aws': str(selected_aws),
                                      'toolExecutableBytesUnchanged': True,
                                      'manifestSha256': digest(tools / 'manifest.json'),
                                      'qaToolsCopiedAfterBuild': False}
        run('signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        run('entitlements', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])
        binary = app / 'Contents/MacOS/info_desktop'
        state['binarySha256'] = digest(binary)
        receiver_root = output / 'receiver'
        with (logs / 'receiver.txt').open('wb') as log:
            receiver = subprocess.Popen([str(ROOT / '.tools/qa-python/bin/python'), str(source / 'scripts/qa/macos-aws-receiver.py'), str(receiver_root)], stdout=log, stderr=subprocess.STDOUT)
        wait_for(lambda: (receiver_root / 'fixture.json').exists(), receiver)
        port = json.loads((receiver_root / 'fixture.json').read_text())['port']
        root = None
        chosen_bookmark_hash = None
        for mode in (['bundled'] if args.bundled else ['choose', 'reopen', 'remove', 'denied']):
            environment = os.environ.copy()
            environment.update(MAC_TOOLS_MODE=mode, MAC_TOOLS_OWNER=owner, MAC_TOOLS_GH=str(selected_gh), MAC_TOOLS_AWS=str(selected_aws), MAC_TOOLS_RECEIVER_PORT=str(port))
            environment.pop('MAC_TOOLS_ROOT', None)
            if root is not None:
                environment['MAC_TOOLS_ROOT'] = str(root)
            path = logs / (mode + '.txt')
            with path.open('wb') as log:
                process = subprocess.Popen([str(binary)], cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)

            def locate():
                found = re.findall(r'MAC_TOOLS_ROOT=([^\r\n]+)', path.read_text(errors='replace'))
                if not found:
                    return None
                candidate = Path(found[-1])
                assert candidate.is_absolute() and not candidate.is_symlink() and candidate.name.startswith('aim-mac-tools-')
                assert (candidate / '.qa-owner').read_text() == owner
                if root is not None:
                    assert candidate.resolve() == root
                return candidate.resolve()
            root = wait_for(locate, process)
            roots.add(root)
            ready = wait_for(lambda: read_report(root, mode), process)
            if mode in ('choose', 'remove', 'bundled'):
                fd = os.open(controller, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(fd, 'w') as stream:
                    json.dump({'owner': owner, 'root': str(root), 'app': str(app), 'pid': process.pid,
                               'case': mode, 'bookmarkFile': str(bookmarks),
                               'ghDirectory': str(GH.parent.parent), 'awsDirectory': str(AWS.parent)}, stream)
                state['waitingForActualUI'] = mode
                save()
                print('MAC_TOOLS_UI_READY=' + mode, flush=True)
            deadline = time.monotonic() + 1800
            observed = False
            while process.poll() is None:
                current = read_report(root, mode)
                if current and current.get('complete') and not observed:
                    print('MAC_TOOLS_FLOW_PASSED=' + mode, flush=True)
                    observed = True
                if time.monotonic() > deadline:
                    raise TimeoutError('Actual tool workflow deadline')
                time.sleep(0.1)
            facts = read_report(root, mode)
            assert process.returncode == 0 and facts and facts.get('complete') and not facts.get('failed')
            assert facts.get('nativeTerminationRequested') and facts['libraryCloses'] == 1 and facts['flutterErrors'] == 0
            record = {'exitCode': process.returncode, **facts}
            (output / (mode + '.json')).write_text(json.dumps(record, indent=2) + '\n')
            state['cases'].append(record)
            if mode in ('choose', 'bundled'):
                receiver_result = json.loads((receiver_root / 'receiver-result.json').read_text())
                assert receiver_result['valid'] == 3 and receiver_result['invalid'] == 1
            if mode == 'choose':
                assert bookmarks.is_file() and not bookmarks.is_symlink()
                assert bookmarks.stat().st_mode & 0o777 == 0o600
                chosen_bookmark_hash = digest(bookmarks)
                state['savedBookmarkFileMode'] = '0600'
                state['savedBookmarkFileSha256'] = chosen_bookmark_hash
            elif mode == 'reopen':
                assert digest(bookmarks) == chosen_bookmark_hash
                state['reopenPreservedBookmarkBytes'] = True
            controller.unlink(missing_ok=True)
            state.pop('waitingForActualUI', None)
            save()
            print('MAC_TOOLS_CASE_PASSED=' + mode, flush=True)
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
        if receiver is not None:
            if receiver.poll() is None:
                receiver.terminate()
                receiver.wait(timeout=10)
            state['receiverExitCode'] = receiver.returncode
        for root in roots:
            if root.exists():
                assert not root.is_symlink() and (root / '.qa-owner').read_text() == owner
                # Only safe result JSON is copied; private associations stay local.
                for path in root.glob('*-result.json'):
                    shutil.copyfile(path, output / ('last-' + path.name))
                shutil.rmtree(root)
        state['ownedFixturesRemoved'] = all(not root.exists() for root in roots)
        controller.unlink(missing_ok=True)
        if bookmarks.exists():
            assert identity.startswith('org.shijijs.agent-info-manage.qa.tools.') and not bookmarks.is_symlink()
            bookmarks.unlink()
            state['ownedBookmarkFileRemoved'] = True
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
        state['generatedArtifactsRemoved'] = removed
        save()
    print(json.dumps({'complete': state['complete'], 'cases': len(state['cases'])}), flush=True)


if __name__ == '__main__':
    main()
