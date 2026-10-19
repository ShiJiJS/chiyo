import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/ui.dart';

class _Files implements InformationFilePicker {
  String? source, target;
  Future<String?>? pending;
  @override
  Future<String?> choose() async => pending ?? source;
  @override
  Future<String?> saveAs(String name) async => target;
}

class _Repository extends MemoryInformationRepository {
  bool failCommit = false, failRelease = false;
  final operations = <String>[];
  final staged = Completer<void>();
  @override
  Future<InformationFileStage> stageInformationBytes({
    required String draftId,
    required String stageId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  }) async {
    final result = await super.stageInformationBytes(
      draftId: draftId,
      stageId: stageId,
      originalName: originalName,
      mediaType: mediaType,
      bytes: bytes,
    );
    if (!staged.isCompleted) staged.complete();
    return result;
  }

  @override
  Future<InformationDraftReceipt> commitInformationDraft(
    InformationDraftChange change,
  ) async {
    operations.add(change.operationId);
    if (failCommit) throw const AccessFailure('storage_failed');
    return super.commitInformationDraft(change);
  }

  @override
  Future<void> releaseInformationDraft(String draftId) async {
    if (failRelease) throw const AccessFailure('storage_failed');
    await super.releaseInformationDraft(draftId);
  }
}

void main() {
  late Directory root;
  late _Repository repository;
  late InformationService service;
  late _Files files;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('information-editor-');
    repository = _Repository();
    service = InformationService(repository: repository);
    files = _Files();
    final source = File('${root.path}/fictional-resume.pdf');
    await source.writeAsBytes([0, 255, 1, 2, 10]);
    files.source = source.path;
  });
  tearDown(() async {
    repository.failRelease = false;
    await service.close();
    // Only this test's generated source/output, never user-selected paths.
    for (final name in ['fictional-resume.pdf', 'saved.pdf']) {
      final file = File('${root.path}/$name');
      if (await file.exists()) await file.delete();
    }
    await root.delete();
  });

  InformationEditorDraft draft() => InformationEditorDraft(
    name: '求职资料',
    fields: [
      EditableInformationField(name: '姓名', value: '虚构姓名'),
      EditableInformationField(name: '简历', kind: FieldKind.file),
    ],
  );

  test(
    'real owner save retries unchanged input, preserves bytes and text-only edits',
    () async {
      final session = OwnerInformationEditorSession(service.owner, files);
      final d = draft();
      await session.choose(d.fields.last);
      expect(repository.items, isEmpty);
      expect((await repository.informationFileStagingUsage()).files, 1);
      repository.failCommit = true;
      await expectLater(session.save(d), throwsA(isA<AccessFailure>()));
      expect(d.fields.last.stage, isNotNull);
      expect(repository.items, isEmpty);
      repository.failCommit = false;
      final saved = await session.save(d);
      final replay = await session.save(d);
      expect(replay.id, saved.id);
      expect(repository.operations.toSet(), {'save-1'});
      expect(repository.items.length, 1);
      expect(
        await repository.readInformationAttachmentChunk(
          saved.fields.last.attachment!,
          0,
          5,
        ),
        [0, 255, 1, 2, 10],
      );
      await session.close();
      final next = OwnerInformationEditorSession(service.owner, files);
      final edit = InformationEditorDraft(original: saved);
      edit.fields.first.value = '新姓名';
      final corrected = await next.save(edit);
      expect(corrected.fields.last.attachment, saved.fields.last.attachment);
      expect(corrected.fields.last.id, saved.fields.last.id);
      expect(corrected.fields.first.value, '新姓名');
      expect(edit.changes.single.kind, FieldChangeKind.correct);
      await next.close();
      await service.owner.exportInformationFile(
        corrected.fields.last.attachment!,
        '${root.path}/saved.pdf',
      );
      expect(await File('${root.path}/saved.pdf').readAsBytes(), [
        0,
        255,
        1,
        2,
        10,
      ]);
      expect(
        service.agent.catalog().toString(),
        isNot(contains('fictional-resume.pdf')),
      );
    },
  );

  test(
    'cancel waits for in-flight picker and releases its eventual stage; cleanup can retry',
    () async {
      final selected = Completer<String?>();
      files.pending = selected.future;
      final session = OwnerInformationEditorSession(service.owner, files);
      final d = draft();
      final picking = session.choose(d.fields.last);
      repository.failRelease = true;
      final closing = session.close();
      final rejected = expectLater(closing, throwsA(isA<AccessFailure>()));
      selected.complete(files.source);
      await picking;
      await rejected;
      expect(repository.items, isEmpty);
      expect((await repository.informationFileStagingUsage()).files, 1);
      repository.failRelease = false;
      await session.close();
      await session.close();
      expect((await repository.informationFileStagingUsage()).files, 0);
      expect(await File(files.source!).readAsBytes(), [0, 255, 1, 2, 10]);
    },
  );

  test(
    'cancelled picker and failed replacement retain the original selection and other inputs',
    () async {
      final session = OwnerInformationEditorSession(service.owner, files);
      final d = draft();
      await session.choose(d.fields.last);
      final original = d.fields.last.stage;
      files.source = null;
      expect(await session.choose(d.fields.last), isFalse);
      expect(d.fields.last.stage, same(original));
      files.source = '${root.path}/missing.pdf';
      await expectLater(
        session.choose(d.fields.last),
        throwsA(isA<AccessFailure>()),
      );
      expect(d.fields.last.stage, same(original));
      expect(d.fields.first.value, '虚构姓名');
      await session.reset();
      expect((await repository.informationFileStagingUsage()).files, 0);
      final template = await service.owner.createTemplate('求职资料', '', [
        const TemplateFieldInput('简历', '', kind: FieldKind.file),
      ]);
      d.applyTemplate(template);
      expect(d.fields.single.hasFile, isFalse);
      expect(d.fields.single.stage, isNull);
      await session.close();
    },
  );

  test(
    'same-purpose file replacement retains identity, kind conversion changes it',
    () async {
      final session = OwnerInformationEditorSession(service.owner, files);
      final d = draft();
      await session.choose(d.fields.last);
      final first = await session.save(d);
      await session.close();
      final next = OwnerInformationEditorSession(service.owner, files);
      final edited = InformationEditorDraft(original: first);
      await File(files.source!).writeAsBytes([3, 4]);
      await next.choose(edited.fields.last);
      final replaced = await next.save(edited);
      await next.close();
      expect(replaced.fields.last.id, first.fields.last.id);
      expect(replaced.fields.last.attachment!.attachmentVersion, 2);
      expect(
        await repository.readInformationAttachmentChunk(
          first.fields.last.attachment!,
          0,
          5,
        ),
        [0, 255, 1, 2, 10],
      );
      final convert = OwnerInformationEditorSession(service.owner, files);
      final converted = InformationEditorDraft(original: replaced);
      converted.fields.last.kind = FieldKind.textNote;
      converted.fields.last.value = '文件已另行保管';
      final text = await convert.save(converted);
      await convert.close();
      expect(text.fields.last.id, isNot(replaced.fields.last.id));
      expect(text.fields.last.value, '文件已另行保管');
    },
  );

  testWidgets(
    'a known committed save only retries cleanup and never submits a second version',
    (tester) async {
      await tester.runAsync(() async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: informationTheme(),
            home: Scaffold(
              body: InformationLibrary(owner: service.owner, files: files),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('new-information')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('item-name')),
          '只保存一次',
        );
        await tester.enterText(
          find.byKey(const ValueKey('field-name-0')),
          '简历',
        );
        await tester.tap(find.byKey(const ValueKey('field-kind-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('文件').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('choose-file-0')));
        await tester.tap(find.byKey(const ValueKey('choose-file-0')));
        await repository.staged.future.timeout(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        repository.failCommit = true;
        await tester.tap(find.byKey(const ValueKey('save-information')));
        await tester.pumpAndSettle();
        expect(repository.items, isEmpty);
        expect(find.text('fictional-resume.pdf'), findsWidgets);
        expect(find.textContaining('当前输入已保留'), findsOneWidget);
        repository.failCommit = false;
        repository.failRelease = true;
        await tester.tap(find.byKey(const ValueKey('save-information')));
        await tester.pumpAndSettle();
        expect(repository.items.single.version, 1);
        expect(find.textContaining('信息已保存，剩余暂存清理未完成'), findsOneWidget);
        expect(find.text('重试清理并关闭'), findsOneWidget);
        repository.failRelease = false;
        await tester.tap(find.text('重试清理并关闭'));
        await tester.pumpAndSettle();
        expect(repository.items.length, 1);
        expect(repository.items.single.version, 1);
        expect(repository.operations.length, 2);
        expect((await repository.informationFileStagingUsage()).files, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await service.close();
      });
    },
  );

  testWidgets(
    'file editor shows missing file error, saves real file and keeps the three-column library',
    (tester) async {
      await tester.runAsync(() async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: informationTheme(),
            home: Scaffold(
              body: InformationLibrary(owner: service.owner, files: files),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('new-information')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('item-name')), '简历资料');
        await tester.enterText(
          find.byKey(const ValueKey('field-name-0')),
          '简历',
        );
        await tester.tap(find.byKey(const ValueKey('field-kind-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('文件').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('field-value-0')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('save-information')));
        await tester.pumpAndSettle();
        expect(find.text('请为这个字段选择一份文件。'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('choose-file-0')));
        await tester.tap(find.byKey(const ValueKey('choose-file-0')));
        await repository.staged.future.timeout(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        expect(find.text('fictional-resume.pdf'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('save-information')));
        await tester.pumpAndSettle();
        expect(repository.items.single.fields.single.kind, FieldKind.file);
        expect(find.byKey(const ValueKey('library-directory')), findsOneWidget);
        expect(find.byKey(const ValueKey('library-list')), findsOneWidget);
        expect(find.byKey(const ValueKey('library-detail')), findsOneWidget);
        expect(
          find.textContaining('5 B · application/pdf · 版本 1'),
          findsOneWidget,
        );
        final saved = repository.items.single;
        await tester.tap(
          find.byKey(const ValueKey('edit-information-description')),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('field-name-0')));
        await tester.enterText(
          find.byKey(const ValueKey('field-name-0')),
          '不同含义',
        );
        await tester.tap(find.byKey(const ValueKey('save-information')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('field-name-0')))
              .enabled,
          isTrue,
        );
        await tester.enterText(
          find.byKey(const ValueKey('field-name-0')),
          '简历',
        );
        files.source = '${root.path}/missing.pdf';
        await tester.ensureVisible(find.byKey(const ValueKey('choose-file-0')));
        await tester.tap(find.byKey(const ValueKey('choose-file-0')));
        await Future.doWhile(() async {
          await Future<void>.delayed(Duration.zero);
          await tester.pump();
          return find.textContaining('无法读取文件').evaluate().isEmpty;
        }).timeout(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('save-information')));
        await tester.pumpAndSettle();
        expect(find.byType(InformationEditor), findsOneWidget);
        expect(repository.items.single.version, saved.version);
        await tester.ensureVisible(find.text('继续使用原文件'));
        await tester.tap(find.text('继续使用原文件'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('save-information')));
        await tester.pumpAndSettle();
        expect(
          repository.items.single.fields.single.attachment,
          saved.fields.single.attachment,
        );
        expect(find.byType(InformationEditor), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        final closing = service.close();
        await tester.pump();
        await closing;
      });
    },
  );
}
