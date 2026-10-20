import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/backups.dart';

// Signed Flutter/SQLCipher acceptance. Only picker paths and OS key storage are
// controlled: this does not claim NSOpenPanel, NSSavePanel or Keychain coverage.
class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value == null ? null : List.of(value!);
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

class _Files extends BackupFilePicker {
  _Files(this.root);
  final String root;
  bool cancelSave = true;
  String? selectedKey;
  String get recovery => '$root/恢复 密钥.txt';
  String get backup => '$root/完整 备份.aimbackup';
  @override
  Future<String?> recoveryKeyOutput() async => cancelSave ? null : recovery;
  @override
  Future<String?> backupOutput() async => backup;
  @override
  Future<String?> backupInput() async => backup;
  @override
  Future<String?> recoveryKeyInput() async => selectedKey ?? recovery;
}

Future<void> _wait(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  do {
    await tester.pumpAndSettle();
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  } while (DateTime.now().isBefore(deadline));
  expect(finder, findsWidgets);
}

Future<void> _click(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openBackups(
  WidgetTester tester,
  InformationService service,
  EncryptedInformationRepository repository,
  _Files files,
) async {
  await tester.pumpWidget(
    InformationApp(
      key: UniqueKey(),
      service: service,
      port: 0,
      backups: repository.backups,
      backupFiles: files,
    ),
  );
  await tester.pumpAndSettle();
  await _click(tester, find.byKey(const ValueKey('nav-4')));
  await _click(tester, find.byKey(const ValueKey('settings-section-backups')));
  await _wait(tester, find.text('导出加密备份'));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final format in [7, 8, 9]) {
    testWidgets(
      'Mac sandbox backup$format UI exports and restores with a new local key',
      (tester) async {
        expect(Platform.isMacOS, isTrue);
        final root = await Directory.systemTemp.createTemp(
          'aim-mac-native-backup-',
        );
        final sourceKeys = _Keys(),
            targetKeys = _Keys(),
            files = _Files(root.path);
        var repository = await EncryptedInformationRepository.open(
          '${root.path}/来源 库',
          sourceKeys,
        );
        var service = InformationService(
          repository: repository,
          informationDeliveryFiles: NativeInformationDeliveryFiles(),
        );
        try {
          final item = await service.owner.createInformation('合成资料', '', [
            const FieldInput('正文', '', 'synthetic before'),
          ]);
          final ref = FieldRef(item.id, item.fields.single.id);
          await service.owner.correctValue(ref, 'synthetic after');
          final credential = await service.owner.createFileCredential(
            name: '合成凭据',
            publicPurpose: '',
            fileName: 'synthetic.key',
            bytes: [0, 128, 255, 10],
          );
          InformationAttachmentRef? attachment;
          FieldRef? fileRef;
          if (format >= 8) {
            final original = File('${root.path}/普通 附件.bin');
            await original.writeAsBytes([0, 255, 1, 2, 3, 10]);
            final draft = await service.owner.beginInformationFileDraft();
            try {
              final staged = await service.owner.stageInformationFile(
                draft,
                original.path,
              );
              final document = await service.owner.commitInformationDraft(
                draft,
                'save-synthetic',
                InformationDraftInput(
                  name: '合成附件',
                  description: '',
                  fields: [
                    InformationDraftField.stagedFile('原文', '', staged.id),
                  ],
                ),
              );
              attachment = document.fields.single.attachment;
              fileRef = FieldRef(document.id, document.fields.single.id);
            } finally {
              await service.owner.releaseInformationFileDraft(draft);
            }
          }
          final session = service.agent.openSession('合成备份会话');
          final scope = [ref, ?fileRef];
          final request = service.agent.request(session, '合成读取', scope);
          service.owner.approve(request.id, scope);
          final oldToken = service.agent.claim(session, request.id).token;
          await service.agent.read(oldToken, ref);
          service.agent.request(session, '不得恢复待审批', [ref]);
          if (format == 9) {
            await service.agent.fetchInformationFile(
              session,
              InformationFileFetchInput.fromJson({
                'protocolVersion': 2,
                'command': 'file-fetch',
                'requestId': request.id,
                'itemId': fileRef!.itemId,
                'fieldId': fileRef.fieldId,
                'operationId': 'before-backup',
              }),
            );
          }
          await _openBackups(tester, service, repository, files);
          await _click(tester, find.text('导出加密备份'));
          await _wait(tester, find.text('创建恢复密钥'));
          await _click(tester, find.text('创建恢复密钥'));
          await _wait(tester, find.text('保存恢复密钥文件'));
          await _click(tester, find.text('保存恢复密钥文件'));
          expect(await repository.backups.recoveryKeySaved(), isFalse);
          expect(await File(files.recovery).exists(), isFalse);
          files.cancelSave = false;
          await _click(tester, find.text('保存恢复密钥文件'));
          await _wait(tester, find.text('恢复密钥已另存'));
          await _click(tester, find.text('导出加密备份').last);
          await _wait(tester, find.text('加密备份已导出。'));
          final recovery = (await File(files.recovery).readAsString()).trim();
          expect(
            (await repository.backups.inspect(
              files.backup,
              recovery,
            )).formatVersion,
            format,
          );
          final sourceKey = List.of(sourceKeys.value!);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await service.close();
          await repository.close();
          sourceKeys.value!.fillRange(0, sourceKeys.value!.length, 0);
          sourceKeys.value = null;
          repository = await EncryptedInformationRepository.open(
            '${root.path}/恢复 库',
            targetKeys,
          );
          service = InformationService(
            repository: repository,
            informationDeliveryFiles: NativeInformationDeliveryFiles(),
          );
          expect(targetKeys.value, isNot(sourceKey));
          sourceKey.fillRange(0, sourceKey.length, 0);
          final wrongKey = File('${root.path}/错误 密钥.txt');
          await wrongKey.writeAsString(
            'aim-recovery-v1:${base64Url.encode(List.filled(32, 7))}',
          );
          files.selectedKey = wrongKey.path;
          await _openBackups(tester, service, repository, files);
          await _click(tester, find.text('查看恢复步骤'));
          await _wait(tester, find.byKey(const ValueKey('backup-select-file')));
          await _click(
            tester,
            find.byKey(const ValueKey('backup-select-file')),
          );
          await _click(tester, find.byKey(const ValueKey('backup-select-key')));
          await _click(tester, find.text('检查备份与恢复密钥'));
          await _wait(tester, find.text('恢复密钥不匹配、文件损坏或备份内容无效。当前信息库未改变。'));
          expect(service.owner.information, isEmpty);
          expect(service.owner.credentials, isEmpty);
          files.selectedKey = files.recovery;
          await _click(tester, find.byKey(const ValueKey('backup-select-key')));
          await _click(tester, find.text('检查备份与恢复密钥'));
          await _wait(tester, find.text('恢复预览'));
          await _click(tester, find.text('确认恢复到空库'));
          await _wait(tester, find.text('资料已恢复，请到“信息库”查看。Agent 需要重新申请访问。'));
          expect(service.owner.information.length, format == 7 ? 1 : 2);
          expect(repository.informationRevisions, hasLength(1));
          expect(
            repository.credentialMaterials
                .singleWhere((m) => m.credentialId == credential.id)
                .bytes,
            [0, 128, 255, 10],
          );
          expect(
            (await service.owner.history()).grants.every((g) => !g.active),
            isTrue,
          );
          expect(service.owner.requests, isEmpty);
          await expectLater(
            service.agent.read(oldToken, ref),
            throwsA(isA<AccessFailure>()),
          );
          expect(await repository.backups.recoveryKey(), isNull);
          if (attachment != null) {
            expect(
              await repository.readInformationAttachmentChunk(attachment, 0, 6),
              [0, 255, 1, 2, 3, 10],
            );
          }
          if (format == 9) {
            final fact = repository.informationFileDeliveries.single;
            expect(fact.runtime, isFalse);
            expect(fact.lease, isNull);
            expect(fact.sessionBinding, isNull);
          }
          final freshSession = service.agent.openSession('恢复后新会话');
          final fresh = service.agent.request(freshSession, '重新申请', [ref]);
          service.owner.approve(fresh.id, [ref]);
          expect(
            await service.agent.read(
              service.agent.claim(freshSession, fresh.id).token,
              ref,
            ),
            'synthetic after',
          );
          debugPrint(
            'MAC_NATIVE_BACKUP_$format=cancel-key-save,independent-key-save,export,wrong-key-refused,preview,restore,new-local-key,no-old-authority,fresh-approval; synthetic keys/picker paths, actual signed Flutter/SQLCipher',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await service.close();
          await repository.close();
          final actual = await root.resolveSymbolicLinks();
          final temp = await Directory.systemTemp.resolveSymbolicLinks();
          if (actual != root.absolute.path ||
              !actual.startsWith('$temp/aim-mac-native-backup-')) {
            throw StateError(
              'Refusing cleanup outside owned native backup fixture',
            );
          }
          await root.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
