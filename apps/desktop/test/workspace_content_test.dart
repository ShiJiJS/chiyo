import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const resume = WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume');
const https = WorkspaceRecordRef(WorkspaceRecordKind.information, 'https');
void main() {
  late SampleWorkspaceSource source;
  late List<String> reads;
  setUp(() {
    reads = [];
    source = SampleWorkspaceSource(
      readAsset: (asset) {
        reads.add(asset);
        return File(asset).readAsBytes();
      },
    );
  });
  tearDown(() => source.dispose());
  Matcher failure(String code) =>
      isA<WorkspaceFailure>().having((e) => e.code, 'code', code);
  Future<WorkspaceFileChange> replace(String op, String selection) async {
    final h = await source.loadFileHistory(resume, 'file');
    return WorkspaceFileChange(
      operationId: op,
      record: resume,
      fieldKey: 'file',
      expectedRecordVersion: h.recordVersion,
      expectedFileVersion: h.current.ref.version,
      kind: WorkspaceFileChangeKind.replace,
      selectionId: selection,
    );
  }

  test(
    'document body/format are private versioned text; unknown format and oversized writes fail atomically',
    () async {
      final before = await source.readDetail(https);
      expect(before.values['bodyFormat'], 'markdown');
      expect(before.values['body'], contains('caddy validate'));
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: 'caddy validate'),
        )).total,
        0,
      );
      final created =
          await source.createRecord(
                WorkspaceCreate(
                  operationId: 'doc-new',
                  typeId: 'document',
                  name: '部署记录',
                  values: {'bodyFormat': 'plain', 'body': '第一版正文'},
                ),
              )
              as WorkspaceSaved;
      final edited =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'doc-edit',
                  expectedVersion: 1,
                  record: created.detail.record,
                  values: {
                    'bodyFormat': 'markdown',
                    'body': '## 第二版\n\n**部署记录**',
                  },
                ),
              )
              as WorkspaceSaved;
      expect(edited.detail.values['body'], contains('第二版'));
      final history = await source.previewRevision(
        created.detail.record.ref,
        1,
        expectedVersion: 2,
      );
      expect(history.archive.detail.values['body'], '第一版正文');
      for (final (id, values) in [
        ('doc-html', <String, Object?>{'bodyFormat': 'html'}),
        (
          'doc-large',
          <String, Object?>{'body': List.filled(1000001, 'x').join()},
        ),
      ]) {
        final rejected =
            await source.saveRecord(
                  WorkspaceEdit(
                    operationId: id,
                    expectedVersion: 2,
                    record: edited.detail.record,
                    values: values,
                  ),
                )
                as WorkspaceRejected;
        expect(rejected.failure.code, 'validation');
        expect(
          (await source.readDetail(created.detail.record.ref)).values,
          edited.detail.values,
        );
      }
      expect(reads, isEmpty);
    },
  );
  test(
    'file metadata never reads original bytes; current/old PDF pages follow explicit version and are immutable',
    () async {
      await source.queryRecords(const WorkspaceQuery());
      final detail = await source.readDetail(resume);
      expect(WorkspaceFileRef.fromJson(detail.values['file']).version, 2);
      expect(reads, isEmpty);
      final h = await source.loadFileHistory(resume, 'file');
      expect(h.recordVersion, 1);
      expect(h.current.ref.version, 2);
      expect(h.versions.map((v) => v.ref.version), [2, 1]);
      expect(reads, ['assets/zhiyu_files/manifest.json']);
      final current = await source.readFilePreview(resume, 'file');
      expect(current.pageCount, 2);
      expect(current.text, contains('LIN YUAN'));
      expect(current.image!.take(4), [137, 80, 78, 71]);
      final header = ByteData.sublistView(current.image!);
      expect(current.pixelWidth, header.getUint32(16));
      expect(current.pixelHeight, header.getUint32(20));
      expect(() => current.image![0] = 0, throwsUnsupportedError);
      final second = await source.readFilePreview(resume, 'file', page: 1);
      expect(second.text, contains('PROJECT NOTES'));
      expect(second.image, isNot(current.image));
      final old = await source.readFilePreview(resume, 'file', version: 1);
      expect(old.pageCount, 1);
      expect(old.text, contains('Task management tool'));
      await expectLater(
        source.readFilePreview(resume, 'file', page: 2),
        throwsA(failure('invalid_request')),
      );
    },
  );
  test(
    'replace and restore create new file heads, preserve record history and coalesce concurrent duplicate mutations',
    () async {
      final original = await source.readDetail(resume);
      final change = await replace('file-change', 'pdf-v1');
      final results = await Future.wait([
        source.changeFile(change),
        source.changeFile(change),
      ]);
      expect(results[0], results[1]);
      expect(results.first.version, 3);
      expect(
        (await source.loadFileHistory(resume, 'file')).versions,
        hasLength(3),
      );
      final current = await source.readDetail(resume);
      expect(current.version, 2);
      final metadataEdit =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'metadata-only',
                  expectedVersion: 2,
                  record: current.record.copyWith(description: '新的文件用途'),
                  values: {},
                ),
              )
              as WorkspaceSaved;
      expect(metadataEdit.detail.values['file'], current.values['file']);
      final bad =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'forged-file',
                  expectedVersion: 3,
                  record: metadataEdit.detail.record,
                  values: {'file': original.values['file']},
                ),
              )
              as WorkspaceRejected;
      expect(bad.failure.fieldErrors['file'], isNotNull);
      final preview = await source.previewRevision(
        resume,
        1,
        expectedVersion: 3,
      );
      expect(
        WorkspaceFileRef.fromJson(preview.restored.values['file']).version,
        4,
      );
      await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore-item',
          action: WorkspaceRecordAction.restoreRevision,
          ref: resume,
          expectedVersion: 3,
          revisionVersion: 1,
          expectedCatalogVersion: preview.catalogVersion,
        ),
      );
      expect(
        (await source.readDetail(resume)).values['file'],
        preview.restored.values['file'],
      );
      expect((await source.readFilePreview(resume, 'file')).pageCount, 2);
      final h = await source.loadFileHistory(resume, 'file');
      final restored = await source.changeFile(
        WorkspaceFileChange(
          operationId: 'restore-file',
          record: resume,
          fieldKey: 'file',
          expectedRecordVersion: h.recordVersion,
          expectedFileVersion: h.current.ref.version,
          kind: WorkspaceFileChangeKind.restore,
          restoreVersion: 1,
        ),
      );
      expect(restored.version, 5);
      expect((await source.readFilePreview(resume, 'file')).pageCount, 1);
      expect(
        (await source.fileOperationReceipt('restore-file'))!.file,
        restored,
      );
      expect(preview.archive.detail.values, original.values);
    },
  );
  test(
    'import validates selection/metadata, failed writes preserve state, and duplicate import does not create two records',
    () async {
      source.nextSaveFailure = const WorkspaceFailure('offline', '文件导入失败');
      final input = WorkspaceFileImport(
        operationId: 'import-one',
        selectionId: 'unknown',
        name: '未知文件',
        directoryId: 'personal',
      );
      await expectLater(source.importFile(input), throwsA(failure('offline')));
      expect((await source.loadSummary()).records, 31);
      expect(await source.fileOperationReceipt('import-one'), isNull);
      final result = await Future.wait([
        source.importFile(input),
        source.importFile(input),
      ]);
      expect(result.first, result.last);
      expect((await source.loadSummary()).records, 32);
      final preview = await source.readFilePreview(result.first, 'file');
      expect(preview.kind, WorkspaceFilePreviewKind.unsupported);
      expect(
        preview.file.byteLength,
        File('assets/zhiyu_files/unsupported.bin').lengthSync(),
      );
      await expectLater(
        source.importFile(
          WorkspaceFileImport(
            operationId: 'bad-selection',
            selectionId: '../../private',
            name: '错误文件',
          ),
        ),
        throwsA(failure('not_found')),
      );
      await expectLater(
        source.importFile(
          WorkspaceFileImport(
            operationId: 'empty-name',
            selectionId: 'pdf-v2',
            name: ' ',
          ),
        ),
        throwsA(failure('validation')),
      );
      expect((await source.loadSummary()).records, 32);
    },
  );
  test(
    'unconnected sample file actions report cancellation or failure and never fabricate native success',
    () async {
      source.cancelNextFileAction = true;
      final cancel = await source.fileAction(
        resume,
        'file',
        2,
        WorkspaceFileAction.saveAs,
        operationId: 'cancel-save',
      );
      expect(cancel.completed, isFalse);
      source.nextFileActionFailure = const WorkspaceFailure(
        'unknown_outcome',
        '结果未知',
      );
      await expectLater(
        source.fileAction(
          resume,
          'file',
          2,
          WorkspaceFileAction.open,
          operationId: 'open-unknown',
        ),
        throwsA(failure('unknown_outcome')),
      );
      expect(await source.fileOperationReceipt('open-unknown'), isNull);
      await expectLater(
        source.fileAction(
          resume,
          'file',
          1,
          WorkspaceFileAction.saveAs,
          operationId: 'save-old',
        ),
        throwsA(failure('unsupported')),
      );
      expect(await source.fileOperationReceipt('save-old'), isNull);
      expect(
        (await source.loadFileHistory(resume, 'file')).current.ref.version,
        2,
      );
    },
  );
  test(
    'credential and unrelated metadata never pass the file aperture; preview failures leave metadata usable',
    () async {
      await expectLater(
        source.readFilePreview(
          const WorkspaceRecordRef(WorkspaceRecordKind.credential, 'aliyunkey'),
          'file',
        ),
        throwsA(failure('unsupported')),
      );
      await expectLater(
        source.readFilePreview(
          const WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
          'file',
        ),
        throwsA(failure('unsupported')),
      );
      expect(reads, isEmpty);
      source.nextFilePreviewFailure = const WorkspaceFailure(
        'preview_unavailable',
        '预览失败',
      );
      await expectLater(
        source.readFilePreview(resume, 'file'),
        throwsA(failure('preview_unavailable')),
      );
      expect(
        (await source.loadFileHistory(resume, 'file')).current.filename,
        contains('.pdf'),
      );
      expect(
        (await source.readFilePreview(resume, 'file')).kind,
        WorkspaceFilePreviewKind.image,
      );
    },
  );
  test(
    'corrupt preview data is rejected; a pending old preview is cancelled after the record changes',
    () async {
      final corrupt = SampleWorkspaceSource(
        readAsset: (asset) async => asset.endsWith('resume-v2-page-1.png')
            ? Uint8List.fromList([1, 2, 3])
            : File(asset).readAsBytes(),
      );
      addTearDown(corrupt.dispose);
      await expectLater(
        corrupt.readFilePreview(resume, 'file'),
        throwsA(failure('preview_unavailable')),
      );
      expect(
        (await corrupt.loadFileHistory(resume, 'file')).current.ref.version,
        2,
      );
      final pending = Completer<Uint8List>();
      final requested = Completer<void>();
      final deferred = SampleWorkspaceSource(
        readAsset: (asset) {
          if (asset.endsWith('resume-v2-page-1.png')) {
            requested.complete();
            return pending.future;
          }
          return File(asset).readAsBytes();
        },
      );
      addTearDown(deferred.dispose);
      final old = deferred.readFilePreview(resume, 'file');
      final assertion = expectLater(old, throwsA(failure('cancelled')));
      await requested.future;
      final current = await deferred.readDetail(resume);
      await deferred.saveRecord(
        WorkspaceEdit(
          operationId: 'update-while-preview',
          expectedVersion: current.version,
          record: current.record.copyWith(name: '新的文件名称'),
          values: {},
        ),
      );
      pending.complete(
        await File('assets/zhiyu_files/resume-v2-page-1.png').readAsBytes(),
      );
      await assertion;
    },
  );
  test(
    'recycle blocks file reads; restore renews its file head, purge removes access, reset restores only the fictional baseline',
    () async {
      final receipt = await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'recycle-file',
          action: WorkspaceRecordAction.recycle,
          ref: resume,
          expectedVersion: 1,
        ),
      );
      await expectLater(
        source.readFilePreview(resume, 'file'),
        throwsA(failure('not_found')),
      );
      await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore-recycled-file',
          action: WorkspaceRecordAction.restoreRecycled,
          ref: resume,
          expectedVersion: receipt.version,
          entryId: receipt.entryId,
          expectedCatalogVersion: (await source.loadCatalog()).version,
        ),
      );
      expect(
        (await source.loadFileHistory(resume, 'file')).current.ref.version,
        3,
      );
      final again = await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'recycle-file-again',
          action: WorkspaceRecordAction.recycle,
          ref: resume,
          expectedVersion: 3,
        ),
      );
      await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'purge-file',
          action: WorkspaceRecordAction.purge,
          ref: resume,
          expectedVersion: again.version,
          entryId: again.entryId,
        ),
      );
      await expectLater(
        source.loadFileHistory(resume, 'file'),
        throwsA(failure('not_found')),
      );
      source.reset();
      expect(
        (await source.loadFileHistory(resume, 'file')).current.ref.version,
        2,
      );
    },
  );
  test(
    'manifest PDF text, original sizes and page hashes correspond to the bundled immutable resources',
    () async {
      final manifest =
          jsonDecode(
                await File('assets/zhiyu_files/manifest.json').readAsString(),
              )
              as Map;
      for (final file in manifest['files'] as List) {
        final bytes = await File(
          'assets/zhiyu_files/${file['asset']}',
        ).readAsBytes();
        expect(bytes.length, file['byteLength']);
        expect(sha256.convert(bytes).toString(), file['sha256']);
        for (final page in file['pages'] as List) {
          final pixels = await File(
            'assets/zhiyu_files/${page['asset']}',
          ).readAsBytes();
          expect(sha256.convert(pixels).toString(), page['sha256']);
        }
        if (file['id'] == 'pdf-v2') {
          expect(
            (file['pages'] as List).last['text'],
            contains('PROJECT NOTES'),
          );
        }
      }
    },
  );
}
