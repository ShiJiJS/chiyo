"""Check native v2 formats against the unchanged pre-v2 source, using synthetic data."""
import argparse
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
COMMON = r"""
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/library_replication.dart';
import 'package:info_core/library_sync_changes.dart';
import 'package:info_storage/info_storage.dart';
class Keys implements DatabaseKeyStore {
  Future<List<int>?> read() async => List.filled(32, 61);
  Future<void> create(List<int> key) async => throw StateError('Fixture key already exists');
}
const kinds = ['appkit_secure_text', 'win32_password', 'winforms_password',
  'wpf_password', 'macos_ax_password', 'windows_uia_password'];
bool v2(String kind) => kind == 'macos_ax_password' || kind == 'windows_uia_password';
Map<String, dynamic> target(String kind) {
  final windows = kind != 'appkit_secure_text' && kind != 'macos_ax_password';
  final executable = windows ? r'C:\Synthetic\Receiver.exe' : '/Applications/Synthetic.app/Contents/MacOS/Synthetic';
  return {
    'targetId': 'N' * 32, 'helperInstanceId': 'H' * 32,
    'platform': windows ? 'windows' : 'macos',
    'application': {'executable': executable, 'sha256': 'a' * 64},
    'appId': windows ? executable : 'synthetic.native', 'appName': 'Synthetic native',
    'windowId': 'W' * 32, 'windowTitle': 'Synthetic login',
    'fieldLabel': 'Password', 'controlKind': kind,
  };
}
"""
PRODUCER = COMMON + r"""
Future<void> main(List<String> args) async {
  for (final kind in kinds) {
    final folder = '${args.single}/$kind';
    final repo = await EncryptedInformationRepository.open('$folder/source', Keys());
    final service = InformationService(repository: repo);
    try {
      final credential = await service.owner.createStringCredential(
        name: 'Synthetic native', publicPurpose: '', secret: 'SYNTHETIC-COMPATIBILITY-ONLY');
      await service.owner.updateCredentialMetadata(credential.id, credential.revision,
        name: credential.name, publicPurpose: '', privateNote: '',
        suggestedBinding: 'password', discoverable: true);
      final session = service.agent.openSession('Synthetic compatibility');
      final request = await service.agent.requestCredentialBatch(session, 'A' * 22,
        CredentialBatchInput.fromJson({'protocolVersion': 3,
          'purpose': 'Synthetic compatibility',
          'items': [{'credentialId': credential.id,
            'destination': {'via': 'native', 'target': target(kind)}}]}),
        operationId: 'synthetic-submit');
      await service.owner.decideCredentialBatch(request.id, operationId: 'synthetic-approve',
        revision: request.revision, approvedItems: ['b1']);
      final recovery = await repo.backups.enable();
      await repo.backups.saveRecoveryKeyTo('$folder/recovery.txt');
      final backup = '$folder/history.aimbackup';
      await service.owner.exportLibrary(() => repo.backups.exportTo(backup));
      final format = (await repo.backups.inspect(backup, recovery)).formatVersion;
      if (format != (v2(kind) ? 31 : 30)) throw StateError('Unexpected content format');
      final initial = LibraryInitialTransfer(libraryId: 'a' * 32,
        snapshotId: 'b' * 64, archiveDigest: 'c' * 64, byteLength: 4096,
        contentFormat: format);
      final delta = LibraryDeltaTransfer(archive: initial,
        sourceReplicaId: 'd' * 32, operationId: 'synthetic-delta', sequence: 1);
      await File('$folder/metadata.json').writeAsString(jsonEncode({
        'initial': initial.toJson(), 'delta': delta.toJson(), 'target': target(kind)}));
    } finally {
      await service.close();
      await repo.close();
    }
  }
  stdout.writeln('NATIVE_V2_SYNTHETIC_FORMATS_CREATED');
}
"""
READER = COMMON + r"""
Future<void> main(List<String> args) async {
  for (final kind in kinds) {
    final folder = '${args.single}/$kind';
    final source = File('$folder/source/library.db');
    final digest = sha256.convert(await source.readAsBytes()).toString();
    EncryptedInformationRepository? opened;
    try {
      opened = await EncryptedInformationRepository.open('$folder/source', Keys());
      if (v2(kind)) throw StateError('Old reader accepted a v2 library');
      if (opened.credentialBatches.single.items.single.destination.native!.controlKind != kind)
        throw StateError('Legacy target changed');
    } on StorageFailure catch (error) {
      if (!v2(kind) || error.code != 'unsupported_schema') rethrow;
    } finally {
      await opened?.close();
    }
    if (v2(kind) && sha256.convert(await source.readAsBytes()).toString() != digest)
      throw StateError('Rejected source was modified');
    final recipient = await EncryptedInformationRepository.open('$folder/recipient', Keys());
    try {
      final recovery = (await File('$folder/recovery.txt').readAsString()).trim();
      try {
        final preview = await recipient.backups.inspect('$folder/history.aimbackup', recovery);
        if (v2(kind) || preview.formatVersion != 30) throw StateError('Old backup gate failed');
      } on StorageFailure catch (error) {
        if (!v2(kind) || error.code != 'unsupported_backup') rethrow;
      }
      if (v2(kind)) {
        try {
          await recipient.backups.restoreFrom('$folder/history.aimbackup', recovery);
          throw StateError('Old reader restored v2 history');
        } on StorageFailure catch (error) {
          if (error.code != 'unsupported_backup') rethrow;
        }
        if (recipient.managedCredentials.isNotEmpty || recipient.credentialBatches.isNotEmpty)
          throw StateError('Rejected restore modified recipient');
      }
    } finally {
      await recipient.close();
    }
    final metadata = jsonDecode(await File('$folder/metadata.json').readAsString()) as Map;
    try {
      NativeFillTarget.fromJson(Map<String, dynamic>.from(metadata['target'] as Map));
      if (v2(kind)) throw StateError('Old parser accepted new kind');
    } on CredentialUseFailure catch (error) {
      if (!v2(kind) || error.code != 'unsupported_target') rethrow;
    }
    for (final key in ['initial', 'delta']) {
      try {
        final raw = Map<String, dynamic>.from(metadata[key] as Map);
        if (key == 'initial') { LibraryInitialTransfer.fromJson(raw); }
        else { LibraryDeltaTransfer.fromJson(raw); }
        if (v2(kind)) throw StateError('Old transfer parser accepted format 31');
      } on FormatException {
        if (!v2(kind)) rethrow;
      }
    }
    stdout.writeln('${v2(kind) ? 'REJECTED_V2' : 'READ_LEGACY'}:$kind');
  }
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--legacy-revision', default='c0119e44')
    args = parser.parse_args()
    legacy = subprocess.check_output(
        ['git', 'rev-parse', args.legacy_revision], cwd=ROOT, text=True).strip()
    parent = ROOT / 'build/native-fill-v2-compatibility'
    parent.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='synthetic-', dir=parent)).resolve()
    env = os.environ.copy()
    try:
        old = run / 'old'
        old.mkdir()
        archive = subprocess.check_output(
            ['git', 'archive', legacy, 'packages/info_core', 'packages/info_storage'], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archive)) as files:
            files.extractall(old, **({'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}))
        markers = []
        for name, repo, code in [('producer', ROOT, PRODUCER), ('reader', old, READER)]:
            probe = run / name
            probe.mkdir()
            (probe / 'pubspec.yaml').write_text(
                'name: native_v2_compatibility_probe\npublish_to: none\nenvironment:\n'
                '  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  info_storage:\n    path: '
                + json.dumps(str(repo / 'packages/info_storage')) + '\n  info_core:\n    path: '
                + json.dumps(str(repo / 'packages/info_core')) + '\n  crypto: ^3.0.6\n'
                'hooks:\n  user_defines:\n    sqlite3:\n      source: sqlcipher\n', encoding='utf-8')
            (probe / 'probe.dart').write_text(code, encoding='utf-8')
            subprocess.run([str(args.dart), 'pub', 'get', '--offline'], cwd=probe,
                           env=env, check=True, stdout=subprocess.DEVNULL)
            result = subprocess.run([str(args.dart), 'run', 'probe.dart', str(run)],
                                    cwd=probe, env=env, text=True, capture_output=True, timeout=180)
            if result.returncode:
                raise RuntimeError(f'{name}: {result.stdout[-3000:]} {result.stderr[-3000:]}')
            markers.extend(line for line in result.stdout.splitlines()
                           if line.startswith(('NATIVE_', 'READ_LEGACY:', 'REJECTED_V2:')))
        if len(markers) != 7:
            raise RuntimeError(f'Incomplete compatibility checks: {markers}')
        print(json.dumps({'legacySource': legacy, 'syntheticOnly': True, 'checks': markers}))
    finally:
        shutil.rmtree(run)


if __name__ == '__main__':
    main()
