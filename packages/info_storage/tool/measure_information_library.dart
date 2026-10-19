import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

class _Keys implements DatabaseKeyStore {
  _Keys(this.byte);
  final int byte;
  @override
  Future<List<int>?> read() async => List<int>.filled(32, byte);
  @override
  Future<void> create(List<int> value) async =>
      throw StateError('Fixed synthetic key');
}

/// Actual repository/retention/copy/backup/restore pipeline, synthetic data only.
/// Run as a separate JIT process or `dart build cli` bundle, never on a user vault.
Future<void> main(List<String> args) async {
  if (args.length != 1 ||
      !{'small', 'near-limit', 'history-limit'}.contains(args.single)) {
    throw ArgumentError('Choose small, near-limit or history-limit');
  }
  final near = args.single == 'near-limit';
  final dense = args.single == 'history-limit';
  final root = await Directory.systemTemp.createTemp(
    'information-library-measure-',
  );
  final watch = Stopwatch()..start();
  final initialRss = ProcessInfo.currentRss;
  final now = DateTime.utc(2026, 10, 19);
  final sourceKeys = _Keys(61), targetKeys = _Keys(62);
  EncryptedInformationRepository? source, target;
  InformationService? service, recipient;
  final copies = <String>[];
  final measurements = <Map<String, Object?>>[];
  var removed = false;
  Map<String, Object?>? result;
  void sample(String phase) {
    final row = <String, Object?>{
      'phase': phase,
      'elapsedMs': watch.elapsedMilliseconds,
      'rss': ProcessInfo.currentRss,
      'maxRss': ProcessInfo.maxRss,
    };
    measurements.add(row);
    stdout.writeln(jsonEncode(row));
  }

  Future<void> require(bool condition, String message) async {
    if (!condition) throw StateError(message);
  }

  sqlite.Database database(String path, int byte) {
    final db = sqlite.sqlite3.open(path);
    final hex = List<int>.filled(
      32,
      byte,
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  Future<int> payloadSize(String path, String key) async {
    final db = sqlite.sqlite3.open(path);
    final hex = base64Url
        .decode(key.substring('aim-recovery-v1:'.length))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    try {
      db.execute('PRAGMA key = "x\'$hex\'"');
      return db
              .select(
                'SELECT length(CAST(payload AS BLOB)) AS n FROM backup_snapshot',
              )
              .single['n']
          as int;
    } finally {
      db.close();
    }
  }

  try {
    source = await EncryptedInformationRepository.open(
      '${root.path}/source',
      sourceKeys,
      clock: () => now,
    );
    service = InformationService(
      repository: source,
      clock: () => now,
      informationDeliveryFiles: WindowsInformationDeliveryFiles(),
    );
    final file = File('${root.path}/synthetic.bin');
    final writer = await file.open(mode: FileMode.write);
    try {
      final chunk = Uint8List(1024 * 1024);
      for (var i = 0; i < 10; i++) {
        await writer.writeFrom(chunk);
      }
      await writer.flush();
    } finally {
      await writer.close();
    }
    final items = <InformationItem>[];
    Future<InformationItem> save(
      String name, {
      InformationItem? previous,
    }) async {
      final owner = service!.owner;
      final draft = await owner.beginInformationFileDraft();
      try {
        final stage = await owner.stageInformationFile(draft, file.path);
        return await owner.commitInformationDraft(
          draft,
          'save',
          InformationDraftInput(
            name: name,
            description: 'Synthetic capacity fixture',
            itemId: previous?.id,
            baseVersion: previous?.version,
            fields: [
              InformationDraftField.stagedFile(
                'Document',
                '',
                stage.id,
                fieldId: previous?.fields.single.id,
              ),
            ],
          ),
        );
      } finally {
        await owner.releaseInformationFileDraft(draft);
      }
    }

    for (var i = 0; i < 9; i++) {
      items.add(await save('Synthetic $i'));
    }
    final changed = await file.open(mode: FileMode.write);
    try {
      final chunk = Uint8List(1024 * 1024);
      for (var i = 0; i < 10; i++) {
        chunk[0] = i == 0 ? 1 : 0;
        await changed.writeFrom(chunk);
      }
      await changed.flush();
    } finally {
      await changed.close();
    }
    final attachmentIds = {
      for (final item in items) item.fields.single.attachment!.attachmentId,
    };
    items[0] = await save(items[0].name, previous: items[0]);
    await require(
      attachmentIds.contains(items[0].fields.single.attachment!.attachmentId) &&
          items[0].fields.single.attachment!.attachmentVersion == 2,
      'Replacement lost immutable version lineage',
    );
    await service.owner.deleteInformation(items.last.id, items.last.version);
    items.removeLast();
    final versions = [
      for (final id in attachmentIds)
        ...await source.informationAttachmentVersions(id),
    ];
    await require(
      versions.length == 10 &&
          versions.fold<int>(0, (n, v) => n + v.byteLength) ==
              100 * 1024 * 1024,
      'Original body budget not100MiB',
    );
    await require(
      source.informationRevisions.isNotEmpty &&
          source.recycleEntries.isNotEmpty,
      'Missing retained or recycled fixture',
    );
    if (dense) {
      final db = database('${root.path}/source/library.db', 61);
      try {
        db.execute('BEGIN');
        final fields = [
          for (var i = 0; i < 200; i++)
            RecordedField('dense-item', 'dense-field-$i', 'I', 'F'),
        ];
        for (var i = 0; i < 2499; i++) {
          final record = GrantHistory(
            id: 'dense-grant-$i',
            requestId: 'dense-request-$i',
            sessionId: 'dense-history',
            chatLabel: 'Synthetic history',
            approvedAt: now.subtract(const Duration(days: 1)),
            expiresAt: now.subtract(const Duration(hours: 16)),
            fields: fields,
            events: [
              GrantEvent(
                GrantEventKind.approved,
                now.subtract(const Duration(days: 1)),
              ),
            ],
            restoredAt: now,
          );
          db.execute(
            'INSERT INTO grant_history(id,approved_at,payload) VALUES(?,?,?)',
            [
              record.id,
              record.approvedAt.millisecondsSinceEpoch,
              jsonEncode(record.toJson()),
            ],
          );
        }
        db.execute('COMMIT');
      } finally {
        db.close();
      }
      await service.close();
      service = null;
      await source.close();
      source = null;
      source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        sourceKeys,
        clock: () => now,
      );
      service = InformationService(
        repository: source,
        clock: () => now,
        informationDeliveryFiles: WindowsInformationDeliveryFiles(),
      );
      await require(
        source.grantHistory.length == 2499,
        'Dense history was not loaded',
      );
    }
    sample('originals-retention-recycle');
    final session = service.agent.openSession('Synthetic capacity profile');
    final fields = [
      for (final item in items) FieldRef(item.id, item.fields.single.id),
    ];
    final request = service.agent.request(
      session,
      'Verify actual100MiB copies',
      fields,
    );
    service.owner.approve(request.id, fields);
    await service.owner.retryAuditStorage();
    for (var i = 0; i < 10; i++) {
      final item = items[i % items.length];
      final reply = await service.agent.fetchInformationFile(
        session,
        InformationFileFetchInput.fromJson({
          'protocolVersion': 2,
          'command': 'file-fetch',
          'requestId': request.id,
          'itemId': item.id,
          'fieldId': item.fields.single.id,
          'operationId': 'copy-$i',
        }),
      );
      copies.add((reply['delivery'] as Map)['path'] as String);
    }
    try {
      final item = items.first;
      await service.agent.fetchInformationFile(
        session,
        InformationFileFetchInput.fromJson({
          'protocolVersion': 2,
          'command': 'file-fetch',
          'requestId': request.id,
          'itemId': item.id,
          'fieldId': item.fields.single.id,
          'operationId': 'over-byte-budget',
        }),
      );
      throw StateError('Copy byte cap accepted too much');
    } on InformationFileFailure catch (error) {
      await require(
        error.code == 'delivery_capacity' && !error.operationClaimed,
        'Unexpected copy quota outcome',
      );
    }
    await require(
      source.informationFileDeliveries.length == 10,
      'Copy quota created extra receipt',
    );
    sample('ten100MiB-native-copies');
    InformationItem? text;
    if (near) {
      final value = 'x' * 999990;
      text = await service.owner
          .createInformation('Synthetic near-limit text', '', [
            for (var i = 0; i < 66; i++)
              FieldInput('Field$i', '', '${'$i'.padLeft(10, '0')}$value'),
            FieldInput('Extra', '', 'x' * 100000),
            const FieldInput('Padding', '', ''),
          ]);
    }
    final key = await source.backups.enable();
    await source.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
    final before = '${root.path}/before.aimbackup';
    await source.backups.exportTo(before);
    if (dense) {
      var remaining =
          AttachmentBackupContainer.maxPayloadBytes -
          await payloadSize(before, key) -
          65536;
      await require(remaining > 0, 'Dense metadata already exceeds budget');
      final fields = <FieldInput>[];
      while (remaining > 0) {
        final size = remaining > 1000000 ? 1000000 : remaining;
        fields.add(
          FieldInput(
            'Dense text${fields.length}',
            '',
            size < 10
                ? 'x' * size
                : '${'${fields.length}'.padLeft(10, '0')}${'x' * (size - 10)}',
          ),
        );
        remaining -= size;
      }
      await service.owner.createInformation('Synthetic dense text', '', fields);
      await source.writeSetting('auditRetentionDays', 90);
    } else if (near) {
      final originalSize = await payloadSize(before, key);
      final padding =
          AttachmentBackupContainer.maxPayloadBytes - originalSize - 65536;
      await require(
        padding > 0 && padding <= 1000000,
        'Unexpected near-limit padding',
      );
      final db = database('${root.path}/source/library.db', 61);
      try {
        db.execute('UPDATE information_fields SET value=? WHERE id=?', [
          'p' * padding,
          text!.fields.last.id,
        ]);
      } finally {
        db.close();
      }
      // Verify the adjusted fixture is admitted by an actual production writer.
      await source.writeSetting('auditRetentionDays', 90);
    }
    sample('metadata-admitted');
    final backup = '${root.path}/complete.aimbackup';
    final exportWatch = Stopwatch()..start();
    await source.backups.exportTo(backup);
    final exportMs = exportWatch.elapsedMilliseconds;
    final metadataBytes = await payloadSize(backup, key);
    sample('full-export-verified');
    target = await EncryptedInformationRepository.open(
      '${root.path}/recipient',
      targetKeys,
      clock: () => now,
    );
    recipient = InformationService(
      repository: target,
      clock: () => now,
      informationDeliveryFiles: WindowsInformationDeliveryFiles(),
    );
    final restoreWatch = Stopwatch()..start();
    final preview = await target.backups.inspect(backup, key);
    await require(
      preview.attachmentBytes == 100 * 1024 * 1024 &&
          preview.fileDeliveryCount == 10,
      'Preview incomplete',
    );
    await target.backups.restore(preview);
    final restoreMs = restoreWatch.elapsedMilliseconds;
    sample('atomic-restore');
    var verifiedBytes = 0;
    for (final version in [
      for (final id in attachmentIds)
        ...await target.informationAttachmentVersions(id),
    ]) {
      var length = 0;
      await target.withInformationAttachment(version.reference, (
        actual,
        chunks,
      ) async {
        await for (final chunk in chunks) {
          for (var i = 0; i < chunk.length; i++) {
            final expected =
                version.reference.attachmentVersion == 2 && length + i == 0
                ? 1
                : 0;
            if (chunk[i] != expected)
              throw StateError('Restored original bytes changed');
          }
          length += chunk.length;
        }
      });
      await require(length == 10 * 1024 * 1024, 'Truncated version');
      verifiedBytes += length;
    }
    await require(
      verifiedBytes == 100 * 1024 * 1024,
      'Not every retained original verified',
    );
    await require(
      target.informationFileDeliveries.every(
        (r) => !r.runtime && r.lease == null,
      ),
      'Restore revived delivery authority',
    );
    await require(
      target.grantHistory.every((g) => !g.active),
      'Restore revived grants',
    );
    for (final path in copies) {
      await require(await File(path).exists(), 'Restore touched source copy');
    }
    for (final record in source.informationFileDeliveries.toList()) {
      await service.agent.releaseInformationFile(session, record.id);
    }
    for (final path in copies) {
      await require(!await File(path).exists(), 'Released copy retained');
    }
    sample('all-versions-checked-copies-released');
    result = {
      'scenario': args.single,
      'execution':
          RegExp(
            r'dart(vm)?\.exe$',
          ).hasMatch(Platform.resolvedExecutable.toLowerCase())
          ? 'JIT'
          : 'AOT bundle',
      'dart': Platform.version.split('\n').first,
      'baselineRss': initialRss,
      'metadataBytes': metadataBytes,
      'originalBytes': verifiedBytes,
      'managedCopyBytes': 100 * 1024 * 1024,
      'backupFileBytes': await File(backup).length(),
      'exportAndVerifyMs': exportMs,
      'inspectAndRestoreMs': restoreMs,
      'allVersionsExact': true,
      'restoredFactsOnly': true,
      'historicalGrants': dense ? 2499 : 0,
      'measurements': measurements,
      'maxRss': ProcessInfo.maxRss,
      'totalMs': watch.elapsedMilliseconds,
    };
  } finally {
    final registered = [
      ...copies,
      if (service != null)
        for (final record in service.owner.informationFileDeliveries)
          if (record.lease != null) record.lease!.filePath,
    ];
    await recipient?.close();
    await service?.close();
    final stillHeld = <String>[];
    for (final path in registered.toSet()) {
      if (await File(path).exists()) stillHeld.add(path);
    }
    await target?.close();
    await source?.close();
    // Never lose a registry when a known copy could not be reclaimed.
    if (stillHeld.isEmpty) {
      for (final dir in ['source', 'recipient']) {
        final folder = Directory('${root.path}/$dir');
        if (await folder.exists()) {
          for (final entry in folder.listSync(followLinks: false)) {
            if (entry is! File)
              throw StateError('Unexpected synthetic fixture member');
            await entry.delete();
          }
          await folder.delete();
        }
      }
      for (final entry in root.listSync(followLinks: false)) {
        if (entry is! File)
          throw StateError('Unexpected synthetic fixture directory');
        await entry.delete();
      }
      await root.delete();
      removed = true;
    }
  }
  sample('closed-and-cleaned');
  result = {
    ...result,
    'maxRss': ProcessInfo.maxRss,
    'postCloseRss': ProcessInfo.currentRss,
    'totalMs': watch.elapsedMilliseconds,
  };
  stdout.writeln(
    jsonEncode({'result': result, 'temporaryOutputRemoved': removed}),
  );
}
