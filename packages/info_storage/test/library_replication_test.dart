import 'dart:convert';
import 'dart:io';

import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'initial replication keeps older retained originals, plugins, templates and manual order',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-replication-history-',
      );
      var now = DateTime.utc(2026, 1, 1);
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        TestKeyStore(),
        clock: () => now,
      );
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        TestKeyStore(),
        clock: () => now,
      );
      final service = InformationService(repository: source, clock: () => now);
      final recipient = InformationService(
        repository: target,
        clock: () => now,
      );
      try {
        Future<InformationItem> save(
          List<int> bytes, [
          InformationItem? before,
        ]) async {
          final file = File('${root.path}/source.bin');
          await file.writeAsBytes(bytes);
          final draft = await service.owner.beginInformationFileDraft();
          try {
            final staged = await service.owner.stageInformationFile(
              draft,
              file.path,
            );
            return await service.owner.commitInformationDraft(
              draft,
              'old-retained-${before?.version ?? 0}',
              InformationDraftInput(
                name: '长期保留原件',
                description: '',
                itemId: before?.id,
                baseVersion: before?.version,
                fields: [
                  InformationDraftField.stagedFile(
                    '文件',
                    '',
                    staged.id,
                    fieldId: before?.fields.single.id,
                  ),
                ],
              ),
            );
          } finally {
            await service.owner.releaseInformationFileDraft(draft);
          }
        }

        final first = await save([3, 4, 5, 6]);
        now = now.add(const Duration(days: 1));
        final second = await save([7, 8], first);
        await service.owner.createTemplate('合成旧模板', '保留已有格式', [
          const TemplateFieldInput('正文', '', kind: FieldKind.textNote),
        ]);
        final package = InstalledTemplatePackage(
          id: 'local.replication',
          enabled: true,
          origin: 'synthetic.json',
          bytes: utf8.encode(
            jsonEncode({
              'id': 'local.replication',
              'name': '合成同步插件',
              'version': '1.0.0',
              'hostApi': 1,
              'author': '合成测试',
              'description': '',
              'templates': [
                {
                  'id': 'record',
                  'name': '合成资料',
                  'icon': 'file',
                  'fields': [
                    {
                      'key': 'body',
                      'label': '内容',
                      'type': 'text',
                      'required': false,
                    },
                  ],
                  'sections': [
                    {
                      'kind': 'fields',
                      'title': '资料',
                      'keys': ['body'],
                    },
                  ],
                  'relations': [],
                  'instructions': '',
                },
              ],
            }),
          ),
        );
        await service.owner.changeTemplatePackage(
          TemplatePackageCommand(
            operationId: 'install-sync-fixture',
            action: TemplatePackageAction.install,
            packageId: package.id,
            expectedVersion: service.owner.templatePackageVersion,
            commandDigest: 'a' * 64,
            expectedDigest: package.digest,
          ),
          input: package,
        );
        final a = await service.owner.createDirectory('先前'),
            b = await service.owner.createDirectory('后建');
        final selection = LibrarySelection(directoryIds: [b.id]);
        final position = LibraryMovePosition(
          LibraryEntryRef('directory', a.id),
        );
        final move = await service.owner.previewLibraryMove(
          selection,
          null,
          position: position,
        );
        await service.owner.moveLibrarySelection(
          'reorder-sync-fixture',
          selection,
          null,
          move.token,
          position: position,
        );
        final recycled = await service.owner.createInformation('可恢复资料', '', [
          const FieldInput('正文', '', 'SYNTHETIC_RECYCLE_CONTENT'),
        ]);
        final trash = LibrarySelection(informationIds: [recycled.id]);
        final review = await service.owner.previewLibraryRecycle(trash);
        await service.owner.recycleLibrarySelection(
          'recycle-sync-fixture',
          trash,
          review.token,
        );
        now = now.add(const Duration(days: 120));
        expect(source.informationRevisions, isNotEmpty);
        final sourceVersions = await source.informationAttachmentVersions(
          first.fields.single.attachment!.attachmentId,
        );
        expect(sourceVersions, hasLength(2));
        final path = '${root.path}/all-retained.encrypted';
        final prepared = await service.owner.exportLibrary(
          () => LibraryReplication(source).exportInitial(path),
        );
        await recipient.owner.restoreLibrary(
          () => LibraryReplication(target).installInitial(
            path: path,
            transferKey: prepared.transferKey,
            operationId: 'all-history',
            transfer: prepared.transfer,
          ),
        );
        expect(
          target.informationRevisions.length,
          source.informationRevisions.length,
        );
        expect(
          target.informationRevisions.any(
            (r) => r.item.id == first.id && r.item.version == first.version,
          ),
          true,
        );
        expect(
          await target.readInformationAttachmentChunk(
            first.fields.single.attachment!,
            0,
            4,
          ),
          [3, 4, 5, 6],
        );
        expect(
          await target.readInformationAttachmentChunk(
            second.fields.single.attachment!,
            0,
            2,
          ),
          [7, 8],
        );
        expect(
          target.templates.map((t) => [t.id, t.name, t.version]),
          source.templates.map((t) => [t.id, t.name, t.version]),
        );
        expect(target.installedTemplatePackages.single.bytes, package.bytes);
        expect(
          target.libraryOrder!.directories,
          source.libraryOrder!.directories,
        );
        expect(target.recycleEntries.length, source.recycleEntries.length);
        expect(
          target.libraryRecycleBatches.length,
          source.libraryRecycleBatches.length,
        );
        expect(source.recycleEntries.single.snapshot, isNotNull);
        expect(target.recycleEntries.single.snapshot, isNotNull);
      } finally {
        await service.close();
        await recipient.close();
        await source.close();
        await target.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'initial transfer preserves content, retained history and local preferences without copying live permission',
    () async {
      final root = await Directory.systemTemp.createTemp('chiyo-replication-');
      final sourceKeys = TestKeyStore(), targetKeys = TestKeyStore();
      var source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        sourceKeys,
      );
      var target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        targetKeys,
      );
      var sourceService = InformationService(repository: source);
      var targetService = InformationService(repository: target);
      try {
        final parent = await sourceService.owner.createDirectory('合成部署');
        final child = await sourceService.owner.createDirectory(
          '应用',
          parentId: parent.id,
        );
        final tag = await sourceService.owner.createTag('合成标签');
        final item = await sourceService.owner.createInformation(
          '合成服务器',
          '部署说明',
          [const FieldInput('地址', '', 'SYNTHETIC_SYNC_PRIVATE')],
        );
        await sourceService.owner.organizeInformation(
          item.id,
          directoryId: child.id,
          tagIds: [tag.id],
        );
        await sourceService.owner.correctValue(
          FieldRef(item.id, item.fields.single.id),
          'SYNTHETIC_SYNC_NEW_VALUE',
        );
        final credential = await sourceService.owner.createStringCredential(
          name: '合成密码',
          publicPurpose: '同步验证',
          secret: 'SYNTHETIC_SYNC_PASSWORD',
        );
        await source.writeSetting('desktopDarkAppearance', 1);
        await target.writeSetting('desktopDarkAppearance', 0);

        final input = File('${root.path}/source.md');
        await input.writeAsString('# 合成附件原文');
        final draft = await sourceService.owner.beginInformationFileDraft();
        late InformationItem attachment;
        try {
          final stage = await sourceService.owner.stageInformationFile(
            draft,
            input.path,
            mediaType: 'text/markdown',
          );
          attachment = await sourceService.owner.commitInformationDraft(
            draft,
            'sync-source-file',
            InformationDraftInput(
              name: '合成附件',
              description: '',
              fields: [InformationDraftField.stagedFile('原文', '', stage.id)],
            ),
          );
        } finally {
          await sourceService.owner.releaseInformationFileDraft(draft);
        }
        final session = sourceService.agent.openSession('合成旧会话');
        final scope = [FieldRef(item.id, item.fields.single.id)];
        final request = sourceService.agent.request(session, '合成读取', scope);
        sourceService.owner.approve(request.id, scope);
        final proof = sourceService.agent.claim(session, request.id);

        final sender = LibraryReplication(source),
            recipient = LibraryReplication(target);
        final sourceIdentity = await sender.identity();
        final targetIdentity = await recipient.identity();
        expect(sourceIdentity.replicaId, isNot(targetIdentity.replicaId));
        final path = '${root.path}/initial.encrypted';
        final prepared = await sourceService.owner.exportLibrary(
          () => sender.exportInitial(path),
        );
        final before = await File(
          '${root.path}/target/library.db',
        ).readAsBytes();
        final wrongKey =
            'aim-recovery-v1:${base64Url.encode(List.filled(32, 17))}';
        await expectLater(
          targetService.owner.restoreLibrary(
            () => recipient.installInitial(
              path: path,
              transferKey: wrongKey,
              operationId: 'initial-1',
              transfer: prepared.transfer,
            ),
          ),
          throwsA(isA<StorageFailure>()),
        );
        expect(target.items, isEmpty);
        expect(
          await File('${root.path}/target/library.db').readAsBytes(),
          before,
        );

        void sql(String statement) {
          final db = sqlite.sqlite3.open('${root.path}/target/library.db');
          try {
            db.execute(
              'PRAGMA key = "x\'${targetKeys.key!.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"',
            );
            db.execute(statement);
          } finally {
            db.close();
          }
        }

        sql(
          "CREATE TRIGGER fail_initial_receipt BEFORE INSERT ON library_replica_receipts BEGIN SELECT RAISE(ABORT,'synthetic write failure'); END",
        );
        await expectLater(
          targetService.owner.restoreLibraryOnce(
            previous: () => recipient.receipt('initial-1', prepared.transfer),
            restore: () => recipient.installInitial(
              path: path,
              transferKey: prepared.transferKey,
              operationId: 'initial-1',
              transfer: prepared.transfer,
            ),
          ),
          throwsA(isA<StorageFailure>()),
        );
        expect(target.items, isEmpty);
        expect(target.managedCredentials, isEmpty);
        expect((await recipient.identity()).toJson(), targetIdentity.toJson());
        expect(await recipient.lookupReceipt('initial-1'), isNull);
        sql('DROP TRIGGER fail_initial_receipt');

        final receipt = await targetService.owner.restoreLibraryOnce(
          previous: () => recipient.receipt('initial-1', prepared.transfer),
          restore: () => recipient.installInitial(
            path: path,
            transferKey: prepared.transferKey,
            operationId: 'initial-1',
            transfer: prepared.transfer,
          ),
        );
        expect(receipt.identity.libraryId, sourceIdentity.libraryId);
        expect(receipt.identity.replicaId, targetIdentity.replicaId);
        expect(targetKeys.key, isNot(sourceKeys.key));
        expect(
          target.items.map((i) => i.id).toSet(),
          source.items.map((i) => i.id).toSet(),
        );
        expect(
          target.informationRevisions.length,
          source.informationRevisions.length,
        );
        expect(
          target.directories.map((d) => [d.id, d.name, d.parentId, d.version]),
          source.directories.map((d) => [d.id, d.name, d.parentId, d.version]),
        );
        expect(
          target.tags.map((d) => [d.id, d.name, d.version]),
          source.tags.map((d) => [d.id, d.name, d.version]),
        );
        expect(target.readSetting('desktopDarkAppearance'), 0);
        expect(
          utf8.decode(target.credentialMaterials.single.bytes),
          'SYNTHETIC_SYNC_PASSWORD',
        );
        expect(target.managedCredentials.single.id, credential.id);
        final ref = attachment.fields.single.attachment!;
        expect(
          utf8.decode(
            await target.readInformationAttachmentChunk(
              ref,
              0,
              utf8.encode('# 合成附件原文').length,
            ),
          ),
          '# 合成附件原文',
        );
        expect(target.grantHistory.single.restoredAt, isNotNull);
        await expectLater(
          targetService.agent.read(proof.token, scope.single),
          throwsA(isA<AccessFailure>()),
        );
        expect(
          await sourceService.agent.read(proof.token, scope.single),
          'SYNTHETIC_SYNC_NEW_VALUE',
        );
        expect(await source.backups.recoveryKey(), isNull);

        await targetService.close();
        await target.close();
        target = await EncryptedInformationRepository.open(
          '${root.path}/target',
          targetKeys,
        );
        targetService = InformationService(repository: target);
        final retry = LibraryReplication(target);
        await File(path).delete();
        final same = await retry.installInitial(
          path: path,
          transferKey: '',
          operationId: 'initial-1',
          transfer: prepared.transfer,
        );
        expect(same.toJson(), receipt.toJson());
        expect(target.items, hasLength(2));
        expect((await retry.identity()).toJson(), receipt.identity.toJson());
        await expectLater(
          retry.installInitial(
            path: path,
            transferKey: '',
            operationId: 'another-operation',
            transfer: prepared.transfer,
          ),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'recipient_not_empty',
            ),
          ),
        );
        final recovery = await target.backups.enable();
        await target.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
        await targetService.owner.exportLibrary(
          () => target.backups.exportTo('${root.path}/after-sync.backup'),
        );
        final restored = await EncryptedInformationRepository.open(
          '${root.path}/restored',
          TestKeyStore(),
        );
        final restoreService = InformationService(repository: restored);
        try {
          final beforeRestore = await LibraryReplication(restored).identity();
          await restoreService.owner.restoreLibrary(
            () => restored.backups.restoreFrom(
              '${root.path}/after-sync.backup',
              recovery,
            ),
          );
          final afterRestore = await LibraryReplication(restored).identity();
          expect(afterRestore.libraryId, isNot(beforeRestore.libraryId));
          expect(afterRestore.libraryId, isNot(receipt.identity.libraryId));
          expect(
            await LibraryReplication(restored).lookupReceipt('initial-1'),
            isNull,
          );
          expect(restored.items, hasLength(2));
          expect(
            utf8.decode(restored.credentialMaterials.single.bytes),
            'SYNTHETIC_SYNC_PASSWORD',
          );
        } finally {
          await restoreService.close();
          await restored.close();
        }
        for (final file in [
          File('${root.path}/source/library.db'),
          File('${root.path}/target/library.db'),
        ]) {
          final bytes = String.fromCharCodes(await file.readAsBytes());
          expect(bytes, isNot(contains('SYNTHETIC_SYNC_PASSWORD')));
          expect(bytes, isNot(contains('SYNTHETIC_SYNC_NEW_VALUE')));
        }
      } finally {
        await sourceService.close();
        await targetService.close();
        await source.close();
        await target.close();
        await root.delete(recursive: true);
      }
    },
  );
}
