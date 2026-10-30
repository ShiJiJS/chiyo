#!/usr/bin/env python3
"""Build one disposable, isolated native owner UI check; preserve the preview."""
import base64
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DESKTOP = ROOT / 'apps/desktop'
TARGET = 'integration_test/owner_workspace_native_test.dart'
IDENTITY = 'com.example.infoDesktop.zhiyuOwnerCheck'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    OUTPUT = args.output.resolve()
    OUTPUT.relative_to(ROOT / 'build/macos-adaptation')
    OUTPUT.mkdir(parents=True, exist_ok=False)
    products = OUTPUT / 'products'
    config = OUTPUT / 'OwnerCheck.xcconfig'
    config.write_text(f'PRODUCT_BUNDLE_IDENTIFIER = {IDENTITY}\n'
                      'AGENT_INFO_INTERFACE_PREVIEW = NO\n'
                      f'CONFIGURATION_BUILD_DIR = {products}\n'
                      f'DWARF_DSYM_FOLDER_PATH = {products}\n')
    preview = DESKTOP / 'build/macos/Build/Products/Debug/info_desktop.app'
    def preview_hash():
        binary = preview / 'Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin'
        return hashlib.sha256(binary.read_bytes()).hexdigest() if binary.exists() else None
    original = preview_hash()
    if original is None or preview.is_symlink():
        raise RuntimeError('Expected the fixed ordinary Debug preview')
    # Preserve exact bytes as well as using a separate Xcode build database.
    # A shared derived-data root can delete the previous target's App as stale.
    preserved = OUTPUT / 'preserved-preview'
    shutil.copytree(preview, preserved, symlinks=True)
    env = dict(os.environ, XCODE_XCCONFIG_FILE=str(config),
               FLUTTER_MACOS_ARM64_ONLY='true',
               ZHIYU_PROFILE_DRIVER_REPORT=str(OUTPUT / 'driver.json'),
               PUB_CACHE=str(ROOT / '.cache/pub'),
               DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    launcher = str(ROOT / 'scripts/dev-macos.sh')
    report = {'complete': False, 'previewKernelSha256': original}
    def run(args, name, timeout=600):
        print(f'{name}: started', flush=True)
        with (OUTPUT / name).open('w') as log:
            result = subprocess.run(args, cwd=DESKTOP, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        print(f'{name}: exit {result.returncode}', flush=True)
        result.check_returncode()
    try:
        run([launcher, 'flutter', 'build', 'macos', '--debug', '--config-only',
             '--no-pub', '--target', TARGET, '--dart-define=OWNER_NATIVE_SYNTHETIC=true',
             '--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false'], 'configure.log')
        run(['xcodebuild', '-workspace', 'macos/Runner.xcworkspace', '-scheme', 'Runner',
             '-configuration', 'Debug', '-derivedDataPath', str(OUTPUT / 'xcode'),
             '-destination', 'generic/platform=macOS',
             'OBJROOT=' + str(OUTPUT / 'xcode/Build/Intermediates.noindex'),
             'SYMROOT=' + str(products), 'ARCHS=arm64',
             'COMPILER_INDEX_STORE_ENABLE=NO', '-quiet'], 'build.log')
        app = products / 'info_desktop.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info['CFBundleIdentifier'] != IDENTITY or info.get('AgentInfoInterfacePreview') == 'YES':
            raise RuntimeError('Unexpected native test identity')
        signed = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)],
                                capture_output=True, check=True)
        if plistlib.loads(signed.stdout).get('com.apple.security.app-sandbox') is not True:
            raise RuntimeError('Native check must remain sandboxed')
        run(['codesign', '--verify', '--deep', '--strict', str(app)], 'signature.log')
        run([launcher, 'flutter', 'drive', '--debug', '-d', 'macos', '--no-pub',
             '--target', TARGET, '--driver', 'integration_test/profile_driver.dart',
             '--use-application-binary', str(app)], 'drive.log', 300)
        data = json.loads((OUTPUT / 'driver.json').read_text())
        if data.get('runtime', {}).get('platform') != 'macos' or len(data.get('checks', [])) != 6:
            raise RuntimeError('Missing native check evidence')
        (OUTPUT / 'saved-library.png').write_bytes(base64.b64decode(data.pop('imagePngBase64')))
        (OUTPUT / 'driver.json').write_text(json.dumps(data, indent=2))
        report['complete'] = True
    finally:
        if original != preview_hash():
            if preview.exists():
                shutil.rmtree(preview)
            preserved.rename(preview)
            report['previewRestoredFromPreservedBytes'] = True
        report['previewUnchanged'] = original == preview_hash()
        if preserved.exists():
            shutil.rmtree(preserved)
        # Only this invocation's output tree; no installed or pre-existing App.
        binary = str(products / 'info_desktop.app/Contents/MacOS/info_desktop')
        processes = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
        still_running = any(line.strip().split(None, 1)[-1] == binary
                            for line in processes.splitlines() if line.strip())
        report['processStillRunning'] = still_running
        if products.exists() and not still_running:
            shutil.rmtree(products)
        if (OUTPUT / 'xcode').exists() and not still_running:
            shutil.rmtree(OUTPUT / 'xcode')
        report['temporaryProductsRemoved'] = not products.exists()
        (OUTPUT / 'result.json').write_text(json.dumps(report, indent=2))
    if not report['previewUnchanged']:
        raise RuntimeError('Preview changed unexpectedly')
    if report['processStillRunning']:
        raise RuntimeError('Native check still running; retained its products')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
