"""Exercise an actual unchanged format-four checkout against a format-five backup."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
COMMON = '''
import 'dart:io';
import 'dart:convert';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:info_storage/info_storage.dart';
import 'package:info_core/info_core.dart';
class Keys implements DatabaseKeyStore {
  List<int>? key;
  Future<List<int>?> read() async => key;
  Future<void> create(List<int> value) async { key = value; }
}
'''
PRODUCER = COMMON + '''
Future<void> main(List<String> args) async {
  final root = args.single;
  final repo = await EncryptedInformationRepository.open('$root/source', Keys());
  final service = InformationService(repository: repo);
  try {
    await service.owner.createStringCredential(name: 'Synthetic format five', publicPurpose: '', secret: 'synthetic-format-five-only');
    await repo.backups.enable();
    await repo.backups.saveRecoveryKeyTo('$root/recovery.txt');
    await service.owner.exportLibrary(() => repo.backups.exportTo('$root/complete.aimbackup'));
    final key = (await repo.backups.recoveryKey())!;
    final preview = await repo.backups.inspect('$root/complete.aimbackup', key);
    if (preview.formatVersion != 5 || preview.credentialCount != 1) throw StateError('Expected complete format five');
    stdout.writeln('NEW_FORMAT_FIVE_VERIFIED');
  } finally { await service.close(); await repo.close(); }
}
'''
READER = COMMON + '''
Future<void> main(List<String> args) async {
  final root = args.single;
  final repo = await EncryptedInformationRepository.open('$root/recipient', Keys());
  try {
    final key = (await File('$root/recovery.txt').readAsString()).trim();
    var rejected = false;
    try { await repo.backups.restoreFrom('$root/complete.aimbackup', key); }
    on StorageFailure catch (e) { rejected = e.code == 'unsupported_backup'; }
    if (!rejected || repo.items.isNotEmpty) throw StateError('Old reader must reject without installing');
    stdout.writeln('OLD_READER_REJECTED_FORMAT_FIVE_WITH_EMPTY_RECIPIENT');
  } finally { await repo.close(); }
}
'''

OLD_PRODUCER = COMMON + '''
Future<void> main(List<String> args) async {
  final root = args.single;
  final keys = WindowsDatabaseKeyStore('$root/upgrade-source/key.dpapi');
  final repo = await EncryptedInformationRepository.open('$root/upgrade-source', keys);
  final service = InformationService(repository: repo);
  try {
    final item = await service.owner.createInformation('Synthetic old release', '', [const FieldInput('Host', '', 'synthetic-old.invalid')]);
    final ref = FieldRef(item.id, item.fields.single.id), session = service.agent.openSession('Synthetic old reader');
    final request = service.agent.request(session, 'Synthetic only', [ref]);
    service.owner.approve(request.id, [ref]);
    final proof = service.agent.claim(session, request.id).token;
    await service.agent.read(proof, ref);
    await File('$root/old-proof.txt').writeAsString(proof);
    await File('$root/upgrade-identity.json').writeAsString(jsonEncode({'id':item.id,'fieldId':ref.fieldId,'version':item.version}));
    await repo.backups.enable();
    await repo.backups.saveRecoveryKeyTo('$root/old-recovery.txt');
    await service.owner.exportLibrary(() => repo.backups.exportTo('$root/old.aimbackup'));
    stdout.writeln('OLD_RELEASE_CREATED_ENCRYPTED_DATA');
  } finally { await service.close(); await repo.close(); }
}
'''
UPGRADER = COMMON + r'''
int schema(String root, List<int> key) {
  final db = sql.sqlite3.open('$root/upgrade-source/library.db');
  try {
    final hex = key.map((v) => v.toRadixString(16).padLeft(2,'0')).join();
    db.execute('PRAGMA key = "x\'' + hex + '\'"');
    return db.select('PRAGMA user_version').single.values.single as int;
  } finally { db.close(); }
}
Future<void> main(List<String> args) async {
  final root = args.single;
  final keys = WindowsDatabaseKeyStore('$root/upgrade-source/key.dpapi');
  final key = (await keys.read())!;
  if (schema(root,key) != 12) throw StateError('Expected real old schema12');
  final identity = jsonDecode(await File('$root/upgrade-identity.json').readAsString());
  final proof = await File('$root/old-proof.txt').readAsString();
  final repo = await EncryptedInformationRepository.open('$root/upgrade-source', keys);
  final service = InformationService(repository: repo);
  void same(InformationItem item) {
    if (item.id != identity['id'] || item.version != identity['version'] || item.fields.single.id != identity['fieldId'] || item.fields.single.value != 'synthetic-old.invalid') throw StateError('Identity or content changed');
  }
  Future<void> denied(InformationService service) async {
    var denied = false;
    try { await service.agent.read(proof, FieldRef(identity['id'] as String, identity['fieldId'] as String)); }
    on AccessFailure { denied = true; }
    if (!denied) throw StateError('Old proof revived');
  }
  try {
    same(service.owner.information.single);
    await denied(service);
    await service.owner.createStringCredential(name: 'Synthetic after upgrade', publicPurpose: '', secret: 'synthetic-only');
  } finally { await service.close(); await repo.close(); }
  if (schema(root,key) != 16) throw StateError('Expected migrated schema16');
  final freshKeys = WindowsDatabaseKeyStore('$root/upgrade-restored/key.dpapi');
  final restored = await EncryptedInformationRepository.open('$root/upgrade-restored', freshKeys);
  final restoredService = InformationService(repository: restored);
  try {
    final recovery = (await File('$root/old-recovery.txt').readAsString()).trim();
    final preview = await restoredService.owner.restoreLibrary(() => restored.backups.restoreFrom('$root/old.aimbackup', recovery));
    if (preview.formatVersion != 3) throw StateError('Expected actual old format3');
    same(restoredService.owner.information.single);
    await denied(restoredService);
    if ((await restoredService.owner.history()).grants.any((g) => g.active)) throw StateError('Historical grant revived');
    if ((await freshKeys.read()).toString() == key.toString()) throw StateError('Local key reused');
    stdout.writeln('REAL_OLD_SCHEMA12_UPGRADED_TO16_AND_FORMAT3_RESTORED_WITHOUT_OLD_AUTHORITY');
  } finally { await restoredService.close(); await restored.close(); }
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--old-repo', type=Path, required=True)
    parser.add_argument('--old-source', required=True)
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--exercise-upgrade', action='store_true')
    args = parser.parse_args()
    old = args.old_repo.resolve()
    expected = subprocess.check_output(['git', 'rev-parse', args.old_source], cwd=old, text=True).strip()
    subprocess.run(['git', 'diff', '--exit-code', expected, '--', 'packages/info_storage', 'packages/info_core'], cwd=old, check=True)
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    parent = ROOT / '.scratch/legacy-backup-reader'
    parent.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='synthetic-', dir=parent)).resolve()
    assert run.parent == parent.resolve()
    env = os.environ.copy()
    env['PUB_HOSTED_URL'] = 'https://pub.dev'
    markers = []
    probes = [
        ('producer', ROOT, PRODUCER, 'NEW_FORMAT_FIVE_VERIFIED'),
        ('old-reader', old, READER, 'OLD_READER_REJECTED_FORMAT_FIVE_WITH_EMPTY_RECIPIENT'),
    ]
    if args.exercise_upgrade:
        probes += [('old-producer', old, OLD_PRODUCER, 'OLD_RELEASE_CREATED_ENCRYPTED_DATA'), ('upgrader', ROOT, UPGRADER, 'REAL_OLD_SCHEMA12_UPGRADED_TO16_AND_FORMAT3_RESTORED_WITHOUT_OLD_AUTHORITY')]
    for name, repo, code, marker in probes:
        package = run / name
        package.mkdir()
        (package / 'pubspec.yaml').write_text('name: legacy_backup_probe\npublish_to: none\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  info_storage:\n    path: ' + json.dumps(str(repo / 'packages/info_storage')) + '\n  info_core:\n    path: ' + json.dumps(str(repo / 'packages/info_core')) + '\n  sqlite3: 3.7.1\nhooks:\n  user_defines:\n    sqlite3:\n      source: sqlcipher\n', encoding='utf-8')
        (package / 'probe.dart').write_text(code, encoding='utf-8')
        subprocess.run([str(args.dart), 'pub', 'get', '--offline'], cwd=package, env=env, check=True, stdout=subprocess.DEVNULL)
        result = subprocess.run([str(args.dart), 'run', 'probe.dart', str(run)], cwd=package, env=env, capture_output=True, text=True, encoding='utf-8', timeout=180)
        if result.returncode or marker not in result.stdout:
            raise RuntimeError(f'{name} failed: {result.stdout[-2000:]} {result.stderr[-2000:]}')
        markers.append(marker)
    print(json.dumps({'newSource': source, 'oldSource': expected, 'markers': markers, 'syntheticOnly': True, 'recipientUnchanged': True}))


if __name__ == '__main__':
    main()
