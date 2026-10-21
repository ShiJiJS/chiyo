#!/usr/bin/env python3
"""Real pinned/upgraded GH versions and a controlled post-probe image change.

Only an isolated QA app is modified. Production inspectors, hosted execution,
worker, SQLCipher and actual owner approval UI are used. A QA timing barrier
holds the return of the real inspector; it never fabricates an identity.
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
import zipfile

ROOT = Path(__file__).resolve().parents[2]
ENTRY = 'apps/desktop/integration_test/macos_tool_version_manual.dart'
UPGRADE = {'version': '2.103.0', 'archive': 'gh_2.103.0_macOS_arm64.zip',
           'sha256': '54be566e9f614bea5de8021e95b9ad33dfee3b9d2ea120c9c294c00defaa5014',
           'url': 'https://github.com/cli/cli/releases/download/v2.103.0/gh_2.103.0_macOS_arm64.zip'}


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
    source, logs = output / 'source', output / 'logs'
    source.mkdir()
    logs.mkdir()
    owner = uuid.uuid4().hex
    identity = 'org.shijijs.agent-info-manage.qa.tool-version.' + owner
    state = {'scope': __doc__, 'complete': False, 'bundleIdentifier': identity,
             'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'upgradeFixture': UPGRADE, 'commands': [], 'cases': [], 'inputSourceHashes': {},
             'observedProcesses': [], 'processExits': []}
    app = root = mutable = None
    original = None
    processes = []
    controller = output / 'controller.json'
    seen = set()

    def save():
        (output / 'result.json').write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')

    def run(label, command, cwd=source, env=None):
        with (logs / (label + '.txt')).open('wb') as log:
            result = subprocess.run(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=900)
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
            time.sleep(0.1)

    def report(mode):
        try:
            return json.loads((root / (mode + '.json')).read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def control(action):
        path = root / 'qa-control.json'
        tmp = root / ('.qa-control-' + uuid.uuid4().hex)
        tmp.write_text(json.dumps({'owner': owner, 'action': action}))
        os.replace(tmp, path)

    def sample(mode):
        text = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,comm='], text=True)
        for line in text.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) != 3:
                continue
            pid, parent, path = parts
            if path.startswith(str(app) + '/'):
                key = (mode, int(pid), int(parent), path)
                if key not in seen:
                    seen.add(key)
                    state['observedProcesses'].append(dict(zip(['mode', 'pid', 'parentPid', 'executable'], key)))

    def restore():
        if original is None or mutable is None:
            return
        temp = mutable.with_name('gh-restore-' + uuid.uuid4().hex)
        shutil.copy2(original, temp)
        os.replace(temp, mutable)
        assert digest(mutable) == digest(original)

    try:
        archive = ROOT / '.downloads' / UPGRADE['archive']
        assert archive.is_file() and not archive.is_symlink() and digest(archive) == UPGRADE['sha256']
        names = subprocess.check_output(['git', 'ls-files', '-z', 'apps/desktop', 'packages', 'scripts', 'integrations', 'third_party'], cwd=ROOT).decode().split('\0')
        for name in sorted(set(filter(None, names)) | {ENTRY, 'scripts/qa/macos-tool-version-ui.py'}):
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
        run('build', [launcher, 'build', '--target=integration_test/macos_tool_version_manual.dart'])
        built = desktop / 'build/macos/Build/Products/Release/info_desktop.app'
        app = desktop / 'build/relocated/工具 版本测试/info_desktop.app'
        app.parent.mkdir(parents=True)
        shutil.move(built, app)
        qa_tools = app / 'Contents/Resources/QA'
        mutable = qa_tools / 'mutable/bin/gh'
        upgraded = qa_tools / 'upgraded/bin/gh'
        mutable.parent.mkdir(parents=True)
        upgraded.parent.mkdir(parents=True)
        pinned = app / 'Contents/Resources/ThirdParty/gh/bin/gh'
        shutil.copy2(pinned, mutable)
        with zipfile.ZipFile(archive) as contents:
            data = contents.read('gh_2.103.0_macOS_arm64/bin/gh')
            upgraded.write_bytes(data)
            (qa_tools / 'GH-UPGRADE-LICENSE').write_bytes(contents.read('gh_2.103.0_macOS_arm64/LICENSE'))
        upgraded.chmod(0o755)
        original = output / 'original-gh'
        shutil.copy2(mutable, original)
        state['toolFiles'] = {name: {'sha256': digest(path), 'bytes': path.stat().st_size,
                             'mtimeNs': path.stat().st_mtime_ns} for name, path in [('pinned', pinned), ('mutableBefore', mutable), ('upgraded', upgraded)]}
        state['qaExtraToolsOnly'] = True
        run('seal-qa-app', ['/usr/bin/codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements,requirements,flags,runtime', str(app)])
        run('signature-before', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        run('entitlements', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)])
        run('worker-entitlements', ['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app / 'Contents/MacOS/info-runtime-worker')])
        state['mainSha256'] = digest(app / 'Contents/MacOS/info_desktop')
        state['workerSha256'] = digest(app / 'Contents/MacOS/info-runtime-worker')
        reference_env = {'HOME': str(output / 'reference-home'), 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'}
        (output / 'reference-home').mkdir()
        run('reference-upgrade-version', [str(upgraded), '--version'], env=reference_env)
        assert (logs / 'reference-upgrade-version.txt').read_text().startswith('gh version 2.103.0 ')
        swapped = restored = False
        for mode in ['exercise', 'reopen']:
            environment = {k: os.environ[k] for k in ['HOME', 'USER', 'LOGNAME', 'LANG'] if k in os.environ}
            environment.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', MAC_TOOL_VERSION_MODE=mode,
                MAC_TOOL_VERSION_OWNER=owner, MAC_TOOL_VERSION_MUTABLE=str(mutable), MAC_TOOL_VERSION_UPGRADED=str(upgraded))
            if root is not None:
                environment['MAC_TOOL_VERSION_ROOT'] = str(root)
            logpath = logs / (mode + '.txt')
            with logpath.open('wb') as log:
                process = subprocess.Popen([str(app / 'Contents/MacOS/info_desktop')], cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)

            def locate():
                found = re.findall(r'TOOL_VERSION_ROOT=([^\r\n]+)', logpath.read_text(errors='replace'))
                if not found:
                    return None
                candidate = Path(found[-1])
                assert candidate.is_absolute() and not candidate.is_symlink() and candidate.name.startswith('aim-tool-version-')
                assert (candidate / '.qa-owner').read_text() == owner
                if root is not None:
                    assert candidate.resolve() == root
                return candidate.resolve()
            root = wait_for(locate, process)
            wait_for(lambda: report(mode), process)
            controller.write_text(json.dumps({'mode': mode, 'pid': process.pid, 'app': str(app), 'root': str(root)}))
            state['waitingForActualUI'] = mode
            save()
            print('TOOL_VERSION_UI_READY=' + mode, flush=True)
            deadline, last_sample, observed = time.monotonic() + 1500, 0.0, False
            while process.poll() is None:
                current = report(mode)
                if current and current.get('barrier') == 'replace-owned-tool-after-production-probe' and not swapped:
                    assert digest(mutable) == digest(original)
                    temp = mutable.with_name('gh-upgrade-' + uuid.uuid4().hex)
                    shutil.copy2(upgraded, temp)
                    os.replace(temp, mutable)
                    state['replacedToolSha256'] = digest(mutable)
                    assert digest(mutable) != digest(original)
                    control('replaced')
                    swapped = True
                    save()
                    print('TOOL_VERSION_REPLACED_AFTER_REAL_PROBE', flush=True)
                if current and current.get('barrier') == 'restore-supported-tool' and not restored:
                    restore()
                    run('signature-after-restore', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
                    control('restored')
                    restored = True
                    state['originalToolBytesModeMtimeRestored'] = mutable.stat().st_mtime_ns == original.stat().st_mtime_ns and mutable.stat().st_mode == original.stat().st_mode
                    save()
                    print('TOOL_VERSION_RESTORED_SUPPORTED_IMAGE', flush=True)
                if current and current.get('complete') and not observed:
                    observed = True
                    print('TOOL_VERSION_FLOW_PASSED=' + mode, flush=True)
                if time.monotonic() - last_sample > 0.2:
                    sample(mode)
                    last_sample = time.monotonic()
                if time.monotonic() > deadline:
                    raise TimeoutError('Actual UI deadline')
                time.sleep(0.1)
            state['processExits'].append({'mode': mode, 'pid': process.pid, 'exitCode': process.returncode})
            save()
            facts = report(mode)
            assert process.returncode == 0 and facts and facts.get('complete') and not facts.get('failed'), facts
            assert facts['libraryCloses'] == 1 and facts['flutterErrors'] == 0
            record = {'exitCode': process.returncode, **facts}
            (output / (mode + '.json')).write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
            state['cases'].append(record)
            controller.unlink()
            state.pop('waitingForActualUI', None)
            save()
            print('TOOL_VERSION_CASE_PASSED=' + mode, flush=True)
        assert swapped and restored and state['originalToolBytesModeMtimeRestored']
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
        restore()
        if root is not None and root.exists():
            assert not root.is_symlink() and (root / '.qa-owner').read_text() == owner
            for path in root.glob('*.json'):
                if path.name != 'qa-control.json':
                    shutil.copy2(path, output / ('last-' + path.name))
            shutil.rmtree(root)
        controller.unlink(missing_ok=True)
        if app is not None and app.exists():
            result = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)], capture_output=True, timeout=30)
            state['unregisterExitCode'] = result.returncode
        for tail in ['apps/desktop/build', 'apps/desktop/.dart_tool/flutter_build', 'apps/desktop/.dart_tool/hooks_runner']:
            path = source / tail
            if path.exists():
                assert path.resolve().is_relative_to(source) and not path.is_symlink()
                shutil.rmtree(path)
        if original is not None:
            original.unlink(missing_ok=True)
        shutil.rmtree(output / 'reference-home', ignore_errors=True)
        state['ownedFixturesAndGeneratedAppRemoved'] = (root is None or not root.exists()) and not (source / 'apps/desktop/build').exists()
        save()


if __name__ == '__main__':
    main()
