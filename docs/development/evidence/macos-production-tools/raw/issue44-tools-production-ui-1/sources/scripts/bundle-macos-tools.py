#!/usr/bin/env python3
"""Assemble fixed official tools into an already built Mac app, then re-seal it.

Only verified archives are extracted, never local installations. No pkg scripts,
system installation, PATH changes, sandbox exceptions or credential access.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'third_party/macos-tools.json'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def verified_download(name, url, expected):
    cache = ROOT / '.downloads'
    cache.mkdir(exist_ok=True)
    path = cache / name
    if path.is_symlink():
        raise RuntimeError('Download cache must not be a symlink: ' + name)
    if not path.exists():
        fd, temporary = tempfile.mkstemp(prefix=name + '.', dir=cache)
        try:
            with os.fdopen(fd, 'wb') as output, urllib.request.urlopen(url, timeout=60) as response:
                shutil.copyfileobj(response, output)
            if digest(Path(temporary)) != expected:
                raise RuntimeError('Downloaded SHA256 mismatch: ' + name)
            os.replace(temporary, path)
        finally:
            Path(temporary).unlink(missing_ok=True)
    if digest(path) != expected:
        raise RuntimeError('Cached SHA256 mismatch: ' + name)
    return path


def inventory(root):
    rows = []
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            path.resolve(strict=True).relative_to(root.resolve())
            rows.append({'path': name, 'link': os.readlink(path)})
        elif path.is_file():
            rows.append({'path': name, 'bytes': path.stat().st_size,
                         'mode': stat.S_IMODE(path.stat().st_mode), 'sha256': digest(path)})
    return rows


def assemble(app):
    app = app.resolve(strict=True)
    if not (app / 'Contents/MacOS/info_desktop').is_file():
        raise RuntimeError('Expected a built info_desktop.app')
    lock = json.loads(LOCK.read_text())
    archives = {row['id']: verified_download(row['archive'], row['url'], row['sha256'])
                for row in lock['tools']}
    notices = [(row, verified_download(row['cache'], row['url'], row['sha256']))
               for row in lock['notices']]
    signature = subprocess.check_output(['/usr/sbin/pkgutil', '--check-signature', str(archives['aws-cli'])], text=True)
    if 'Developer ID Installer: AMZN Mobile LLC (94KV3E626L)' not in signature:
        raise RuntimeError('Unexpected AWS installer signer')
    scratch = ROOT / '.cache/tmp'
    scratch.mkdir(parents=True, exist_ok=True)
    destination = app / 'Contents/Resources/ThirdParty'
    with tempfile.TemporaryDirectory(prefix='mac-tools-', dir=scratch) as temporary:
        staging = Path(temporary)
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archives['gh']), str(staging / 'gh')], check=True)
        subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(archives['aws-cli']), str(staging / 'aws')], check=True)
        payload = staging / 'ThirdParty'
        payload.mkdir()
        shutil.copytree(staging / 'gh/gh_2.102.0_macOS_arm64', payload / 'gh', symlinks=True)
        shutil.copytree(staging / 'aws/aws-cli.pkg/Payload/aws-cli', payload / 'aws-cli', symlinks=True)
        notice_dir = payload / 'notices'
        notice_dir.mkdir()
        for row, path in notices:
            shutil.copy2(path, notice_dir / row['name'])
        shutil.copy2(staging / 'aws/Resources/LICENSE.txt', notice_dir / 'AWS-installer-LICENSE.txt')
        shutil.copy2(payload / 'gh/LICENSE', notice_dir / 'GH-LICENSE.txt')
        for row in lock['tools']:
            if digest(payload / row['executable']) != row['executableSha256']:
                raise RuntimeError('Unexpected tool entry bytes: ' + row['id'])
        manifest = {**lock, 'files': inventory(payload)}
        (payload / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # Refuse a redirected destination rather than deleting its target.
        if destination.is_symlink():
            raise RuntimeError('ThirdParty destination must not be a symlink')
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(payload, destination, symlinks=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-',
                    '--preserve-metadata=entitlements,requirements,flags,runtime', str(app)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('Bundled GH 2.102.0 and AWS CLI 2.38.1 from verified official archives', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    assemble(args.app)
