#!/usr/bin/env python3
"""Read-only checks of a normal Release App's embedded native-fill helper.

Does not launch the App/helper, open a library, install, or request permission.
Build ordinary lib/main.dart with dev-macos.sh first. This is packaging evidence,
not proof that the Dart Launcher injected the driver or approved an operation.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('native_bundle', ROOT / 'scripts/bundle-macos-focused-helper.py')
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, required=True, help='New JSON under this checkout build/')
    args = parser.parse_args()
    output = args.output.absolute()
    output.parent.resolve().relative_to((ROOT / 'build').resolve())
    if output.exists() or output.is_symlink():
        parser.error('Output must be new')
    app = BUNDLE.app_path(args.app, readonly=True)
    receipt = BUNDLE.inspect(app)
    if not receipt or not receipt.get('capabilityEnabled'):
        raise RuntimeError('Embedded production helper missing')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    binaries = {
        'owner': app / 'Contents/MacOS/info_desktop',
        'worker': app / 'Contents/MacOS/info-runtime-worker',
        'helper': app / BUNDLE.HELPER / 'Contents/MacOS/AgentInfoFocusedFill',
        'dartAOT': app / 'Contents/Frameworks/App.framework/Versions/A/App',
    }
    identities = {}
    for name, binary in binaries.items():
        details = subprocess.check_output(['codesign', '-dvvv', str(binary)], stderr=subprocess.STDOUT, text=True)
        match = re.search(r'^CDHash=([0-9a-f]{40})$', details, re.M)
        if not match:
            raise RuntimeError('Native architecture signing identity unavailable')
        requirement = 'cdhash H"' + match.group(1) + '"'
        subprocess.run(['codesign', '--verify', '--strict', '-R', '=' + requirement, str(binary)], check=True)
        architecture = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
        if architecture != ['arm64']:
            raise RuntimeError('Unexpected architecture')
        identities[name] = {'path': str(binary.relative_to(app)), 'sha256': sha(binary),
                            'cdhash': match.group(1), 'architecture': architecture}
    owner_rights = BUNDLE.entitlements(app)
    worker_rights = BUNDLE.entitlements(binaries['worker'])
    helper_rights = BUNDLE.entitlements(app / BUNDLE.HELPER)
    if not owner_rights.get('com.apple.security.app-sandbox') or not worker_rights.get('com.apple.security.inherit') or helper_rights:
        raise RuntimeError('Owner/worker/helper entitlement separation changed')
    forbidden = re.compile(r'(NativeFixture|NativeWorkCover|ControllerChecks|PlatformChecks|DispatchObserver|SyntheticSecureTarget|native_background/tests|preview_main\.dart|Probe\.swift)', re.I)
    unexpected = [str(p.relative_to(app)) for p in app.rglob('*') if forbidden.search(str(p.relative_to(app)))]
    if unexpected:
        raise RuntimeError('QA artifacts present in product')
    inputs = receipt['helper']['sourceInputs']
    needed = ['NativeBackgroundCompatibility.swift', 'NativeBackgroundWire.swift', 'SystemNativeBackgroundEnvironment.swift']
    if any(not any(path.endswith('/' + name) for path in inputs) for name in needed):
        raise RuntimeError('Helper receipt lacks native implementation')
    current = all((ROOT / name).is_file() and sha(ROOT / name) == digest for name, digest in inputs.items())
    if not current:
        raise RuntimeError('Product helper sources differ from checkout')
    generated = ROOT / 'apps/desktop/macos/Flutter/ephemeral/Flutter-Generated.xcconfig'
    target = re.search(r'^FLUTTER_TARGET=(.+)$', generated.read_text(), re.M)
    if not target or target.group(1).strip() != 'lib/main.dart':
        raise RuntimeError('Expected ordinary main.dart build metadata')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    report = {'format': 1, 'kind': 'ordinary-macos-product-native-package', 'passed': True,
              'app': str(app), 'target': 'lib/main.dart', 'sourceCommit': receipt['helper']['sourceCommit'],
              'helperSourceHashesCurrent': current, 'version': info['CFBundleShortVersionString'],
              'build': info['CFBundleVersion'], 'signing': 'local-ad-hoc', 'identities': identities,
              'ownerEntitlements': owner_rights, 'workerEntitlements': worker_rights,
              'helperEntitlements': helper_rights, 'fixtureFiles': unexpected,
              'deepStrictSignatureVerified': True, 'exactCDHashRequirementsVerified': True,
              'appExecuted': False, 'helperExecuted': False, 'installed': False,
              'launcherInjectionVerified': False, 'productEndToEndVerified': False,
              'distributionSignatureVerified': False, 'productHelperTCCVerified': False}
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': True, 'sourceCommit': report['sourceCommit'], 'output': str(output)}))


if __name__ == '__main__':
    main()
