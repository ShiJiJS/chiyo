// Real Keychain is supplied by the ordinary Release QA entry. This helper only
// uses production owner/storage APIs and synthetic files in its owned root.
// Recovery files and private comparisons never leave that root.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

List<Map<String, Object?>> _sorted(Iterable<Map<String, Object?>> values) =>
    values.toList()..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));

Map<String, Object?> _contents(
  InformationService service,
  EncryptedInformationRepository repository,
) => {
  'information': _sorted(service.owner.information.map(informationToJson)),
  'directories': _sorted(
    service.owner.directories.map(
      (d) => {
        'id': d.id,
        'name': d.name,
        'parent': d.parentId,
        'version': d.version,
      },
    ),
  ),
  'tags': _sorted(
    service.owner.tags.map(
      (t) => {'id': t.id, 'name': t.name, 'version': t.version},
    ),
  ),
  'templates': _sorted(
    service.owner.templates.map(
      (t) => {
        'id': t.id,
        'name': t.name,
        'description': t.description,
        'version': t.version,
        'fields': [
          for (final f in t.fields)
            {
              'id': f.id,
              'name': f.name,
              'description': f.description,
              'kind': f.kind.name,
            },
        ],
      },
    ),
  ),
  'versions': _sorted(
    repository.informationRevisions.map(
      (r) => {
        'item': informationToJson(r.item),
        'replacedAt': r.replacedAt.toUtc().toIso8601String(),
      },
    ),
  ),
  'recycle': _sorted(repository.recycleEntries.map((r) => r.toJson())),
  'credentials': _sorted(
    service.owner.credentials.map(
      (c) => {
        'id': c.id,
        'name': c.name,
        'form': c.form.name,
        'version': c.version,
        'enabled': c.enabled,
        'linked': c.linkedItemIds.toList()..sort(),
      },
    ),
  ),
  'materials': _sorted(
    repository.credentialMaterials.map(
      (m) => {
        'id': m.credentialId,
        'version': m.version,
        'fileName': m.fileName,
        'bytes': base64Encode(m.bytes),
      },
    ),
  ),
  'requestLifetime': service.owner.requestLifetime.inMilliseconds,
  'theme': service.owner.colorTheme.name,
};

Future<String> _refused(Future<Object?> Function() work) async {
  try {
    await work();
  } on StorageFailure catch (error) {
    return error.code;
  }
  throw StateError('Expected storage refusal');
}

Future<Map<String, Object?>> runMacKeychainBackup(
  DesktopBootstrap bootstrap,
  EncryptedInformationRepository repository,
  DatabaseKeyStore keys,
  String root,
  String mode,
) async {
  final service = bootstrap.library!.service;
  final private = File('$root/backup-private.json');
  final backup = File('$root/中文 完整备份.aimbackup');
  final recoveryFile = File('$root/独立 恢复密钥.txt');
  const fileBytes = 1024 * 1024;
  final facts = <String, Object?>{'backupFormat': 9};
  if (mode == 'backup-export') {
    final text = await service.owner.createInformation('版本与回收', '合成资料', [
      const FieldInput('正文', '', 'before', kind: FieldKind.textNote),
      const FieldInput('待回收', '', 'recycled synthetic value'),
    ]);
    final ref = FieldRef(text.id, text.fields.first.id);
    await service.owner.correctValue(ref, 'after');
    await service.owner.deleteInformation(
      text.id,
      2,
      fieldId: text.fields.last.id,
    );
    final parent = await service.owner.createDirectory('父目录');
    final child = await service.owner.createDirectory(
      '子目录',
      parentId: parent.id,
    );
    final tag = await service.owner.createTag('合成标签');
    await service.owner.organizeInformation(
      text.id,
      directoryId: child.id,
      tagIds: [tag.id],
    );
    await service.owner.createTemplate('合成模板', '保留字段类型', [
      const TemplateFieldInput('正文', '', kind: FieldKind.textNote),
    ]);
    await service.owner.createFileCredential(
      name: '合成文件凭据',
      publicPurpose: '',
      fileName: 'synthetic.key',
      bytes: [0, 128, 255, 10],
    );
    await service.owner.createStringCredential(
      name: '合成字符串凭据',
      publicPurpose: '',
      secret: 'synthetic backup credential',
    );
    await service.owner.setRequestLifetime(const Duration(minutes: 23));
    await service.owner.setColorTheme(DesktopColorTheme.green);
    final fileItems = <InformationItem>[];
    for (var index = 1; index <= 2; index++) {
      final file = File('$root/中文 附件 $index.bin');
      await file.writeAsBytes(
        Uint8List(fileBytes)..fillRange(0, fileBytes, index),
      );
      final draft = await service.owner.beginInformationFileDraft();
      try {
        final stage = await service.owner.stageInformationFile(
          draft,
          file.path,
        );
        fileItems.add(
          await service.owner.commitInformationDraft(
            draft,
            'backup-keychain-$index',
            InformationDraftInput(
              name: '合成附件 $index',
              description: '',
              fields: [InformationDraftField.stagedFile('原文', '', stage.id)],
            ),
          ),
        );
      } finally {
        await service.owner.releaseInformationFileDraft(draft);
        await file.delete();
      }
    }
    final fileRef = FieldRef(
      fileItems.first.id,
      fileItems.first.fields.single.id,
    );
    final session = service.agent.openSession('Keychain 合成源');
    final request = service.agent.request(session, '读取与交付', [ref, fileRef]);
    service.owner.approve(request.id, [ref, fileRef]);
    final token = service.agent.claim(session, request.id).token;
    _check(
      await service.agent.read(token, ref) == 'after',
      'Source read mismatch',
    );
    await service.agent.fetchInformationFile(
      session,
      InformationFileFetchInput.fromJson({
        'protocolVersion': 2,
        'command': 'file-fetch',
        'requestId': request.id,
        'itemId': fileRef.itemId,
        'fieldId': fileRef.fieldId,
        'operationId': 'backup-original',
      }),
    );
    service.agent.request(session, '不得复活待审批', [ref]);
    await service.agent.submitImport(session, [
      ImportItemInput('不得自动入库', '', [
        const FieldInput('正文', '', 'unconfirmed'),
      ]),
    ]);
    final recovery = await repository.backups.enable();
    final localKey = (await keys.read())!;
    _check(
      !listEquals(
        localKey,
        base64Url.decode(recovery.substring('aim-recovery-v1:'.length)),
      ),
      'Recovery key reused the local key',
    );
    localKey.fillRange(0, localKey.length, 0);
    await repository.backups.saveRecoveryKeyTo(recoveryFile.path);
    _check(
      await repository.backups.recoveryKeySaved(),
      'Recovery file was not saved',
    );
    await service.owner.exportLibrary(
      () => repository.backups.exportTo(backup.path),
    );
    final exported = await backup.readAsBytes();
    final duplicate = await _refused(
      () => repository.backups.exportTo(backup.path),
    );
    _check(
      duplicate == 'output_exists' &&
          listEquals(exported, await backup.readAsBytes()),
      'Duplicate output overwrote original backup',
    );
    final preview = await repository.backups.inspect(backup.path, recovery);
    _check(
      preview.formatVersion == 9 &&
          preview.attachmentCount == 2 &&
          preview.attachmentBytes == 2 * fileBytes,
      'Backup preview mismatch',
    );
    final association = <String, Object?>{
      'token': token,
      'session': session,
      'item': ref.itemId,
      'field': ref.fieldId,
      'fileItems': fileItems.map((i) => i.id).toList(),
      'fileHistory': repository.informationFileDeliveries.single.id,
      'grantIds': repository.grantHistory.map((r) => r.id).toList(),
      'contents': _contents(service, repository),
    };
    await private.writeAsString(jsonEncode(association), flush: true);
    _check(
      (await Process.run('/bin/chmod', [
            '600',
            private.path,
            recoveryFile.path,
          ])).exitCode ==
          0,
      'Private fixture permissions unavailable',
    );
    facts.addAll({
      'exported': true,
      'recoveryKeyIndependent': true,
      'duplicateOutputRefused': true,
      'informationCount': 3,
      'attachmentBytes': 2 * fileBytes,
      'directoryCount': 2,
      'tagCount': 1,
      'templateCount': 1,
      'credentialCount': 2,
    });
    return facts;
  }
  final old = jsonDecode(await private.readAsString()) as Map<String, dynamic>;
  final recovery = await repository.backups.readRecoveryKeyFrom(
    recoveryFile.path,
  );
  final originalBackup = await backup.readAsBytes();
  final localBefore = List<int>.of((await keys.read())!);
  if (mode == 'backup-restore') {
    final oldDb = File('$root/library/library.db');
    final originalSource = await oldDb.readAsBytes();
    final wrongSource = await _refused(() async {
      final accidental = await EncryptedInformationRepository.open(
        '$root/library',
        keys,
      );
      await accidental.close();
      return null;
    });
    _check(
      wrongSource == 'library_unavailable' &&
          listEquals(originalSource, await oldDb.readAsBytes()),
      'Target key opened or changed the old source database',
    );
    facts['newTargetKeyCannotOpenOriginalSource'] = true;
    await service.owner.setRequestLifetime(const Duration(minutes: 17));
    final db = File('$root/restored/library.db');
    final before = await db.readAsBytes();
    final wrong = await _refused(
      () => repository.backups.inspect(
        backup.path,
        'aim-recovery-v1:${base64Url.encode(List.filled(32, 7))}',
      ),
    );
    final damaged = File('$root/损坏 备份.aimbackup');
    final badBytes = List<int>.of(originalBackup);
    badBytes[0] ^= 0xff;
    await damaged.writeAsBytes(badBytes, flush: true);
    final corrupt = await _refused(
      () => repository.backups.inspect(damaged.path, recovery),
    );
    _check(
      service.owner.information.isEmpty &&
          service.owner.credentials.isEmpty &&
          service.owner.requestLifetime == const Duration(minutes: 17) &&
          listEquals(before, await db.readAsBytes()),
      'Rejected backup changed target',
    );
    await damaged.delete();
    final preview = await repository.backups.inspect(backup.path, recovery);
    _check(
      preview.formatVersion == 9 && preview.attachmentBytes == 2 * fileBytes,
      'Target preview mismatch',
    );
    await service.owner.restoreLibrary(
      () => repository.backups.restore(preview),
    );
    facts.addAll({
      'wrongRecoveryKeyRefused': wrong,
      'damagedBackupRefused': corrupt,
      'failedPreflightPreservedTargetBytes': true,
      'sameTargetRetryRestored': true,
    });
  } else {
    _check(mode == 'backup-reopen', 'Unknown backup phase');
  }
  _check(
    jsonEncode(_contents(service, repository)) == jsonEncode(old['contents']),
    'Restored information, organization, templates, versions, recycle, credentials or settings changed',
  );
  _check(
    service.owner.requests.isEmpty && service.owner.importProposals.isEmpty,
    'Pending approval or proposal revived',
  );
  final oldGrantIds = (old['grantIds'] as List).cast<String>().toSet();
  final historical = repository.grantHistory
      .where((r) => oldGrantIds.contains(r.id))
      .toList();
  _check(
    historical.length == oldGrantIds.length &&
        historical.every((r) => !r.active) &&
        repository.accessRecords.any((r) => r.outcome == AccessOutcome.allowed),
    'Historical facts lost or authority revived',
  );
  final fileHistory = repository.informationFileDeliveries.singleWhere(
    (r) => r.id == old['fileHistory'],
  );
  _check(
    !fileHistory.runtime &&
        fileHistory.lease == null &&
        fileHistory.sessionBinding == null,
    'Live file delivery restored',
  );
  var denied = false;
  final ref = FieldRef(old['item'] as String, old['field'] as String);
  try {
    await service.agent.read(old['token'] as String, ref);
  } on AccessFailure {
    denied = true;
  }
  _check(denied, 'Original source token revived');
  var oldFileDenied = false;
  try {
    await service.agent.informationFileStatus(
      old['session'] as String,
      fileHistory.id,
    );
  } on InformationFileFailure {
    oldFileDenied = true;
  }
  _check(oldFileDenied, 'Original file association revived');
  final ids = (old['fileItems'] as List).cast<String>();
  for (var index = 0; index < ids.length; index++) {
    final attachment = service.owner.information
        .singleWhere((i) => i.id == ids[index])
        .fields
        .single
        .attachment!;
    final bytes = await repository.readInformationAttachmentChunk(
      attachment,
      0,
      fileBytes,
    );
    _check(
      bytes.length == fileBytes && bytes.every((b) => b == index + 1),
      'Attachment bytes differ',
    );
  }
  _check(
    await repository.backups.recoveryKey() == null,
    'Source recovery configuration revived',
  );
  final db = File('$root/restored/library.db');
  final beforeNonempty = await db.readAsBytes();
  final nonempty = await _refused(
    () => repository.backups.restoreFrom(backup.path, recovery),
  );
  _check(
    nonempty == 'recipient_not_empty' &&
        listEquals(beforeNonempty, await db.readAsBytes()),
    'Nonempty target changed',
  );
  final session = service.agent.openSession('恢复后重新申请');
  final request = service.agent.request(session, '重新读取', [ref]);
  service.owner.approve(request.id, [ref]);
  final token = service.agent.claim(session, request.id).token;
  _check(
    await service.agent.read(token, ref) == 'after',
    'Fresh approved access failed',
  );
  _check(
    listEquals(localBefore, await keys.read()) &&
        listEquals(originalBackup, await backup.readAsBytes()),
    'Target local key or original backup changed',
  );
  localBefore.fillRange(0, localBefore.length, 0);
  facts.addAll({
    'contentAndRelationshipsPreserved': true,
    'attachmentBytesVerified': 2 * fileBytes,
    'oldAuthorizationRefused': true,
    'oldFileAssociationRefused': true,
    'pendingRequestsAndProposalsExcluded': true,
    'runtimeFileLeasesRestored': false,
    'nonemptyTargetRefusedAndBytesPreserved': true,
    'freshApprovedReadSucceeded': true,
    'targetKeyUnchanged': true,
    'originalBackupUnchanged': true,
    'sourceRecoveryConfigurationRestored': false,
  });
  return facts;
}
