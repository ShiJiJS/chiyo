#!/usr/bin/env python3
"""Observe self-signed cross-version Keychain access without prompting or changing production trust.

Diagnostic completion does not mean upgraded key access succeeded. Inspect
crossVersionKeyAccessPreserved and the actual status/partition metadata.
Temporary signing identities are imported only into an owned file keychain.
"""
from pathlib import Path
import os, subprocess, json, secrets, uuid, hashlib, plistlib, time, shutil, sys, re

def main():
    root = Path(__file__).resolve().parents[2]
    if sys.platform != 'darwin' or len(sys.argv) != 2:
        raise SystemExit('Usage on macOS: macos-stable-signing.py NEW_OUTPUT_DIRECTORY')
    out = Path(sys.argv[1]).resolve()
    out.relative_to(root / 'build/macos-adaptation')
    if out.exists() or out.is_symlink():
        raise SystemExit('Output must be new')
    os.umask(0o077)
    out.mkdir(parents=True)
    private = out / ('private-' + uuid.uuid4().hex)
    private.mkdir(mode=0o700)
    owner = secrets.token_hex(16)
    (private / '.qa-owner').write_text(owner)
    password = secrets.token_hex(32)
    service = 'org.shijijs.agent-info-manage.qa.' + str(uuid.uuid4())
    facts = {'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(), 'complete': False, 'scope': 'ephemeral self-signed identities in owned file keychain; actual production DatabaseKeyStore in native signed sandbox Apps; only UUID synthetic Keychain service; no production key/database, no trust-settings change', 'steps': [], 'service': service}
    beforeList = subprocess.check_output(['security', 'list-keychains', '-d', 'user'])
    beforeDefault = subprocess.check_output(['security', 'default-keychain', '-d', 'user'])

    def sha(b):
        return hashlib.sha256(b).hexdigest()
    facts['keychainContextBefore'] = {'searchListHash': sha(beforeList), 'defaultHash': sha(beforeDefault)}
    facts['sourceInputs'] = [{'path': str(path.relative_to(root)), 'sha256': sha(path.read_bytes())} for path in [Path(__file__).resolve(), root / 'scripts/qa/macos-signing-fixture.swift', root / 'scripts/qa/macos-stable-signing-probe.swift', root / 'apps/desktop/macos/Runner/DatabaseKeyStore.swift', root / 'apps/desktop/macos/Runner/Release.entitlements']]

    def save():
        (out / 'result.json').write_text(json.dumps(facts, indent=2) + '\n')

    def run(label, args, *, stdin=None, required=True, timeout=30, public=True, pass_fds=()):
        started = time.monotonic()
        try:
            p = subprocess.run(args, input=stdin, capture_output=True, timeout=timeout, cwd=root, pass_fds=pass_fds)
            code = p.returncode
        except subprocess.TimeoutExpired as e:
            code = 124
            p = subprocess.CompletedProcess(args, code, e.stdout or b'', e.stderr or b'')
        except OSError as e:
            code = 127
            p = subprocess.CompletedProcess(args, code, b'', str(e).encode())
        record = {'label': label, 'exit': code, 'elapsedSeconds': round(time.monotonic() - started, 3)}
        if public:
            (out / (label + '.stdout.txt')).write_bytes(p.stdout)
            (out / (label + '.stderr.txt')).write_bytes(p.stderr)
        facts['steps'].append(record)
        save()
        print(label, code, flush=True)
        if required and code:
            raise RuntimeError(label + ' failed; see owned result')
        return p
    helper = str(out / 'signer-fixture')

    def fixture(action):
        return json.dumps({'action': action, 'root': str(private), 'owner': owner, 'password': password}).encode()
    apps = {}
    createdApps = []
    keysCreated = False
    try:
        run('compile-signer-fixture', ['xcrun', 'swiftc', '-parse-as-library', str(root / 'scripts/qa/macos-signing-fixture.swift'), '-o', helper])
        for label in ['A', 'Other']:
            config = private / (label + '.cnf')
            config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=codesign\n[dn]\nCN=AgentInfo Synthetic Signing ' + label + ' ' + uuid.uuid4().hex[:16] + '\n[codesign]\nkeyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=critical,codeSigning\nbasicConstraints=critical,CA:true,pathlen:0\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n')
            key = private / (label + '.pem')
            cert = private / (label + '.crt')
            p12 = private / (label + '.p12')
            run('generate-key-' + label, ['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:3072', '-aes-256-cbc', '-pass', 'stdin', '-out', str(key)], stdin=(password + '\n').encode(), public=False)
            run('generate-certificate-' + label, ['openssl', 'req', '-new', '-x509', '-sha256', '-days', '2', '-key', str(key), '-passin', 'stdin', '-config', str(config), '-out', str(cert)], stdin=(password + '\n').encode(), public=False)
            (readIn, writeIn) = os.pipe()
            (readOut, writeOut) = os.pipe()
            os.write(writeIn, (password + '\n').encode())
            os.close(writeIn)
            os.write(writeOut, (password + '\n').encode())
            os.close(writeOut)
            try:
                run('export-synthetic-identity-' + label, ['openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(cert), '-out', str(p12), '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1', '-passin', 'fd:' + str(readIn), '-passout', 'fd:' + str(readOut)], pass_fds=(readIn, readOut), public=False)
            finally:
                os.close(readIn)
                os.close(readOut)
            fingerprint = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-noout', '-fingerprint', '-sha1'], text=True).strip().split('=')[1].replace(':', '')
            facts['certificate' + label] = {'sha1': fingerprint, 'pemSha256': sha(cert.read_bytes()), 'validDays': 2, 'syntheticOnly': True}
            key.unlink()
        run('prepare-private-signer', [helper], stdin=fixture('prepare'))
        signingKeychain = private / 'signer.keychain'
        probe = root / 'scripts/qa/macos-stable-signing-probe.swift'
        identity = 'org.shijijs.agent-info-manage.qa.stablesigning'
        for label in ['A', 'B', 'C', 'D']:
            app = out / ('StableSigner-' + label + '.app')
            createdApps.append(app)
            binary = app / 'Contents/MacOS/probe'
            binary.parent.mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identity if label != 'D' else identity + '.other', 'CFBundleExecutable': 'probe', 'CFBundleName': 'Synthetic Stable Signing QA', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': str(['A', 'B', 'C', 'D'].index(label) + 1)}))
            run('compile-' + label, ['xcrun', 'swiftc', '-parse-as-library', *(['-D', 'SECOND_BUILD'] if label != 'A' else []), str(root / 'apps/desktop/macos/Runner/DatabaseKeyStore.swift'), str(probe), '-o', str(binary)])
            cert = facts['certificateOther' if label == 'C' else 'certificateA']['sha1']
            run('sign-' + label, ['codesign', '--force', '--sign', cert, '--keychain', str(signingKeychain), '--timestamp=none', '--entitlements', str(root / 'apps/desktop/macos/Runner/Release.entitlements'), str(app)])
            run('verify-' + label, ['codesign', '--verify', '--deep', '--strict', str(app)])
            req = run('requirement-' + label, ['codesign', '-d', '-r-', str(app)])
            facts['variant' + label] = {'binarySha256': sha(binary.read_bytes()), 'designatedRequirement': req.stdout.decode().strip(), 'signingCertificate': cert}
            detail = run('signature-details-' + label, ['codesign', '-dvvv', str(app)])
            facts['variant' + label]['cdhash'] = re.search('^CDHash=([a-f0-9]+)$', detail.stderr.decode(), re.M).group(1)
            apps[label] = str(binary)
        assert facts['variantA']['binarySha256'] != facts['variantB']['binarySha256']
        assert facts['variantA']['designatedRequirement'] == facts['variantB']['designatedRequirement']
        assert facts['variantA']['designatedRequirement'] != facts['variantC']['designatedRequirement']
        assert facts['variantA']['designatedRequirement'] != facts['variantD']['designatedRequirement']
        for step in ['missing', 'create', 'read']:
            keysCreated = keysCreated or step == 'create'
            run('A-' + step, [apps['A'], service, step])
        metadata = run('A-owned-acl-metadata', [apps['A'], service, 'acl'])
        acl = json.loads(metadata.stdout.decode().splitlines()[0])['syntheticItemACL']
        partitions = []
        for entry in acl:
            try:
                decoded = plistlib.loads(bytes.fromhex(entry['description']))
                partitions.extend(decoded.get('Partitions', []))
            except (ValueError, TypeError, plistlib.InvalidFileException):
                pass
        facts['observedSyntheticItemPartitions'] = partitions
        facts['partitionMatchesOriginalCDHash'] = 'cdhash:' + facts['variantA']['cdhash'] in partitions
        facts['partitionIncludesUpgradeCDHash'] = 'cdhash:' + facts['variantB']['cdhash'] in partitions
        first = run('B-read-different-path', [apps['B'], service, 'read'], required=False)
        assert first.returncode in (0, 73), 'Read must return bounded allow/deny, not crash'
        facts['sameCertificateDifferentPathAccess'] = first.returncode == 0
        appA = out / 'StableSigner-A.app'
        originalApp = out / 'original-A'
        appA.rename(originalApp)
        try:
            shutil.copytree(out / 'StableSigner-B.app', appA)
            run('verify-B-at-exact-original-path', ['codesign', '--verify', '--deep', '--strict', str(appA)])
            second = run('B-read-exact-original-path', [apps['A'], service, 'read'], required=False)
            assert second.returncode in (0, 73), 'Read must return bounded allow/deny'
            facts['sameCertificateSamePathAccess'] = second.returncode == 0
        finally:
            if appA.exists():
                shutil.rmtree(appA)
            originalApp.rename(appA)
        run('C-different-certificate-denied', [apps['C'], service, 'denied'])
        run('D-different-identifier-denied', [apps['D'], service, 'denied'])
        run('A-original-still-reads', [apps['A'], service, 'read'])
        facts['crossVersionKeyAccessPreserved'] = facts['sameCertificateSamePathAccess']
        facts['unrelatedSignersDenied'] = True
        facts['probeCasesPassed'] = True
    finally:
        cleanup = []
        itemAbsent = not keysCreated
        if keysCreated:
            deleted = run('cleanup-owned-test-item', [apps['A'], service, 'delete'], required=False)
            absent = run('verify-owned-test-item-absent', [apps['A'], service, 'missing'], required=False)
            itemAbsent = deleted.returncode == 0 and absent.returncode == 0
            if not itemAbsent:
                cleanup.append('synthetic_item_cleanup_pending')
        signerDeleted = True
        if (private / 'signer.keychain').exists() or (private / 'signer.keychain-db').exists():
            removed = run('delete-private-signer', [helper], stdin=fixture('delete'), required=False)
            signerDeleted = removed.returncode == 0
            if not signerDeleted:
                cleanup.append('owned_signing_keychain_cleanup_pending')
        afterList = subprocess.check_output(['security', 'list-keychains', '-d', 'user'])
        afterDefault = subprocess.check_output(['security', 'default-keychain', '-d', 'user'])
        facts['searchListRestored'] = beforeList == afterList
        facts['defaultKeychainUnchanged'] = beforeDefault == afterDefault
        if not facts['searchListRestored'] or not facts['defaultKeychainUnchanged']:
            cleanup.append('keychain_context_differed')
        if signerDeleted:
            shutil.rmtree(private)
            facts['temporarySigningKeysDeleted'] = True
        else:
            facts['temporarySigningKeysDeleted'] = False
        if itemAbsent:
            for app in createdApps:
                subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if app.exists():
                    shutil.rmtree(app)
            facts['generatedAppsRemoved'] = True
        else:
            facts['generatedAppsRemoved'] = False
        if signerDeleted and itemAbsent and Path(helper).exists():
            Path(helper).unlink()
        facts['ownedSyntheticItemAbsent'] = itemAbsent
        facts['cleanupErrors'] = cleanup
        facts['complete'] = facts.get('probeCasesPassed', False) and (not cleanup)
        save()
        if cleanup:
            raise RuntimeError('Owned fixture cleanup incomplete; see result.json')
if __name__ == '__main__':
    main()
