// Signed Flutter crash/retry probe. All keys and records are synthetic.
// Does not claim native picker, Keychain or Windows migration coverage.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void _check(bool value, String message) {
  if (!value) throw StateError(message);
}

class _SourceKeys implements DatabaseKeyStore {
  List<int>? value = List.filled(32, 118);
  @override
  Future<List<int>?> read() async => value == null ? null : List.of(value!);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Source synthetic key already exists');
}

// Called BEFORE DesktopBootstrap opens the repository. SQLCipher itself must
// recover the interrupted transaction; repository cleanup cannot mask it.
Map<String, Object> checkMacBackupRollback(String root) {
  final db = sql.sqlite3.open('$root/library/library.db');
  try {
    db.execute('PRAGMA key = "x\'${'75' * 32}\'"');
    final cipher = db.select('PRAGMA cipher_version').single.values.single;
    _check(cipher is String && cipher.isNotEmpty, 'SQLCipher unavailable');
    _check(
      db.select('PRAGMA user_version').single.values.single == 21 &&
          db.select('PRAGMA integrity_check').single.values.single == 'ok',
      'Raw schema or integrity failed',
    );
    for (final table in [
      'information_items',
      'information_attachment_versions',
      'information_file_fields',
      'information_file_stages',
    ]) {
      _check(
        db.select('SELECT count(*) AS n FROM $table').single['n'] == 0,
        'Partial restore visible before repository startup',
      );
    }
    return {'rawIntegrity': 'ok', 'rawSchema': 21, 'rawPartialRows': 0};
  } finally {
    db.close();
  }
}

Future<void> runMacBackupRecovery(
  DesktopBootstrap bootstrap,
  EncryptedInformationRepository target,
  String root,
  String mode,
  File report,
  Map<String, Object>? rollback,
) async {
  final format = int.parse(Platform.environment['INFO_MAC_BACKUP_FORMAT']!);
  _check(format == 8 || format == 9, 'Unsupported QA format');
  final service = bootstrap.library!.service;
  final privateFile = File('$root/backup-association.json');
  final backup = File('$root/中文 完整备份.aimbackup');
  const fileBytes = 8 * 1024 * 1024;
  if (mode == 'backup-prepare') {
    await service.owner.setRequestLifetime(const Duration(minutes: 17));
    final keys = _SourceKeys();
    final source = await EncryptedInformationRepository.open(
      '$root/source',
      keys,
    );
    final sourceService = InformationService(
      repository: source,
      informationDeliveryFiles: NativeInformationDeliveryFiles(),
    );
    late Map<String, Object?> association;
    try {
      final items = <InformationItem>[];
      for (var index = 1; index <= 10; index++) {
        final input = File('$root/合成附件 $index.bin');
        await input.writeAsBytes(
          Uint8List(fileBytes)..fillRange(0, fileBytes, index),
        );
        final draft = await sourceService.owner.beginInformationFileDraft();
        try {
          final stage = await sourceService.owner.stageInformationFile(
            draft,
            input.path,
          );
          items.add(
            await sourceService.owner.commitInformationDraft(
              draft,
              'backup-fixture-$index',
              InformationDraftInput(
                name: '合成附件 $index',
                description: '',
                fields: [InformationDraftField.stagedFile('原文', '', stage.id)],
              ),
            ),
          );
        } finally {
          await sourceService.owner.releaseInformationFileDraft(draft);
          await input.delete();
        }
      }
      final text = await sourceService.owner.createInformation('版本与回收', '', [
        const FieldInput('正文', '', 'synthetic before'),
        const FieldInput('待回收', '', 'synthetic recycle'),
      ]);
      final ref = FieldRef(text.id, text.fields.first.id);
      await sourceService.owner.correctValue(ref, 'synthetic after');
      await sourceService.owner.deleteInformation(
        text.id,
        2,
        fieldId: text.fields.last.id,
      );
      await sourceService.owner.createFileCredential(
        name: '合成凭据',
        publicPurpose: '',
        fileName: 'synthetic.key',
        bytes: [0, 128, 255, 10],
      );
      await sourceService.owner.setRequestLifetime(const Duration(minutes: 23));
      final session = sourceService.agent.openSession('合成源会话');
      final fileRef = FieldRef(items.first.id, items.first.fields.single.id);
      final request = sourceService.agent.request(session, '读取', [
        ref,
        fileRef,
      ]);
      sourceService.owner.approve(request.id, [ref, fileRef]);
      final token = sourceService.agent.claim(session, request.id).token;
      await sourceService.agent.read(token, ref);
      sourceService.agent.request(session, '不得恢复', [ref]);
      if (format == 9) {
        await sourceService.agent.fetchInformationFile(
          session,
          InformationFileFetchInput.fromJson({
            'protocolVersion': 2,
            'command': 'file-fetch',
            'requestId': request.id,
            'itemId': fileRef.itemId,
            'fieldId': fileRef.fieldId,
            'operationId': 'before-backup',
          }),
        );
      }
      final recovery = await source.backups.enable();
      await source.backups.saveRecoveryKeyTo('$root/合成恢复密钥.txt');
      await sourceService.owner.exportLibrary(
        () => source.backups.exportTo(backup.path),
      );
      association = {
        'recovery': recovery,
        'token': token,
        'session': session,
        'textItem': ref.itemId,
        'textField': ref.fieldId,
        'fileIds': items.map((i) => i.id).toList(),
      };
    } finally {
      await sourceService.close();
      await source.close();
      keys.value!.fillRange(0, 32, 0);
      keys.value = null;
    }
    await privateFile.writeAsString(jsonEncode(association), flush: true);
    _check(
      (await Process.run('/bin/chmod', ['600', privateFile.path])).exitCode ==
          0,
      'Private fixture permissions unavailable',
    );
    await report.writeAsString(
      jsonEncode({
        'mode': mode,
        'format': format,
        'phase': 'prepared',
        'sourceClosedAndKeyCleared': true,
        'distinctTargetKey': true,
        'attachmentBytes': 80 * 1024 * 1024,
      }),
      flush: true,
    );
    await bootstrap.runtime!.quit();
    return;
  }
  final association = jsonDecode(await privateFile.readAsString()) as Map;
  final preview = await target.backups.inspect(
    backup.path,
    association['recovery'] as String,
  );
  _check(
    preview.formatVersion == format &&
        preview.attachmentCount == 10 &&
        preview.attachmentBytes == 80 * 1024 * 1024,
    'Backup preview mismatch',
  );
  _check(
    service.owner.information.isEmpty &&
        service.owner.requestLifetime == const Duration(minutes: 17) &&
        target.informationRevisions.isEmpty &&
        target.recycleEntries.isEmpty &&
        target.grantHistory.isEmpty &&
        target.accessRecords.isEmpty &&
        target.informationFileDeliveries.isEmpty,
    'Target baseline was changed',
  );
  if (mode == 'backup-interrupt') {
    await report.writeAsString(
      jsonEncode({
        'mode': mode,
        'format': format,
        'phase': 'ready',
        'pid': pid,
        'baselineBytes': await File('$root/library/library.db').length(),
      }),
      flush: true,
    );
    final gate = File('$root/begin-backup-restore');
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (!await gate.exists()) {
      _check(DateTime.now().isBefore(deadline), 'Restore gate deadline');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await service.owner.restoreLibrary(() => target.backups.restore(preview));
    throw StateError('Restore completed before deliberate interruption');
  }
  _check(
    mode == 'backup-recover' && rollback != null,
    'Raw rollback inspection missing',
  );
  await service.owner.restoreLibrary(() => target.backups.restore(preview));
  _check(
    service.owner.information.length == 11 &&
        service.owner.requestLifetime == const Duration(minutes: 23) &&
        target.informationRevisions.length == 2 &&
        target.recycleEntries.length == 1 &&
        target.credentialMaterials.single.bytes.join(',') == '0,128,255,10' &&
        target.grantHistory.every((record) => !record.active) &&
        service.owner.requests.isEmpty &&
        target.accessRecords.single.outcome == AccessOutcome.allowed,
    'Restored content or historical authority mismatch',
  );
  var oldReadDenied = false;
  try {
    await service.agent.read(
      association['token'] as String,
      FieldRef(
        association['textItem'] as String,
        association['textField'] as String,
      ),
    );
  } on AccessFailure {
    oldReadDenied = true;
  }
  _check(oldReadDenied, 'Old authorization revived');
  if (format == 9) {
    final fact = target.informationFileDeliveries.single;
    _check(
      !fact.runtime && fact.lease == null && fact.sessionBinding == null,
      'Runtime file lease revived',
    );
    var oldStatusDenied = false;
    try {
      await service.agent.informationFileStatus(
        association['session'] as String,
        fact.id,
      );
    } on InformationFileFailure {
      oldStatusDenied = true;
    }
    _check(oldStatusDenied, 'Old file association revived');
  }
  final ids = (association['fileIds'] as List).cast<String>();
  for (var index = 0; index < ids.length; index++) {
    final item = service.owner.information.singleWhere(
      (i) => i.id == ids[index],
    );
    final attachment = item.fields.single.attachment!;
    for (var offset = 0; offset < fileBytes; offset += 1024 * 1024) {
      final bytes = await target.readInformationAttachmentChunk(
        attachment,
        offset,
        1024 * 1024,
      );
      _check(
        bytes.length == 1024 * 1024 && bytes.every((b) => b == index + 1),
        'Attachment bytes changed',
      );
    }
  }
  await report.writeAsString(
    jsonEncode({
      'mode': mode,
      'format': format,
      'phase': 'complete',
      ...rollback!,
      'sameTargetRetry': true,
      'verifiedAttachmentBytes': 80 * 1024 * 1024,
      'oldAuthorizationDenied': true,
      'runtimeFileLeasesRestored': false,
      'targetBaselinePreservedBeforeRetry': true,
    }),
    flush: true,
  );
  await bootstrap.runtime!.quit();
}
