// Owns fake values only in memory, encrypted DB and the receiver's private pipe.
// Never emit fake secrets, key bytes, session proofs or plaintext backup keys.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2)
    throw StateError('Explicit fixture root/receiver required');
  final root = Directory(args[0]);
  final actual = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
      !actual.toLowerCase().startsWith(
        '$temp${Platform.pathSeparator}'.toLowerCase(),
      ) ||
      !root.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('aim-packaged-joint-') ||
      !await root.list().isEmpty) {
    throw StateError('Not a new owned synthetic fixture');
  }
  final random = Random.secure();
  String nonce() =>
      base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
  final ghSecret = 'ghp_synthetic_${nonce()}';
  final fillSecret = '  A1b2C3d4${nonce()}中文🧭  ';
  bool clean(String text) => [ghSecret, fillSecret].every(
    (s) =>
        !text.contains(s) &&
        !text.contains(jsonEncode(s).substring(1, jsonEncode(s).length - 1)),
  );
  void emit(Map<String, Object?> value) {
    final text = jsonEncode(value);
    if (!clean(text))
      throw StateError('Synthetic secret escaped a private pipe');
    stdout.writeln(text);
  }

  Process? receiver;
  StreamIterator<String>? receiverLines;
  Future<Map<String, dynamic>> reply() async {
    if (!await receiverLines!.moveNext().timeout(const Duration(seconds: 5))) {
      throw StateError('Synthetic receiver ended');
    }
    final text = receiverLines!.current;
    if (!clean(text)) throw StateError('Synthetic receiver exposed fake bytes');
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> receiverFrame(int opcode) async {
    final body = Uint8List(
      opcode == 1 ? 1 + fillSecret.codeUnits.length * 2 : 1,
    )..[0] = opcode;
    final view = ByteData.sublistView(body);
    if (opcode == 1) {
      for (var i = 0; i < fillSecret.codeUnits.length; i++) {
        view.setUint16(1 + i * 2, fillSecret.codeUnits[i], Endian.little);
      }
    }
    final header = Uint8List(4);
    ByteData.sublistView(header).setUint32(0, body.length, Endian.little);
    receiver!.stdin.add(header);
    receiver!.stdin.add(body);
    await receiver!.stdin.flush();
    body.fillRange(0, body.length, 0);
  }

  Future<void> closeReceiver() async {
    final active = receiver;
    if (active == null) return;
    await active.stdin.close();
    if (await active.exitCode.timeout(const Duration(seconds: 6)) != 0) {
      throw StateError('Synthetic receiver did not close normally');
    }
    await receiverLines?.cancel();
    receiver = null;
    receiverLines = null;
  }

  final source = '${root.path}/source/AgentInfoManage';
  final repository = await EncryptedInformationRepository.open(
    source,
    WindowsDatabaseKeyStore('$source/database-key.dpapi'),
  );
  final service = InformationService(
    repository: repository,
    informationDeliveryFiles: WindowsInformationDeliveryFiles(),
  );
  final original = utf8.encode('虚构简历原始版本，不是真实个人资料。');
  final replacement = utf8.encode('虚构简历第二版，原始版本仍在修改历史中。');
  late InformationItem document;
  late InformationAttachmentRef oldAttachment, currentAttachment;
  final ids = <String, String>{};
  try {
    await service.owner.setNotificationsEnabled(false);
    for (final entry in {'gh': ghSecret, 'fill': fillSecret}.entries) {
      var credential = await service.owner.createStringCredential(
        name: entry.key == 'gh' ? '合成 GitHub Token' : '本机填充测试密码',
        publicPurpose: '自动生成的假凭据，仅用于整包验收',
        secret: entry.value,
        suggestedBinding: entry.key == 'gh' ? 'GH_TOKEN' : 'PORTAL_PASSWORD',
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: credential.suggestedBinding,
        discoverable: true,
      );
      ids[entry.key] = credential.id;
    }
    Future<InformationItem> save(
      List<int> bytes, [
      InformationItem? before,
    ]) async {
      final input = File('${root.path}/synthetic-resume.txt');
      await input.writeAsBytes(bytes);
      final draft = await service.owner.beginInformationFileDraft();
      final stage = await service.owner.stageInformationFile(draft, input.path);
      final saved = await service.owner.commitInformationDraft(
        draft,
        before == null ? 'joint-v1' : 'joint-v2',
        InformationDraftInput(
          name: '整包虚构简历',
          description: '两份保留原文及交付历史',
          itemId: before?.id,
          baseVersion: before?.version,
          fields: [
            InformationDraftField.stagedFile(
              '简历文件',
              '',
              stage.id,
              fieldId: before?.fields.single.id,
            ),
          ],
        ),
      );
      await service.owner.releaseInformationFileDraft(draft);
      return saved;
    }

    final first = await save(original);
    oldAttachment = first.fields.single.attachment!;
    document = await save(replacement, first);
    currentAttachment = document.fields.single.attachment!;
    // Seed a released past delivery so the real UI exports format9. This setup
    // is separate from command/fill operations performed by the actual package.
    final session = service.agent.openSession('合成附件历史准备');
    final ref = FieldRef(document.id, document.fields.single.id);
    final request = service.agent.request(session, '合成附件历史', [ref]);
    service.owner.approve(request.id, [ref]);
    final delivered = await service.agent.fetchInformationFile(
      session,
      InformationFileFetchInput.fromJson({
        'protocolVersion': 2,
        'command': 'file-fetch',
        'requestId': request.id,
        'itemId': ref.itemId,
        'fieldId': ref.fieldId,
        'operationId': 'seed-released-file',
      }),
    );
    final delivery = delivered['delivery'] as Map;
    await service.agent.releaseInformationFile(
      session,
      delivery['deliveryId'] as String,
    );
    // Pre-save this next run's dummy backup key. The actual package still
    // exports/restores the backup through native dialogs. Its key-generation
    // and key-save dialogs were exercised separately in run-02.
    await repository.backups.enable();
    await repository.backups.saveRecoveryKeyTo(
      '${root.path}/current9.recovery.txt',
    );
    await File('${root.path}/expected-hashes.json').writeAsString(
      jsonEncode({
        'credentialHashes': {
          ids['gh']!: sha256.convert(utf8.encode(ghSecret)).toString(),
          ids['fill']!: sha256.convert(utf8.encode(fillSecret)).toString(),
        },
        'oldAttachment': oldAttachment.toJson(),
        'currentAttachment': currentAttachment.toJson(),
      }),
    );
  } finally {
    await service.close();
    await repository.close();
  }
  emit({
    'status': 'prepared',
    'credentials': ids,
    'documentId': document.id,
    'fieldId': document.fields.single.id,
  });
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final input = jsonDecode(line) as Map<String, dynamic>;
      switch (input['action']) {
        case 'scan':
          emit({'status': 'scanned', 'clean': clean(input['text'] as String)});
        case 'receiver-start':
          receiver = await Process.start(args[1], []);
          unawaited(receiver!.stderr.drain<void>());
          receiverLines = StreamIterator(
            receiver!.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter()),
          );
          if ((await reply())['event'] != 'window_ready')
            throw StateError('Receiver not ready');
          await receiverFrame(1);
          if ((await reply())['event'] != 'expected_ready')
            throw StateError('No expected value receipt');
          emit({'status': 'receiver_ready', 'processId': receiver!.pid});
        case 'receiver-verify':
          await receiverFrame(2);
          emit(await reply());
        case 'receiver-close':
          await closeReceiver();
          emit({'status': 'receiver_closed'});
        case 'backup-inspect':
          final repo = await EncryptedInformationRepository.open(
            source,
            WindowsDatabaseKeyStore('$source/database-key.dpapi'),
          );
          try {
            final key = (await File(
              '${root.path}/current9.recovery.txt',
            ).readAsString()).trim();
            final preview = await repo.backups.inspect(
              '${root.path}/current9.aimbackup',
              key,
            );
            emit({
              'status': 'backup_inspected',
              'format': preview.formatVersion,
              'information': preview.informationCount,
              'credentials': preview.credentialCount,
              'attachments': preview.attachmentCount,
              'currentAttachments': preview.currentAttachmentCount,
              'fileDeliveries': preview.fileDeliveryCount,
              'credentialUseFacts': preview.credentialUseHistoryCount,
              'executionFacts': preview.credentialExecutionCount,
              'fillFacts': preview.focusedFillCount,
            });
          } finally {
            await repo.close();
          }
        case 'inspect':
          if (!{'source', 'restored'}.contains(input['profile']))
            throw StateError('Invalid profile');
          final directory = '${root.path}/${input['profile']}/AgentInfoManage';
          final repo = await EncryptedInformationRepository.open(
            directory,
            WindowsDatabaseKeyStore('$directory/database-key.dpapi'),
          );
          try {
            final bytes1 = await repo.readInformationAttachmentChunk(
              oldAttachment,
              0,
              original.length,
            );
            final bytes2 = await repo.readInformationAttachmentChunk(
              currentAttachment,
              0,
              replacement.length,
            );
            bool equal(List<int> a, List<int> b) =>
                a.length == b.length &&
                List.generate(a.length, (i) => a[i] == b[i]).every((e) => e);
            final materials = {
              for (final m in repo.credentialMaterials)
                m.credentialId: utf8.decode(m.bytes),
            };
            emit({
              'status': 'inspected',
              'originalMatches': equal(bytes1, original),
              'currentMatches': equal(bytes2, replacement),
              'credentialBytesMatch':
                  materials[ids['gh']] == ghSecret &&
                  materials[ids['fill']] == fillSecret,
              'credentialRequests': repo.credentialUseRequests.length,
              'executions': repo.credentialExecutions.length,
              'executionsExitedOne': repo.credentialExecutions.every(
                (e) => e.state == 'exited' && e.exitCode == 1,
              ),
              'fills': repo.focusedFillOperations.length,
              'fillsSent': repo.focusedFillOperations.every(
                (f) => f.state == FocusedFillState.sent,
              ),
              'fileDeliveries': repo.informationFileDeliveries.length,
              'noHeldCopies': repo.informationFileDeliveries.every(
                (d) => !d.holdsCopy,
              ),
              'requestsArchived': repo.credentialUseRequests.every(
                (q) => q.restoredAt != null,
              ),
              'executionsArchived': repo.credentialExecutions.every(
                (e) => e.restoredAt != null,
              ),
              'fillsArchived': repo.focusedFillOperations.every(
                (f) => f.restoredAt != null,
              ),
            });
          } finally {
            await repo.close();
          }
        case 'close':
          return;
        default:
          throw StateError('Invalid fixture action');
      }
    }
  } finally {
    await closeReceiver();
  }
}
