import 'dart:convert';
import 'dart:io';

import 'package:info_core/info_core.dart';
import 'package:info_core/library_sync_changes.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'portable units roundtrip a complete initial copy with inactive history',
    () async {
      final root = await Directory.systemTemp.createTemp('sync-contents-');
      final source = await EncryptedInformationRepository.open(
        '${root.path}/a',
        TestKeyStore(),
      );
      final target = await EncryptedInformationRepository.open(
        '${root.path}/b',
        TestKeyStore(),
      );
      final service = InformationService(repository: source);
      final recipient = InformationService(repository: target);
      try {
        final directory = await service.owner.createDirectory('合成目录');
        final tag = await service.owner.createTag('合成标签');
        final item = await service.owner.createInformation('合成资料', '', [
          const FieldInput('正文', '', 'SYNTHETIC_CONTENT'),
        ]);
        await service.owner.organizeInformation(
          item.id,
          directoryId: directory.id,
          tagIds: [tag.id],
        );
        await service.owner.correctValue(
          FieldRef(item.id, item.fields.single.id),
          'SYNTHETIC_CONTENT_CHANGED',
        );
        final session = service.agent.openSession('合成历史');
        final request = service.agent.request(session, '验证历史只复制事实', [
          FieldRef(item.id, item.fields.single.id),
        ]);
        service.owner.approve(request.id, [
          FieldRef(item.id, item.fields.single.id),
        ], lifetime: const Duration(hours: 2));
        final before = await service.owner.exportLibrary(
          () => LibraryReplication(source).snapshotContents(),
        );
        before.validate(DateTime.now().toUtc());
        final information =
            before.units[LibrarySyncKey(LibrarySyncKind.information, item.id)]!;
        final tables = information['tables'] as Map;
        expect(tables['information_items'], hasLength(1));
        expect(tables['information_fields'], hasLength(1));
        expect(tables['information_revisions'], isNotEmpty);
        final export = await service.owner.exportLibrary(
          () => LibraryReplication(
            source,
          ).exportInitial('${root.path}/copy.encrypted'),
        );
        await recipient.owner.restoreLibrary(
          () => LibraryReplication(target).installInitial(
            path: '${root.path}/copy.encrypted',
            transferKey: export.transferKey,
            operationId: 'copy-contents',
            transfer: export.transfer,
          ),
        );
        final after = await recipient.owner.exportLibrary(
          () => LibraryReplication(target).snapshotContents(),
        );
        after.validate(DateTime.now().toUtc());
        expect(after.units.keys.toSet(), before.units.keys.toSet());
        expect(
          jsonEncode(after.units.map((k, v) => MapEntry(k.toString(), v))),
          jsonEncode(before.units.map((k, v) => MapEntry(k.toString(), v))),
        );
        expect(target.grantHistory.every((g) => !g.active), true);
        expect(after.toString(), isNot(contains('SYNTHETIC_CONTENT')));
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
    'changed units cannot impersonate another record or carry unknown private columns',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-contents-validate-',
      );
      final source = await EncryptedInformationRepository.open(
        root.path,
        TestKeyStore(),
      );
      final service = InformationService(repository: source);
      try {
        final a = await service.owner.createInformation('第一条', '', [
          const FieldInput('正文', '', 'SYNTHETIC_A'),
        ]);
        final b = await service.owner.createInformation('第二条', '', [
          const FieldInput('正文', '', 'SYNTHETIC_B'),
        ]);
        final contents = await service.owner.exportLibrary(
          () => LibraryReplication(source).snapshotContents(),
        );
        final keyA = LibrarySyncKey(LibrarySyncKind.information, a.id);
        final keyB = LibrarySyncKey(LibrarySyncKind.information, b.id);
        LibrarySyncBatch batch(Map<String, Object?> replacement) =>
            LibrarySyncBatch(
              libraryId: contents.libraryId,
              sourceReplicaId: 'a' * 32,
              operationId: 'bad-unit',
              sequence: 1,
              edits: [
                LibrarySyncEdit(
                  key: keyA,
                  baseVersion: null,
                  content: replacement,
                ),
              ],
            );
        // Swap both payloads: the whole relational document still validates,
        // but its unit identities must not bypass the conflict comparison.
        final swapped = LibrarySyncBatch(
          libraryId: contents.libraryId,
          sourceReplicaId: 'a' * 32,
          operationId: 'swapped-units',
          sequence: 1,
          edits: [
            LibrarySyncEdit(
              key: keyA,
              baseVersion: null,
              content: contents.units[keyB],
            ),
            LibrarySyncEdit(
              key: keyB,
              baseVersion: null,
              content: contents.units[keyA],
            ),
          ],
        );
        expect(
          () => contents.replacing(swapped).validate(DateTime.now().toUtc()),
          throwsA(isA<StorageFailure>()),
        );
        final privateColumn = Map<String, Object?>.from(
          jsonDecode(jsonEncode(contents.units[keyA])) as Map,
        );
        ((privateColumn['tables'] as Map)['information_items'] as List)
                .single['ownerToken'] =
            'SYNTHETIC_FORBIDDEN';
        expect(
          () => contents
              .replacing(batch(privateColumn))
              .validate(DateTime.now().toUtc()),
          throwsA(isA<StorageFailure>()),
        );
        expect(service.owner.information, hasLength(2));
      } finally {
        await service.close();
        await source.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'file versions form metadata-only units separate from record references',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sync-contents-files-',
      );
      final source = await EncryptedInformationRepository.open(
        root.path,
        TestKeyStore(),
      );
      final service = InformationService(repository: source);
      try {
        final file = File('${root.path}/source.txt');
        const text = 'SYNTHETIC_ORIGINAL_FILE_BODY';
        await file.writeAsString(text);
        final draft = await service.owner.beginInformationFileDraft();
        try {
          final staged = await service.owner.stageInformationFile(
            draft,
            file.path,
          );
          await service.owner.commitInformationDraft(
            draft,
            'file-unit',
            InformationDraftInput(
              name: '合成文件',
              description: '',
              fields: [InformationDraftField.stagedFile('原文', '', staged.id)],
            ),
          );
        } finally {
          await service.owner.releaseInformationFileDraft(draft);
        }
        final contents = await service.owner.exportLibrary(
          () => LibraryReplication(source).snapshotContents(),
        );
        contents.validate(DateTime.now().toUtc());
        final files = contents.units.entries.where(
          (e) => e.key.kind == LibrarySyncKind.attachment,
        );
        expect(files, hasLength(1));
        expect(files.single.value['attachments'], hasLength(1));
        expect(
          jsonEncode(contents.units.values.toList()),
          isNot(contains(text)),
        );
        final information = contents.units.entries.singleWhere(
          (e) => e.key.kind == LibrarySyncKind.information,
        );
        expect(
          (information.value['tables'] as Map)['information_file_fields'],
          hasLength(1),
        );
      } finally {
        await service.close();
        await source.close();
        await root.delete(recursive: true);
      }
    },
  );
}
