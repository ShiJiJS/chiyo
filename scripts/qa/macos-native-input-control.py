#!/usr/bin/env python3
"""Launch a tiny sandbox AppKit input control; operate it only through CUA.

No application data, Keychain, global event monitoring, or input synthesis.
The supervisor preserves a live app on timeout; normal exit unregisters and
removes its owned generated bundle, not the development SDK or ordinary app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    source = ROOT / 'scripts/qa/macos-native-input-control.swift'
    shutil.copyfile(source, output / source.name)
    app = output / 'MacNativeInputControl.app'
    binary = app / 'Contents/MacOS/MacNativeInputControl'
    binary.parent.mkdir(parents=True)
    identity = 'org.shijijs.agent-info-manage.qa.native-input.' + uuid.uuid4().hex
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': identity, 'CFBundleName': 'MacNativeInputControl',
        'CFBundleDisplayName': 'Mac 原生输入独立对照',
        'CFBundleExecutable': binary.name, 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True,
    }))
    entitlements = output / 'entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
    facts = {'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
             'appPath': str(app), 'bundleIdentifier': identity, 'commands': [],
             'complete': False, 'keychainUsed': False, 'inputSynthesisUsed': False}

    def save():
        (output / 'result.json').write_text(json.dumps(facts, indent=2) + '\n')

    def run(label, command):
        with (output / (label + '.txt')).open('wb') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        facts['commands'].append({'label': label, 'command': command, 'exit': result.returncode})
        save()
        print(label, result.returncode, flush=True)
        if result.returncode:
            raise RuntimeError(label)

    process = None
    try:
        run('compile', ['/usr/bin/xcrun', 'swiftc', str(output / source.name),
                        '-framework', 'AppKit', '-o', str(binary)])
        run('sign', ['/usr/bin/codesign', '--force', '--sign', '-', '--entitlements',
                     str(entitlements), str(app)])
        run('verify', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        facts['binarySha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        env = {k: os.environ[k] for k in ['HOME', 'USER', 'LOGNAME', 'LANG'] if k in os.environ}
        env['PATH'] = '/usr/bin:/bin'
        facts['environmentKeys'] = sorted(env)
        with (output / 'app.jsonl').open('wb') as log:
            process = subprocess.Popen([str(binary)], cwd='/', env=env, stdout=log, stderr=subprocess.STDOUT)
            facts['pid'] = process.pid
            save()
            print('NATIVE_INPUT_CONTROL', process.pid, str(app), flush=True)
            code = process.wait(timeout=1200)
        facts['exit'] = code
        facts['complete'] = code == 0
        print('NATIVE_INPUT_EXIT', code, flush=True)
    finally:
        if process is None or process.poll() is not None:
            if app.exists():
                unregister = subprocess.run([
                    '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                    '-u', str(app)], capture_output=True, timeout=30)
                facts['unregisterExit'] = unregister.returncode
                shutil.rmtree(app)
            facts['generatedAppRemoved'] = True
        else:
            facts['liveProcessPreserved'] = process.pid
            facts['generatedAppRemoved'] = False
        save()


if __name__ == '__main__':
    main()
