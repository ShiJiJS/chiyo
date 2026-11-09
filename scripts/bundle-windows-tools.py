#!/usr/bin/env python3
"""Assemble fixed Windows GH/AWS payloads in a new directory, without install.

Archives, entry hashes, AWS Authenticode identity and notices are verified.
No PATH changes, installer actions, user tool copies or credential reads.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
from windows_msi_payload import extract, leaf

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'third_party/windows-tools.json'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def download(name, url, expected):
    cache = ROOT / '.downloads'
    cache.mkdir(exist_ok=True)
    target = cache / leaf(name)
    if target.is_symlink():
        raise ValueError('Redirected download')
    if not target.exists():
        fd, temporary = tempfile.mkstemp(prefix=name + '.', dir=cache)
        try:
            with os.fdopen(fd, 'wb') as output, urllib.request.urlopen(url, timeout=60) as response:
                shutil.copyfileobj(response, output)
            if digest(Path(temporary)) != expected:
                raise ValueError('Download SHA256 mismatch: ' + name)
            os.replace(temporary, target)
        finally:
            Path(temporary).unlink(missing_ok=True)
    if digest(target) != expected:
        raise ValueError('Cached SHA256 mismatch: ' + name)
    return target


def inventory(root):
    rows = []
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or path.is_junction():
            raise ValueError('Redirected tool payload')
        if path.is_file():
            rows.append({'path': path.relative_to(root).as_posix(),
                         'bytes': path.stat().st_size, 'sha256': digest(path)})
    return rows


def assemble(destination):
    destination = destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError('Tool destination must be new')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.parent.resolve() != destination.parent:
        raise ValueError('Redirected tool destination')
    lock = json.loads(LOCK.read_text())
    archives = {row['id']: download(row['archive'], row['url'], row['sha256'])
                for row in lock['tools']}
    aws = next(row for row in lock['tools'] if row['id'] == 'aws-cli')
    # Pass the public fixed path through an environment variable, never inject
    # it into PowerShell code. Get-AuthenticodeSignature does not run the MSI.
    signed = subprocess.check_output([
        'pwsh.exe', '-NoProfile', '-NonInteractive', '-Command',
        '$ErrorActionPreference="Stop"; $s=Get-AuthenticodeSignature -LiteralPath $env:CHIYO_TOOL_MSI; '
        '@{status=$s.Status.ToString();thumbprint=$s.SignerCertificate.Thumbprint;'
        'subject=$s.SignerCertificate.Subject}|ConvertTo-Json -Compress'],
        env={**os.environ, 'CHIYO_TOOL_MSI': str(archives['aws-cli'])}, text=True)
    signature = json.loads(signed)
    if (signature['status'] != 'Valid' or signature['thumbprint'] != aws['signerThumbprint']
            or 'Amazon Web Services, Inc.' not in signature['subject']):
        raise ValueError('Unexpected AWS installer signer')
    notices = [(row, download(row['cache'], row['url'], row['sha256'])) for row in lock['notices']]
    scratch = ROOT / '.cache'
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='windows-tools-', dir=scratch) as temp:
        staging = Path(temp)
        payload = staging / 'tools'
        payload.mkdir()
        with zipfile.ZipFile(archives['gh']) as archive:
            if set(archive.namelist()) != {'LICENSE', 'bin/gh.exe'}:
                raise ValueError('Unexpected GH archive layout')
            for name in archive.namelist():
                info = archive.getinfo(name)
                if info.file_size > 128 * 1024 * 1024 or info.external_attr >> 16 & 0o170000 == 0o120000:
                    raise ValueError('Invalid GH archive file')
                target = payload / 'gh' / name
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
        extract(archives['aws-cli'], staging / 'msi', scratch)
        shutil.copytree(staging / 'msi/Amazon/AWSCLIV2', payload / 'aws-cli')
        notice_dir = payload / 'notices'
        notice_dir.mkdir()
        for row, path in notices:
            shutil.copyfile(path, notice_dir / row['name'])
        shutil.copyfile(payload / 'gh/LICENSE', notice_dir / 'GH-LICENSE.txt')
        for row in lock['tools']:
            if digest(payload / row['executable']) != row['executableSha256']:
                raise ValueError('Tool entry SHA256 mismatch: ' + row['id'])
        manifest = {**lock, 'files': inventory(payload)}
        (payload / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # A new target only. Leave failed outputs intact for diagnosis.
        shutil.copytree(payload, destination)
    print('Verified Windows GH 2.102.0 / AWS CLI 2.38.1 payload: ' + str(destination))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    assemble(parser.parse_args().destination)
