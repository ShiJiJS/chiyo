import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_credential.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const aliyun = WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun');
void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    final fonts = await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
    await File('$evidence/fonts.json').writeAsString(jsonEncode(fonts));
  });
  void check(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (t) async {
        final shadows = debugDisableShadows;
        try {
          if (evidence.isNotEmpty) debugDisableShadows = false;
          await body(t);
        } finally {
          debugDisableShadows = shadows;
        }
      });
  Future<void> tap(WidgetTester t, Finder finder) async {
    await t.ensureVisible(finder);
    await t.pumpAndSettle();
    await t.tap(finder);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> enter(WidgetTester t, Finder finder, String value) async {
    await t.ensureVisible(finder);
    await t.pumpAndSettle();
    await t.enterText(finder, value);
    await t.pumpAndSettle();
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('credential-lifecycle-capture')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<LibraryController> start(
    WidgetTester t,
    String name, {
    bool dark = false,
    double scale = 1,
    double width = 1440,
  }) async {
    t.view.physicalSize = Size(width, width == 1440 ? 900 : 800);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('credential-lifecycle-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    await tap(t, find.byKey(const ValueKey('library-directory-all')));
    await enter(t, find.byKey(const ValueKey('library-search')), name);
    final model = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
    final ref = model.results!.items.singleWhere((r) => r.name == name).ref;
    await tap(t, find.byKey(ValueKey('library-record-${ref.key}')));
    expect(find.byType(LibraryCredential), findsOneWidget);
    expect(t.takeException(), isNull);
    return model;
  }

  Future<void> action(WidgetTester t, String text) async {
    await tap(t, find.byKey(const ValueKey('library-record-actions')));
    await tap(t, find.text(text));
  }

  Future<void> rotate(LibraryController model) async {
    final d = await model.source.credentials.read(ssh);
    await model.source.credentials.save(
      WorkspaceCredentialWrite(
        operationId: 'setup-rotation',
        ref: ssh,
        expectedRecordVersion: d.recordVersion,
        expectedMaterialVersion: d.materialVersion,
        name: d.record.name,
        purpose: d.record.description,
        privateNote: '材料恢复应保留的备注',
        binding: d.binding,
        directoryId: d.record.directoryId,
        tagIds: d.record.tags.map((t) => t.id),
        candidateId: 'ssh-file',
      ),
    );
  }

  check(
    'material list failure and explicit restore preserve metadata and create a disabled new head',
    (t) async {
      final model = await start(t, 'Azure SSH 私钥');
      await rotate(model);
      await t.pumpAndSettle();
      (model.source as SampleWorkspaceSource).nextCredentialReadFailure =
          const WorkspaceFailure('offline', '材料版本读取失败，请重试。');
      await action(t, '材料版本');
      expect(find.text('材料版本读取失败，请重试。'), findsOneWidget);
      await tap(t, find.text('重新读取并核对'));
      expect(
        find.byKey(const ValueKey('credential-material-1')),
        findsOneWidget,
      );
      await tap(t, find.byKey(const ValueKey('credential-material-1')));
      await tap(t, find.byKey(const ValueKey('credential-material-restore')));
      await capture(t, 'credential-1440-light-material-restore-review');
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('offline', '材料恢复失败，选择仍保留。');
      await tap(t, find.byKey(const ValueKey('credential-material-restore')));
      expect(find.text('材料恢复失败，选择仍保留。'), findsOneWidget);
      expect((await model.source.credentials.read(ssh)).materialVersion, 2);
      await capture(t, 'credential-1440-light-material-restore-failure');
      await tap(t, find.byKey(const ValueKey('credential-material-restore')));
      expect(find.byType(DesktopDialog), findsNothing);
      final result = await model.source.credentials.read(ssh);
      expect(result.materialVersion, 3);
      expect(result.enabled, isFalse);
      expect(result.privateNote, '材料恢复应保留的备注');
      expect(result.filename, 'azure-jp.pem');
      expect((await model.source.readDetail(ssh)).values, isEmpty);
    },
  );
  check(
    'dark200 recycle unknown result is reconciled before explicit retry and shared recycle restores disabled',
    (t) async {
      final model = await start(
        t,
        'Azure SSH 私钥',
        dark: true,
        scale: 2,
        width: 1280,
      );
      final count = (await model.source.loadSummary()).records;
      await action(t, '移到回收站');
      await tap(t, find.text('取消').last);
      expect((await model.source.loadSummary()).records, count);
      await action(t, '移到回收站');
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('unknown_outcome', '回收结果未知，请先核对。');
      await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('credential-recycle-submit')),
            )
            .onPressed,
        isNull,
      );
      await capture(t, 'credential-1280-dark-200-recycle-unknown');
      await tap(t, find.byKey(const ValueKey('credential-recycle-lookup')));
      await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
      expect((await model.source.loadSummary()).records, count - 1);
      final entry = (await model.source.queryRecycled(
        keyword: 'Azure SSH',
      )).items.single;
      await tap(t, find.byKey(const ValueKey('library-open-recycle')));
      await tap(t, find.byKey(ValueKey('library-recycle-view-${entry.id}')));
      expect(find.text('恢复后：材料 v2 · 已停用'), findsOneWidget);
      await t.ensureVisible(find.text('恢复后：材料 v2 · 已停用'));
      await t.pumpAndSettle();
      await capture(t, 'credential-1280-dark-200-recycled-review');
      await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
      expect((await model.source.loadSummary()).records, count);
      expect((await model.source.credentials.read(ssh)).enabled, isFalse);
      await tap(t, find.text('查看已恢复资料'));
      expect(find.byType(LibraryCredential), findsOneWidget);
      await capture(t, 'credential-1280-dark-200-restored-reading');
    },
  );
  check(
    'permanent purge needs second confirmation and failed purge retains masked owner snapshot',
    (t) async {
      final model = await start(t, 'Azure SSH 私钥', dark: true);
      await action(t, '移到回收站');
      await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
      final entry = (await model.source.queryRecycled(
        keyword: 'Azure SSH',
      )).items.single;
      await tap(t, find.byKey(const ValueKey('library-open-recycle')));
      await tap(t, find.byKey(ValueKey('library-recycle-view-${entry.id}')));
      await tap(t, find.byKey(const ValueKey('credential-recycle-purge')));
      await capture(t, 'credential-1440-dark-purge-review');
      await tap(t, find.text('返回查看'));
      expect((await model.source.queryRecycled(keyword: 'Azure SSH')).total, 1);
      await tap(t, find.byKey(const ValueKey('credential-recycle-purge')));
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('offline', '清理失败，回收内容仍保留。');
      await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
      expect(find.text('清理失败，回收内容仍保留。'), findsOneWidget);
      expect(
        (await model.source.credentials.readRecycled(entry.id)).detail.mask,
        '••••••••',
      );
      await capture(t, 'credential-1440-dark-purge-failure');
      await tap(t, find.byKey(const ValueKey('credential-recycle-submit')));
      expect((await model.source.queryRecycled(keyword: 'Azure SSH')).total, 0);
      expect(
        find.byKey(ValueKey('library-recycle-view-${entry.id}')),
        findsNothing,
      );
      expect(find.byType(DesktopDialog), findsNothing);
    },
  );
}
