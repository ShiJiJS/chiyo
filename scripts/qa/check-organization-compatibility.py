"""Check actual unchanged schema21 reader against schema22 / format10.

Extracts only committed core/storage sources into a fresh ignored build folder;
all profiles, DPAPI envelopes and backup recovery keys are synthetic and local.
Does not check out a branch or modify the working package locks.
"""
import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
COMMON = r'''
import 'dart:io';
import 'dart:convert';
import 'package:info_storage/info_storage.dart';
import 'package:info_core/info_core.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
WindowsDatabaseKeyStore keys(String root, String name) => WindowsDatabaseKeyStore('$root/$name/key.dpapi');
int schema(String root, List<int> key) {
  final db = sql.sqlite3.open('$root/source/library.db');
  try {
    final hex = key.map((b)=>b.toRadixString(16).padLeft(2,'0')).join();
    db.execute('PRAGMA key = "x\'' + hex + '\'"');
    return db.select('PRAGMA user_version').single.values.single as int;
  } finally {db.close();}
}
'''
OLD_PRODUCER = COMMON + r'''
Future<void> main(List<String> args) async {
  final root=args.single, k=keys(args.single,'source');
  final repo=await EncryptedInformationRepository.open('$root/source',k);
  final service=InformationService(repository:repo);
  try {
    final o=service.owner, d=await service.owner.createDirectory('Project'), t=await service.owner.createTag('Docs');
    final i=await o.createInformation('Synthetic resume','',[const FieldInput('Text','','synthetic content')],directoryId:d.id,tagIds:[t.id]);
    await File('$root/identity.json').writeAsString(jsonEncode({'id':i.id,'field':i.fields.single.id,'directory':d.id,'tag':t.id}));
    await repo.backups.enable();
    await repo.backups.saveRecoveryKeyTo('$root/recovery.txt');
    await o.exportLibrary(()=>repo.backups.exportTo('$root/old.aimbackup'));
  } finally {await service.close();await repo.close();}
  if(schema(root,(await k.read())!)!=21) throw StateError('Old source did not create schema21');
  stdout.writeln('UNCHANGED_OLD_READER_CREATED_SCHEMA21');
}
'''
UPGRADE = COMMON + r'''
Future<void> main(List<String> args) async {
  final root=args.single, k=keys(args.single,'source');
  final id=jsonDecode(await File('$root/identity.json').readAsString());
  final recovery=(await File('$root/recovery.txt').readAsString()).trim();
  if(schema(root,(await k.read())!)!=21) throw StateError('Not an actual old fixture');
  final repo=await EncryptedInformationRepository.open('$root/source',k);
  final service=InformationService(repository:repo);
  try {
    final o=service.owner, i=service.owner.information.single;
    if(i.id!=id['id']||i.fields.single.id!=id['field']||i.fields.single.value!='synthetic content') throw StateError('Migration changed identity or content');
    final old=await repo.backups.inspect('$root/old.aimbackup',recovery);
    if(old.formatVersion>9||old.informationCount!=1) throw StateError('Old backup not readable');
    await o.deleteTag(o.tags.single.id,o.tags.single.version);
    await o.deleteInformation(i.id,o.information.single.version);
    await o.deleteDirectory(o.directories.single.id,o.directories.single.version);
    await o.exportLibrary(()=>repo.backups.exportTo('$root/new.aimbackup'));
    final current=await repo.backups.inspect('$root/new.aimbackup',recovery);
    if(current.formatVersion!=10) throw StateError('Expected conditional format10');
  } finally {await service.close();await repo.close();}
  if(schema(root,(await k.read())!)!=22) throw StateError('Migration did not mark schema22');
  final recipient=await EncryptedInformationRepository.open('$root/old-restore',keys(root,'old-restore'));
  try {
    final contents=await recipient.backups.inspect('$root/old.aimbackup',recovery);
    await recipient.backups.restore(contents);
    if(recipient.items.single.id!=id['id']) throw StateError('Old backup lost identity');
  } finally {await recipient.close();}
  stdout.writeln('SCHEMA21_TO22_IDENTITY_AND_OLD_BACKUP_RESTORE_PASSED');
}
'''
OLD_READER = COMMON + r'''
Future<void> main(List<String> args) async {
  final root=args.single;
  var refused=false;
  try {
    final unexpected=await EncryptedInformationRepository.open('$root/source',keys(root,'source'));
    await unexpected.close();
  } on StorageFailure catch(e) {refused=e.code=='unsupported_schema';}
  if(!refused) throw StateError('Old application accepted schema22');
  final recipient=await EncryptedInformationRepository.open('$root/old-reader',keys(root,'old-reader'));
  try {
    var denied=false;
    final recovery=(await File('$root/recovery.txt').readAsString()).trim();
    try {await recipient.backups.inspect('$root/new.aimbackup',recovery);}
    on StorageFailure catch(e) {denied=e.code=='unsupported_backup';}
    if(!denied||recipient.items.isNotEmpty) throw StateError('Old reader accepted format10 or modified recipient');
  } finally {await recipient.close();}
  if(schema(root,(await keys(root,'source').read())!)!=22) throw StateError('Old reader changed schema marker');
  stdout.writeln('UNCHANGED_OLD_READER_REJECTED_SCHEMA22_AND_FORMAT10');
}
'''

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dart', required=True)
    parser.add_argument('--old-source', default='b37f96a')
    args = parser.parse_args()
    revision = subprocess.check_output(['git', 'rev-parse', args.old_source], cwd=ROOT, text=True).strip()
    parent = ROOT / 'build/library-ux/compatibility'
    parent.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='synthetic-', dir=parent)).resolve()
    old = run / 'old-source'
    archive = subprocess.check_output(['git', 'archive', '--format=zip', revision, 'packages/info_core', 'packages/info_storage'], cwd=ROOT)
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        for member in zipped.infolist():
            if not (old / member.filename).resolve().is_relative_to(old.resolve()):
                raise ValueError('Archive escaped its destination')
        zipped.extractall(old)
    env = os.environ.copy()
    env['PUB_HOSTED_URL'] = 'https://pub.flutter-io.cn'
    markers = []
    for name, repo, code in [('old-producer', old, OLD_PRODUCER), ('upgrade', ROOT, UPGRADE), ('old-reader', old, OLD_READER)]:
        probe = run / name
        probe.mkdir()
        manifest = 'name: organization_compatibility_probe\npublish_to: none\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  info_storage:\n    path: '+json.dumps(str(repo/'packages/info_storage'))+'\n  info_core:\n    path: '+json.dumps(str(repo/'packages/info_core'))+'\n  sqlite3: 3.7.1\nhooks:\n  user_defines:\n    sqlite3:\n      source: sqlcipher\n'
        (probe/'pubspec.yaml').write_text(manifest, encoding='utf-8')
        (probe/'probe.dart').write_text(code, encoding='utf-8')
        subprocess.run([args.dart, 'pub', 'get', '--offline'], cwd=probe, env=env, check=True, stdout=subprocess.DEVNULL)
        result = subprocess.run([args.dart, 'run', 'probe.dart', str(run)], cwd=probe, env=env, text=True, encoding='utf-8', capture_output=True, timeout=180)
        if result.returncode:
            raise RuntimeError(f'{name}: {result.stdout[-2000:]} {result.stderr[-2500:]}')
        markers.append(result.stdout.strip())
        print(markers[-1], flush=True)
    report = {'oldSource': revision, 'checks': markers, 'syntheticOnly': True, 'oldSourceUnmodified': True, 'realWindowsDPAPI': True}
    (parent/'verification.json').write_text(json.dumps(report, indent=2), encoding='utf-8')

if __name__ == '__main__':
    main()
