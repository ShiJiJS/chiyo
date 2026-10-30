#!/usr/bin/env python3
"""Verify a Mac candidate and archive the exact existing application payload.

Preparation only: never swaps/launches an App, reads a library or recovery key,
changes Keychain, or installs hooks. The archive protects application files,
NOT user data. A fresh application-exported backup is still required to upgrade.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import stat
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / 'local/中文 Mac 预览/AgentInfoManage'


def digest_stream(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(chunk)
    return result.hexdigest()


def digest(path):
    with path.open('rb') as stream:
        return digest_stream(stream)


def inventory(root):
    """Do not follow directory symlinks or permit links outside the payload."""
    result = {}
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            target = os.readlink(path)
            if os.path.isabs(target):
                raise RuntimeError('Absolute payload link: ' + name)
            path.resolve(strict=True).relative_to(root)
            result[name] = {'link': target}
        elif stat.S_ISREG(mode):
            result[name] = {'bytes': path.stat().st_size,
                            'mode': stat.S_IMODE(mode), 'sha256': digest(path)}
        elif not stat.S_ISDIR(mode):
            raise RuntimeError('Special payload file: ' + name)
    return result


def check_payload(root, *, allow_extras):
    if not root.is_dir() or root.resolve() != root:
        raise RuntimeError('Payload must be an existing unlinked directory')
    manifest = json.loads((root / 'manifest.json').read_text())
    if (manifest.get('format') != 1 or manifest.get('product') != 'Agent Info Manage'
            or manifest.get('architecture') != 'macos-arm64'
            or manifest.get('appIdentity') != 'com.example.infoDesktop'):
        raise RuntimeError('Unexpected Mac package identity')
    actual = inventory(root)
    expected = {}
    for row in manifest['files']:
        name = row['path']
        parsed = PurePosixPath(name)
        if parsed.is_absolute() or '..' in parsed.parts or str(parsed) != name:
            raise RuntimeError('Unsafe manifest path')
        if name in expected or name == 'manifest.json':
            raise RuntimeError('Duplicate or self-referencing manifest entry')
        expected[name] = {k: v for k, v in row.items() if k != 'path'}
        if actual.get(name) != expected[name]:
            raise RuntimeError('Package file differs: ' + name)
    extras = set(actual) - set(expected) - {'manifest.json'}
    if extras and not allow_extras:
        raise RuntimeError('Candidate contains unlisted files')
    app = root / 'app/info_desktop.app'
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != manifest['appIdentity']:
        raise RuntimeError('App identity differs from manifest')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                   check=True, capture_output=True, timeout=120)
    return manifest, actual, sorted(extras)


def archive_payload(root, output, expected):
    # A compact recovery artifact, not another expanded .app for macOS to index.
    with output.open('xb') as file:
        os.fchmod(file.fileno(), 0o600)
        with tarfile.open(fileobj=file, mode='w:gz', dereference=False) as archive:
            archive.add(root, arcname='AgentInfoManage', recursive=True)
    seen = set()
    with tarfile.open(output, 'r:gz') as archive:
        for member in archive:
            relative = PurePosixPath(member.name).relative_to('AgentInfoManage')
            if member.isdir():
                continue
            name = str(relative)
            if name in seen or name not in expected:
                raise RuntimeError('Unexpected recovery archive member')
            seen.add(name)
            wanted = expected[name]
            if 'link' in wanted:
                if not member.issym() or member.linkname != wanted['link']:
                    raise RuntimeError('Archived link differs')
            else:
                if not member.isfile() or member.size != wanted['bytes'] or member.mode != wanted['mode']:
                    raise RuntimeError('Archived file metadata differs')
                with archive.extractfile(member) as stream:
                    if digest_stream(stream) != wanted['sha256']:
                        raise RuntimeError('Archived file bytes differ')
    if seen != set(expected) or inventory(root) != expected:
        raise RuntimeError('Installation changed during archive preparation')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='New directory beneath this checkout local/private/')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('Run on the target ARM64 Mac')
    candidate = args.candidate.absolute()
    candidate.relative_to(ROOT / 'build/macos-adaptation')
    output = args.output.absolute()
    output.relative_to(ROOT / 'local/private')
    if output.exists() or output.is_symlink() or output.parent.resolve() != output.parent:
        parser.error('Output must be new and have an existing unlinked parent')
    old, old_files, extras = check_payload(INSTALL, allow_extras=True)
    new, new_files, _ = check_payload(candidate, allow_extras=False)
    if old['sourceCommit'] == new['sourceCommit']:
        parser.error('Candidate is already installed')
    output.mkdir(mode=0o700)
    report = {'format': 1, 'prepared': False, 'installed': False,
              'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'installedRelease': old['release'], 'candidateRelease': new['release'],
              'candidateSource': new['sourceCommit'],
              'candidateManifestSha256': digest(candidate / 'manifest.json'),
              'installedManifestSha256': digest(INSTALL / 'manifest.json'),
              'installedFiles': len(old_files), 'candidateFiles': len(new_files),
              'extraInstalledFilesPreserved': extras,
              'applicationBackupIsNotDataBackup': True,
              'libraryOpened': False, 'keychainAccessed': False,
              'remaining': ['fresh owner-exported encrypted backup and separately saved recovery key',
                            'normal exit and stopped process/listener check immediately before replacement',
                            'whole-directory replacement, normal Release launch and Keychain decision if needed',
                            'verify original data and normal independent reopen before deleting recovery artifacts']}
    try:
        archive = output / 'previous-application.tar.gz'
        archive_payload(INSTALL, archive, old_files)
        if inventory(candidate) != new_files:
            raise RuntimeError('Candidate changed during preparation')
        report.update(prepared=True, archiveBytes=archive.stat().st_size,
                      archiveSha256=digest(archive), archiveMembersVerified=len(old_files),
                      installedPayloadUnchanged=True, candidatePayloadUnchanged=True)
    finally:
        with (output / 'preparation.json').open('x') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
