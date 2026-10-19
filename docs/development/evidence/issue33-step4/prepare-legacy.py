"""Prepare an unmodified schema16/backup5 reader from the delivered Git source."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[4]
qa = root / 'build/qa-issue33'
qa.mkdir(parents=True, exist_ok=True)
ref = '291801046f7d1e6e4217a4bc001ea714689855c5'
destination = Path(tempfile.mkdtemp(prefix='legacy16-source-', dir=qa))
archive = destination / 'source.zip'
subprocess.run(['git', 'archive', '--format=zip', '--output', str(archive), ref,
                'packages/info_core', 'packages/info_storage'], cwd=root, check=True)
with zipfile.ZipFile(archive) as source:
    for entry in source.infolist():
        assert (destination / entry.filename).resolve().is_relative_to(destination.resolve())
    source.extractall(destination)
package = destination / 'packages/info_storage'
helper = root / 'packages/info_storage/test/support/legacy16_probe.dart'
reader = package / 'legacy_probe.dart'
reader.write_bytes(helper.read_bytes())
lock = package / 'pubspec.lock'
original_lock = lock.read_bytes()
lock.write_bytes(original_lock.replace(b'https://pub.dev', b'https://pub.flutter-io.cn'))
env = os.environ.copy()
env['PUB_HOSTED_URL'] = 'https://pub.flutter-io.cn'
dart = env.get('DART_EXE', 'C:/Users/Todoki/.local/share/flutter/bin/dart.bat')
for offline in [True, False]:
    result = subprocess.run([dart, 'pub', 'get', '--enforce-lockfile'] +
                            (['--offline'] if offline else []), cwd=package, env=env,
                            capture_output=True, text=True, encoding='utf-8')
    (qa / 'legacy16-preparation.txt').write_text(result.stdout + result.stderr, encoding='utf-8')
    if result.returncode == 0:
        break
if result.returncode:
    raise RuntimeError('Legacy dependency preparation failed; see saved output')
digest = lambda data: hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest()
metadata = {'sourceCommit': ref, 'archiveSha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
            'helperSha256': digest(helper.read_bytes()), 'lockSha256': digest(original_lock),
            'reader': str(reader), 'schema': 16, 'backupFormat': 5,
            'execution': 'dart run legacy_probe.dart with original SQLCipher native-asset hooks'}
(qa / 'legacy16-reader-preparation.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
print(json.dumps(metadata, indent=2))
