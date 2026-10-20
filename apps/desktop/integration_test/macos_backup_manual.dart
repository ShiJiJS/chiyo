// Ordinary Flutter binding + actual native file panels, operated with CUA.
// Synthetic libraries/keys only; never opens production library or Keychain.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/backups.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

class _Panels extends NativeBackupFilePicker {
  String? savedKey, exported;
  final events = <Map<String, Object?>>[];
  void event(String kind, [Object? value]) {
    events.add({'kind': kind, 'value': value});
    stdout.writeln('MAC_BACKUP_PANEL=${jsonEncode(events.last)}');
  }

  @override
  Future<String?> recoveryKeyOutput() async {
    final path = await super.recoveryKeyOutput();
    event('recoveryKeyOutput', path);
    if (path != null) savedKey = path;
    return path;
  }

  @override
  Future<String?> backupOutput() async {
    final path = await super.backupOutput();
    event('backupOutput', path);
    if (path != null) exported = path;
    return path;
  }

  @override
  Future<String?> backupInput() async {
    final path = await super.backupInput();
    event('backupInput', path);
    return path;
  }

  @override
  Future<String?> recoveryKeyInput() async {
    final path = await super.recoveryKeyInput();
    event('recoveryKeyInput', path);
    return path;
  }

  @override
  Future<BackupStaging?> prepareStaging(String output) async {
    final staging = await super.prepareStaging(output);
    event('stagingPrepared', staging?.directory);
    return staging;
  }

  @override
  Future<void> releaseStaging(BackupStaging staging) async {
    await super.releaseStaging(staging);
    final removed = !await Directory(staging.directory).exists();
    event('stagingRemoved', removed);
    if (!removed) throw StateError('Native staging remained');
  }
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> until(FutureOr<bool> Function() done, String phase) async {
  stdout.writeln('MAC_BACKUP_PHASE=$phase');
  final deadline = DateTime.now().add(const Duration(minutes: 20));
  while (!await done()) {
    check(DateTime.now().isBefore(deadline), 'Manual phase timed out');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isMacOS) exit(64);
  final root = await Directory.systemTemp.createTemp('aim-mac-backup-panel-');
  stdout.writeln('MAC_BACKUP_ROOT=${root.path}');
  final sourceKeys = _Keys(), targetKeys = _Keys(), panels = _Panels();
  var repository = await EncryptedInformationRepository.open(
    '${root.path}/source',
    sourceKeys,
  );
  var service = InformationService(
    repository: repository,
    informationDeliveryFiles: NativeInformationDeliveryFiles(),
  );
  var completed = false;
  try {
    final item = await service.owner.createInformation('面板合成资料', '', [
      const FieldInput('正文', '', 'synthetic before'),
    ]);
    final ref = FieldRef(item.id, item.fields.single.id);
    await service.owner.correctValue(ref, 'synthetic after');
    await service.owner.createFileCredential(
      name: '合成凭据',
      publicPurpose: '',
      fileName: 'synthetic.key',
      bytes: [0, 128, 255, 10],
    );
    final original = File('${root.path}/synthetic.bin');
    await original.writeAsBytes([0, 255, 1, 2, 3, 10]);
    final draft = await service.owner.beginInformationFileDraft();
    late InformationItem file;
    try {
      final stage = await service.owner.stageInformationFile(
        draft,
        original.path,
      );
      file = await service.owner.commitInformationDraft(
        draft,
        'manual-backup',
        InformationDraftInput(
          name: '面板合成附件',
          description: '',
          fields: [InformationDraftField.stagedFile('原文', '', stage.id)],
        ),
      );
    } finally {
      await service.owner.releaseInformationFileDraft(draft);
    }
    final fileRef = FieldRef(file.id, file.fields.single.id);
    final session = service.agent.openSession('面板合成会话');
    final request = service.agent.request(session, '备份前读取', [ref, fileRef]);
    service.owner.approve(request.id, [ref, fileRef]);
    final token = service.agent.claim(session, request.id).token;
    await service.agent.read(token, ref);
    service.agent.request(session, '不得恢复待审批', [ref]);
    await service.agent.fetchInformationFile(
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
    void show() => runApp(
      InformationApp(
        key: UniqueKey(),
        service: service,
        port: 0,
        backups: repository.backups,
        backupFiles: panels,
      ),
    );
    show();
    await until(
      () => File('${root.path}/switch-to-target').exists(),
      'source-export-through-real-panels',
    );
    check(
      panels.savedKey != null && panels.exported != null,
      'Native save selections missing',
    );
    check(
      await repository.backups.recoveryKeySaved(),
      'Recovery key not saved',
    );
    check(
      panels.events.any(
        (e) => e['kind'] == 'recoveryKeyOutput' && e['value'] == null,
      ),
      'Cancellation not exercised',
    );
    check(
      panels.events.any(
        (e) => e['kind'] == 'stagingRemoved' && e['value'] == true,
      ),
      'Native staging cleanup not observed',
    );
    final recovery = await repository.backups.readRecoveryKeyFrom(
      panels.savedKey!,
    );
    final preview = await repository.backups.inspect(
      panels.exported!,
      recovery,
    );
    check(
      preview.formatVersion == 9 && preview.attachmentBytes == 6,
      'Native export mismatch',
    );
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    await service.close();
    await repository.close();
    final sourceKeyBefore = List.of(sourceKeys.value!);
    sourceKeys.value!.fillRange(0, sourceKeys.value!.length, 0);
    sourceKeys.value = null;
    repository = await EncryptedInformationRepository.open(
      '${root.path}/target',
      targetKeys,
    );
    check(
      base64Encode(sourceKeyBefore) != base64Encode(targetKeys.value!),
      'Target reused source key',
    );
    sourceKeyBefore.fillRange(0, sourceKeyBefore.length, 0);
    service = InformationService(
      repository: repository,
      informationDeliveryFiles: NativeInformationDeliveryFiles(),
    );
    show();
    await until(
      () => service.owner.information.length == 2,
      'target-restore-through-real-panels',
    );
    check(
      repository.informationRevisions.length == 1 &&
          repository.credentialMaterials.single.bytes.join(',') ==
              '0,128,255,10' &&
          repository.grantHistory.every((g) => !g.active) &&
          service.owner.requests.isEmpty,
      'Restored contents mismatch',
    );
    var denied = false;
    try {
      await service.agent.read(token, ref);
    } on AccessFailure {
      denied = true;
    }
    check(denied, 'Old token revived');
    check(
      (await repository.readInformationAttachmentChunk(
            file.fields.single.attachment!,
            0,
            6,
          )).join(',') ==
          '0,255,1,2,3,10',
      'Attachment changed',
    );
    final fact = repository.informationFileDeliveries.single;
    check(
      !fact.runtime && fact.lease == null && fact.sessionBinding == null,
      'Live file lease revived',
    );
    final freshSession = service.agent.openSession('恢复后合成会话');
    final fresh = service.agent.request(freshSession, '重新申请', [ref]);
    service.owner.approve(fresh.id, [ref]);
    check(
      await service.agent.read(
            service.agent.claim(freshSession, fresh.id).token,
            ref,
          ) ==
          'synthetic after',
      'Fresh approval failed',
    );
    await File('${root.path}/result.json').writeAsString(
      jsonEncode({
        'complete': true,
        'format': 9,
        'actualNativePanels': true,
        'sourceKeyCleared': true,
        'distinctTargetKey': true,
        'oldAuthorityDenied': true,
        'freshApprovalRead': true,
        'attachmentBytesMatched': true,
        'events': panels.events,
        'scope':
            'ordinary Flutter binding; actual native panels; synthetic keys; not Keychain',
      }),
      flush: true,
    );
    stdout.writeln('MAC_BACKUP_RESULT=PASS');
    await until(
      () => File('${root.path}/finish').exists(),
      'inspect-final-result',
    );
    completed = true;
  } catch (e) {
    stdout.writeln('MAC_BACKUP_FAILED=${e.runtimeType}');
    rethrow;
  } finally {
    runApp(const SizedBox.shrink());
    await service.close();
    await repository.close();
    // The external selected files stay in the named project QA directory.
    if (completed) {
      final base = await Directory.systemTemp.resolveSymbolicLinks();
      final actual = await root.resolveSymbolicLinks();
      check(
        actual.startsWith('$base/aim-mac-backup-panel-'),
        'Foreign temporary root',
      );
      await root.delete(recursive: true);
    }
  }
  exit(0);
}
