#!/usr/bin/env python3
"""Build isolated Mac native-background checks. --platform opts into synthetic UI.

No installed App, user credential, system permission, Flutter build or public RPC
is changed. Runtime fixtures/caches are removed; receipts remain under build/.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'apps/desktop/macos/native_background'
FOCUS = ROOT / 'apps/desktop/macos/focused_input'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', action='store_true')
    parser.add_argument('--cache-only', action='store_true', help='Only the read-only replacement-window regression')
    args = parser.parse_args()
    output = ROOT / 'build/native-background-macos'
    if args.cache_only:
        args.platform = True
        output = output / 'cache-recheck'
    output.mkdir(parents=True, exist_ok=True)
    common = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-warnings-as-errors',
              '-target', 'arm64-apple-macos14.0']
    model = [FOCUS / 'FocusedFillContract.swift', SOURCE / 'NativeBackgroundTypes.swift', SOURCE / 'NativeBackgroundController.swift']
    system = model + [FOCUS / 'FocusProcessIdentity.swift', SOURCE / 'SystemNativeBackgroundEnvironment.swift', SOURCE / 'NativeBackgroundWire.swift', SOURCE / 'NativeBackgroundCompatibility.swift']
    report = {'platformRequested': args.platform, 'publicRPCEnabled': False,
              'formalSignedHelperTCCVerified': False, 'startedAt': time.time()}
    with tempfile.TemporaryDirectory(prefix='candidate-', dir=output) as work:
        work = Path(work)
        compile_args = common + ['-module-cache-path', str(work / 'modules')]
        def compile(sources, destination):
            subprocess.run(compile_args + [str(p) for p in sources] + ['-o', str(destination)], check=True)
        compile(model + [SOURCE / 'tests/ControllerChecks.swift'], work / 'controller')
        report['controller'] = json.loads(subprocess.check_output([work / 'controller'], text=True))
        subprocess.run(compile_args + ['-typecheck'] + [str(p) for p in system], check=True)
        framework = ROOT / '.tools/flutter/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64'
        if not framework.exists():
            framework = ROOT.parent.parent / '.tools/flutter/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64'
        owner = [FOCUS / n for n in ['FocusedFillContract.swift', 'FocusProcessIdentity.swift', 'FocusedFillXPC.swift']]
        owner += [SOURCE / n for n in ['NativeBackgroundXPC.swift', 'NativeBackgroundBridge.swift']]
        subprocess.run(compile_args + ['-typecheck', '-F', str(framework)] + list(map(str, owner)), check=True)
        report['ownerBridgeTypechecked'] = True
        if args.platform:
            compile([SOURCE / 'tests/NativeFixture.swift'], work / 'fixture')
            compile(system + [SOURCE / 'tests/PlatformChecks.swift'], work / 'platform')
            compile(model + [SOURCE / 'tests/DispatchObserver.swift'], work / 'observer')
            (work / 'fixture.log').touch()
            for prefix in ['target', 'alternate', 'cover']:
                contents = work / (prefix + '.app') / 'Contents'
                (contents / 'MacOS').mkdir(parents=True)
                shutil.copy(work / 'fixture', contents / 'MacOS/NativeFixture')
                (contents / 'Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleExecutable': 'NativeFixture', 'CFBundleIdentifier': 'local.chiyo.native-background.' + prefix,
                    'CFBundleName': 'Native Background Synthetic ' + prefix, 'CFBundlePackageType': 'APPL'}))
                subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', contents.parent], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            target = work / 'target.app/Contents/MacOS/NativeFixture'
            detail = subprocess.check_output(['codesign', '-dvvv', target], stderr=subprocess.STDOUT, text=True)
            cdhash = re.search(r'^CDHash=([0-9a-f]{40})$', detail, re.M).group(1)
            (work / 'config.json').write_text(json.dumps({'targetExecutable': str(target), 'sha256': digest(target),
                                                        'codeRequirement': 'cdhash H"' + cdhash + '"'}))
            (work / 'case.json').write_text(json.dumps({'expected': 'synthetic'}))
            with (work / 'fixture.log').open('ab') as log:
                cover = subprocess.Popen([work / 'cover.app/Contents/MacOS/NativeFixture', work, '--cover'], stdout=log, stderr=log)
                try:
                    for _ in range(200):
                        if (work / 'cover-state.json').exists(): break
                        time.sleep(.02)
                    result = subprocess.run([work / 'platform', work, *(['--cache-only'] if args.cache_only else [])], capture_output=True, text=True, timeout=300)
                    (output / 'platform-log.txt').write_text(result.stdout + result.stderr)
                    for name in ['calibration.json', 'platform-results.json', 'foreground-typing.json', 'wire-results.json', 'wire-before-cache.json', 'window-cache.json', 'stage.json', 'result.json']:
                        if (work / name).exists(): shutil.copy(work / name, output / name)
                    for observer in list(work.glob('observer-*.json')) + list(work.glob('ax-metadata-*.json')):
                        shutil.copy(observer, output / observer.name)
                    report['platformExit'] = result.returncode
                    report['platform'] = json.loads((work / 'result.json').read_text()) if (work / 'result.json').exists() else {'passed': False}
                finally:
                    # Exact synthetic children only. Never terminate by App name.
                    for prefix in ['target', 'cover']:
                        pid_file = work / (prefix + '-pid.json')
                        if pid_file.exists():
                            pid = str(json.loads(pid_file.read_text())['pid'])
                            command = subprocess.run(['ps', '-p', pid, '-o', 'command='], capture_output=True, text=True).stdout
                            if str(work) in command:
                                subprocess.run(['kill', '-TERM', pid], check=False)
                    cover.wait(timeout=5)
                    shutil.copy(work / 'fixture.log', output / 'fixture-log.txt')
    report['temporaryArtifactsRemoved'] = True
    inputs = list(SOURCE.rglob('*.swift')) + [Path(__file__).resolve()]
    report['sources'] = {str(p.relative_to(ROOT)): digest(p) for p in inputs}
    report['finishedAt'] = time.time()
    (output / 'checks.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'sources'}, indent=2))
    if args.platform and not report['platform'].get('passed'): raise SystemExit(1)

if __name__ == '__main__':
    main()
