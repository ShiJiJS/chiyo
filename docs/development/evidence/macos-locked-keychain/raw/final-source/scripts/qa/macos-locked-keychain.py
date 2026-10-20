#!/usr/bin/env python3
"""Native signed sandbox test of an owned file Keychain; never locks the login keychain.

The only production-store copy changes are explicit read/add keychain targeting.
The probe owns a random in-memory password and an isolated temporary directory.
"""
import hashlib
import json
import plistlib
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    if sys.platform != 'darwin' or len(sys.argv) != 2:
        raise SystemExit('Usage: macos-locked-keychain.py NEW_OUTPUT_DIRECTORY')
    output = Path(sys.argv[1]).resolve()
    output.relative_to(ROOT / 'build/macos-adaptation')
    output.mkdir(parents=True, exist_ok=False)
    logs = output / 'logs'
    logs.mkdir()
    source = ROOT / 'apps/desktop/macos/Runner/DatabaseKeyStore.swift'
    original = source.read_text()
    read = '      request[kSecReturnData as String] = true'
    add = '      request[kSecValueData as String] = data'
    assert original.count(read) == 1 and original.count(add) == 1
    modified = original.replace(read, '      request[kSecMatchSearchList as String] = [qaKeychain!]\n' + read)
    modified = modified.replace(add, '      request[kSecUseKeychain as String] = qaKeychain!\n' + add)
    copied = output / 'DatabaseKeyStore.swift'
    copied.write_text(modified)
    probe = ROOT / 'scripts/qa/macos-locked-keychain-probe.swift'
    facts = {
        'complete': False,
        'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
        'probeSha256': hashlib.sha256(probe.read_bytes()).hexdigest(),
        'runnerSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'targetedStoreSha256': hashlib.sha256(copied.read_bytes()).hexdigest(),
        'steps': [],
        'scope': 'native signed sandbox, explicit private file-keychain queries; no Flutter/database or production-profile operations',
    }

    def run(label, args, timeout=60):
        started = time.monotonic()
        with (logs / (label + '.txt')).open('wb') as log:
            try:
                result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = 124
        facts['steps'].append({'label': label, 'exit': code,
                               'seconds': round(time.monotonic() - started, 3)})
        (output / 'result.json').write_text(json.dumps(facts, indent=2) + '\n')
        print(label, code, flush=True)
        if code:
            raise RuntimeError(label + ' failed; retained raw log; cleanup is not claimed')

    app = output / 'LockedKeychain.app'
    binary = app / 'Contents/MacOS/locked-keychain-probe'
    binary.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.shijijs.agent-info-manage.qa.lockedkeychain',
        'CFBundleExecutable': binary.name, 'CFBundleName': 'Mac Locked Keychain QA',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    }))
    run('compile', ['xcrun', 'swiftc', '-parse-as-library', str(copied), str(probe), '-o', str(binary)])
    run('sign', ['codesign', '--force', '--sign', '-', '--entitlements',
                 str(ROOT / 'apps/desktop/macos/Runner/Release.entitlements'), str(app)])
    run('verify-signature', ['codesign', '--verify', '--deep', '--strict', str(app)])
    run('probe', [str(binary)], 30)
    facts['probe'] = json.loads((logs / 'probe.txt').read_text())
    assert facts['probe']['complete']
    facts['complete'] = True
    (output / 'result.json').write_text(json.dumps(facts, indent=2) + '\n')


if __name__ == '__main__':
    main()
