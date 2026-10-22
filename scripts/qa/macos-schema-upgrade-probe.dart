// QA-only AOT helper, compiled independently against actual old/current sources.
// The random synthetic key arrives on stdin; never report it or raw SQL rows.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

const expectedCurrentSchema = 22;

class _Keys implements DatabaseKeyStore {
  _Keys(this.bytes);
  final List<int> bytes;
  @override
  Future<List<int>?> read() async => List.of(bytes);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Unexpected key creation');
}

/// Migration compares against the old library; reopening compares against the
/// last completed run, including audit rows created by verification itself.
void verifySchemaUpgradeSnapshot(
  Map snapshot,
  Map baseline, {
  required bool migratingLegacy,
}) {
  if (snapshot['schema'] != expectedCurrentSchema ||
      snapshot['marker'] != expectedCurrentSchema ||
      snapshot['integrity'] != 'ok' ||
      baseline['schema'] != (migratingLegacy ? 20 : expectedCurrentSchema)) {
    throw StateError('Invalid migration/reopen snapshot');
  }
  final tables = snapshot['tables'] as Map;
  final expected = baseline['tables'] as Map;
  final names = {...expected.keys};
  if (migratingLegacy) names.add('information_deliveries');
  if (tables.length != names.length || !names.containsAll(tables.keys)) {
    throw StateError('Migration/reopen table set changed');
  }
  for (final entry in expected.entries) {
    if (migratingLegacy && entry.key == 'information_draft_commits') continue;
    if (jsonEncode(tables[entry.key]) != jsonEncode(entry.value)) {
      throw StateError('Durable expected table changed: ${entry.key}');
    }
  }
  if ((tables['information_draft_commits'] as Map)['rows'] != 0 ||
      (tables['information_deliveries'] as Map)['rows'] != 0) {
    throw StateError('Transient drafts or new delivery registry invalid');
  }
}

Future<void> main(List<String> args) async {
  if (!Platform.isMacOS ||
      args.length != 2 ||
      !{
        'create',
        'inspect',
        'conflict',
        'repair',
        'snapshot',
      }.contains(args[0])) {
    exitCode = 64;
    return;
  }
  final input = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  final key = base64Decode(input['key'] as String);
  if (key.length != 32) {
    exitCode = 64;
    return;
  }
  final result = await runSchemaUpgradeFixture(
    args[0],
    Directory(args[1]),
    key,
  );
  stdout.writeln(jsonEncode(result));
  if (result['status'] != 'ok') exitCode = 1;
}

/// The same fixture runs inside each signed Flutter host. It never receives or
/// returns a production key: hosts read their dedicated QA Keychain item and
/// pass a short-lived copy entirely within their process. Returned data contains
/// row counts/digests, not raw rows or authorization material.
Future<Map<String, Object?>> runSchemaUpgradeFixture(
  String mode,
  Directory root,
  List<int> key,
) async {
  if (key.length != 32 ||
      !{'create', 'inspect', 'conflict', 'repair', 'snapshot'}.contains(mode)) {
    throw ArgumentError('Invalid fixture input');
  }
  final database = '${root.path}/library/library.db';
  final now = DateTime.utc(2026, 10, 21);
  sql.Database raw() {
    final db = sql.sqlite3.open(database);
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  Map<String, Object?> snapshot() {
    final db = raw();
    try {
      final tables = <String, Object?>{};
      for (final table in db.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name<>'library_format' ORDER BY name",
      )) {
        final name = table['name'] as String;
        if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name))
          throw StateError('Unexpected table');
        final rows = db.select('SELECT * FROM "$name" ORDER BY rowid');
        final values = [
          for (final row in rows)
            [
              for (final value in row.values)
                if (value is List<int>)
                  {'blob': base64Encode(value)}
                else
                  value,
            ],
        ];
        tables[name] = {
          'rows': rows.length,
          'sha256': sha256.convert(utf8.encode(jsonEncode(values))).toString(),
        };
      }
      return {
        'schema': db.select('PRAGMA user_version').single.values.single,
        'marker': db
            .select('SELECT version FROM library_format')
            .single
            .values
            .single,
        'integrity': db.select('PRAGMA integrity_check').single.values.single,
        'tables': tables,
      };
    } finally {
      db.close();
    }
  }

  EncryptedInformationRepository? repository;
  InformationService? service;
  Map<String, Object?>? beforeChecks;
  try {
    if (mode == 'snapshot') return {'status': 'ok', ...snapshot()};
    if (mode == 'conflict' || mode == 'repair') {
      final db = raw();
      try {
        db.execute(
          mode == 'conflict'
              ? 'CREATE TABLE information_deliveries (qa_conflict INTEGER NOT NULL)'
              : 'DROP TABLE information_deliveries',
        );
      } finally {
        db.close();
      }
      return {'status': 'ok', 'fixtureMutation': mode, ...snapshot()};
    }
    repository = await EncryptedInformationRepository.open(
      '${root.path}/library',
      _Keys(key),
      clock: () => now,
    );
    service = InformationService(repository: repository, clock: () => now);
    if (mode == 'create') {
      final text = await service.owner.createInformation(
        'Synthetic legacy text',
        '',
        [const FieldInput('Text', '', 'synthetic schema upgrade value')],
      );
      await service.owner.createStringCredential(
        name: 'Synthetic legacy credential',
        publicPurpose: 'QA only',
        secret: 'synthetic schema upgrade credential',
      );
      InformationItem? before;
      for (var version = 1; version <= 2; version++) {
        final source = File('${root.path}/source-$version.bin');
        final bytes = List<int>.generate(
          version == 1 ? 1024 * 1024 + 17 : 2049,
          (i) => (i * 37 + version) % 256,
        );
        await source.writeAsBytes(bytes);
        final draft = await service.owner.beginInformationFileDraft();
        final staged = await service.owner.stageInformationFile(
          draft,
          source.path,
        );
        before = await service.owner.commitInformationDraft(
          draft,
          'legacy-$version',
          InformationDraftInput(
            name: 'Synthetic legacy file',
            description: '',
            itemId: before?.id,
            baseVersion: before?.version,
            fields: [
              InformationDraftField.stagedFile(
                'File',
                '',
                staged.id,
                fieldId: before?.fields.single.id,
              ),
            ],
          ),
        );
        await service.owner.releaseInformationFileDraft(draft);
      }
      final field = FieldRef(text.id, text.fields.single.id);
      final session = service.agent.openSession('Synthetic legacy session');
      final request = service.agent.request(session, 'QA only', [field]);
      service.owner.approve(request.id, [field]);
      final token = service.agent.claim(session, request.id).token;
      if (await service.agent.read(token, field) !=
          'synthetic schema upgrade value')
        throw StateError('Read mismatch');
      final association = File('${root.path}/.private-association.json');
      await association.writeAsString(
        jsonEncode({
          'token': token,
          'item': field.itemId,
          'field': field.fieldId,
        }),
      );
      if ((await Process.run('/bin/chmod', [
            '600',
            association.path,
          ])).exitCode !=
          0)
        throw StateError('Private fixture permissions');
    } else {
      beforeChecks = snapshot();
      final old = jsonDecode(
        await File('${root.path}/.private-association.json').readAsString(),
      ) as Map;
      var refused = false;
      try {
        await service.agent.read(
          old['token'] as String,
          FieldRef(old['item'] as String, old['field'] as String),
        );
      } on AccessFailure {
        refused = true;
      }
      if (!refused) throw StateError('Old authority survived reopen');
      final item = repository.items.singleWhere(
        (i) => i.name == 'Synthetic legacy file',
      );
      final current = item.fields.single.attachment!;
      final versions = await repository.informationAttachmentVersions(
        current.attachmentId,
      );
      if (versions.length != 2 || current.attachmentVersion != 2)
        throw StateError('Version identity changed');
      for (final version in versions) {
        final original = await File(
          '${root.path}/source-${version.reference.attachmentVersion}.bin',
        ).readAsBytes();
        final actual = <int>[];
        for (var offset = 0; offset < original.length; offset += 64 * 1024) {
          final remaining = original.length - offset;
          actual.addAll(
            await repository.readInformationAttachmentChunk(
              version.reference,
              offset,
              remaining > 64 * 1024 ? 64 * 1024 : remaining,
            ),
          );
        }
        if (sha256.convert(original) != sha256.convert(actual))
          throw StateError('Original changed');
      }
      if (repository.grantHistory.length != 1 ||
          repository.grantHistory.single.active ||
          !repository.accessRecords.any(
            (r) => r.outcome == AccessOutcome.allowed,
          ))
        throw StateError('History changed');
    }
    final cipher = repository.cipherVersion;
    await service.close();
    service = null;
    await repository.close();
    repository = null;
    return {
      'status': 'ok',
      'cipherVersion': cipher,
      'oldAuthorityRefused': mode != 'create',
      if (beforeChecks != null) 'beforeVerificationOperations': beforeChecks,
      ...snapshot(),
    };
  } catch (error) {
    return {
      'status': 'failed',
      'errorType': error.runtimeType.toString(),
      if (error is AccessFailure) 'accessFailure': error.status,
      if (error is StateError) 'checkFailure': error.message.toString(),
      if (error is StorageFailure) 'storageFailure': error.code,
    };
  } finally {
    await service?.close();
    await repository?.close();
    key.fillRange(0, key.length, 0);
  }
}
