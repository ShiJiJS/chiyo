import 'support/workspace_fixtures.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_adoption_test.dart' show installDomain, generic;

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
  });
  Future<void> tap(WidgetTester t, Finder f) async {
    if (await prepareFixtureAction(t, f)) return;
    await t.ensureVisible(f);
    await t.pumpAndSettle();
    await t.tap(f);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> enter(WidgetTester t, String key, String value) async {
    final f = find.byKey(ValueKey(key));
    await t.ensureVisible(f);
    await t.enterText(f, value);
    await t.pumpAndSettle();
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('adoption-capture')),
    );
    await t.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<
    ({
      LibraryController library,
      SampleWorkspaceSource source,
      WorkspaceDetail original,
    })
  >
  start(WidgetTester t, {bool dark = false, bool file = false}) async {
    t.view.physicalSize = dark ? const Size(1280, 800) : const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = dark ? 2 : 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('adoption-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    final library = t.widget<LibraryPage>(find.byType(LibraryPage)).controller,
        source = library.source as SampleWorkspaceSource;
    await installDomain(source);
    final original = file
        ? await source.readDetail(
            const WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume'),
          )
        : await generic(source);
    await library.openRelated(original.record.ref);
    await t.pumpAndSettle();
    return (library: library, source: source, original: original);
  }

  Future<void> open(WidgetTester t) async {
    await tap(t, find.byKey(const ValueKey('library-record-actions')));
    await tap(t, find.text('采用资料模板'));
    await tap(
      t,
      find.byKey(const ValueKey('adoption-target-local.domain/domain')),
    );
  }

  Future<void> mapBody(WidgetTester t) async {
    await tap(t, find.byKey(const ValueKey('adoption-source-domain')));
    await tap(t, find.text('内容 · multiline').last);
    await tap(t, find.byKey(const ValueKey('adoption-meaning-domain')));
  }

  testWidgets(
    'actual record action maps same-meaning fields, previews retained collisions and reads back the same classified record',
    (t) async {
      final m = await start(t);
      await open(t);
      await mapBody(t);
      await t.ensureVisible(
        find.byKey(const ValueKey('adoption-field-domain')),
      );
      await t.pumpAndSettle();
      await capture(t, 'adoption-1440-light-mapping');
      await tap(t, find.byKey(const ValueKey('adoption-preview')));
      expect(find.text('内容 → 保留原身份'), findsOneWidget);
      expect(find.text('以下内容也会继续保存（1）'), findsOneWidget);
      expect(
        (await m.source.readDetail(m.original.record.ref)).record.type.id,
        'generic',
      );
      await capture(t, 'adoption-1440-light-review');
      await tap(t, find.byKey(const ValueKey('adoption-apply')));
      expect(find.byType(DesktopDialog), findsNothing);
      final after = m.library.detail!;
      expect(after.record.ref, m.original.record.ref);
      expect(after.record.directoryId, m.original.record.directoryId);
      expect(after.record.type.id, 'local.domain/domain');
      expect(after.fieldIds['domain'], m.original.fieldIds['body']);
      expect(find.text('补充内容'), findsNothing);
      expect(find.text('保留的原字段'), findsNothing);
      await t.ensureVisible(find.text('原来同名但不同含义的内容'));
      await t.pumpAndSettle();
      await capture(t, 'adoption-1440-light-result');
      await tap(t, find.text('编辑信息'));
      final key = after.retainedFields.single['key'] as String;
      await enter(t, 'library-edit-$key', '保留内容可继续编辑');
      await tap(t, find.byKey(const ValueKey('library-edit-save')));
      expect(m.library.detail!.values[key], '保留内容可继续编辑');
      expect(m.library.detail!.fieldIds, after.fieldIds);
    },
  );

  testWidgets(
    'dark200 incompatible attachment mapping shows a problem, allows adjustment and preserves original versions',
    (t) async {
      final m = await start(t, dark: true, file: true);
      await open(t);
      await tap(t, find.byKey(const ValueKey('adoption-source-domain')));
      final selector = t.widget<DesktopSelect<String>>(
        find.byKey(const ValueKey('adoption-source-domain')),
      );
      final fileItem = selector.items.singleWhere((i) => i.value == 'file');
      await tap(t, find.byWidget(fileItem.child).last);
      await tap(t, find.byKey(const ValueKey('adoption-preview')));
      expect(find.text('内容形态不兼容，原字段将保留，请改选来源或新字段。'), findsOneWidget);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('adoption-apply')))
            .onPressed,
        isNull,
      );
      await t.ensureVisible(find.text('内容形态不兼容，原字段将保留，请改选来源或新字段。'));
      await t.pumpAndSettle();
      await capture(t, 'adoption-1280-dark-200-conflict');
      await tap(t, find.byKey(const ValueKey('adoption-back')));
      await tap(t, find.byKey(const ValueKey('adoption-source-domain')));
      await tap(t, find.text('新字段').last);
      await enter(t, 'adoption-value-domain', 'resume.example');
      await tap(t, find.byKey(const ValueKey('adoption-preview')));
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('adoption-apply')))
            .onPressed,
        isNotNull,
      );
      await tap(t, find.byKey(const ValueKey('adoption-apply')));
      final after = m.library.detail!,
          key =
              after.retainedFields.singleWhere(
                    (f) => f['type'] == 'file',
                  )['key']
                  as String;
      expect(after.values[key], m.original.values['file']);
      expect(
        (await m.source.loadFileHistory(after.record.ref, key)).versions,
        hasLength(2),
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'stale preview requires reread; failed save keeps mapping and committed lost reply freezes then reconciles exact plan',
    (t) async {
      final m = await start(t);
      await open(t);
      await mapBody(t);
      await tap(t, find.byKey(const ValueKey('adoption-preview')));
      m.source.nextSaveFailure = const WorkspaceFailure(
        'offline',
        '采用保存失败，映射保留',
      );
      await tap(t, find.byKey(const ValueKey('adoption-apply')));
      expect(find.text('采用保存失败，映射保留'), findsOneWidget);
      await m.source.saveRecord(
        WorkspaceEdit(
          operationId: 'while-reviewing-adoption',
          expectedVersion: m.original.version,
          record: m.original.record,
          values: {'body': 'updated.example'},
        ),
      );
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('adoption-apply')));
      expect(find.text('资料或目标模板已变化，请重新预览字段对应。'), findsOneWidget);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('adoption-apply')))
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('adoption-refresh')));
      expect(
        find.descendant(
          of: find.byType(DesktopDialog),
          matching: find.text('updated.example'),
        ),
        findsOneWidget,
      );
      await tap(t, find.byKey(const ValueKey('adoption-preview')));
      m.source.loseNextRecordReply = true;
      await tap(t, find.byKey(const ValueKey('adoption-apply')));
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('adoption-cancel')),
            )
            .onPressed,
        isNull,
      );
      expect(find.byKey(const ValueKey('adoption-back')), findsNothing);
      await tap(t, find.byKey(const ValueKey('desktop-dialog-close')));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(DesktopDialog), findsOneWidget);
      m.source.setScenario(SampleWorkspaceScenario.failure);
      await tap(t, find.byKey(const ValueKey('adoption-reconcile')));
      expect(find.text('仍无法确认结果，请稍后核对。'), findsOneWidget);
      await capture(t, 'adoption-1440-light-unknown');
      m.source.setScenario(SampleWorkspaceScenario.ready);
      await tap(t, find.byKey(const ValueKey('adoption-reconcile')));
      expect(find.byType(DesktopDialog), findsNothing);
      expect(m.library.detail!.record.ref, m.original.record.ref);
      expect(m.library.detail!.values['domain'], 'updated.example');
    },
  );

  testWidgets(
    'uncommitted unknown requires a new preview; cancelled waiting reads never reopen or write',
    (t) async {
      final m = await start(t);
      await open(t);
      await mapBody(t);
      await tap(t, find.byKey(const ValueKey('adoption-preview')));
      m.source.nextSaveFailure = const WorkspaceFailure(
        'unknown_outcome',
        '合成未提交未知',
      );
      await tap(t, find.byKey(const ValueKey('adoption-apply')));
      await tap(t, find.byKey(const ValueKey('adoption-reconcile')));
      expect(find.text('已确认尚未提交，原映射保留。请重新预览后再决定。'), findsOneWidget);
      expect(
        t
            .widget<DesktopButton>(find.byKey(const ValueKey('adoption-apply')))
            .onPressed,
        isNull,
      );
      await tap(t, find.byKey(const ValueKey('adoption-back')));
      await tap(t, find.byKey(const ValueKey('adoption-preview')));
      await tap(t, find.byKey(const ValueKey('adoption-cancel')));
      expect(
        (await m.source.readDetail(m.original.record.ref)).version,
        m.original.version,
      );
      await tap(t, find.byKey(const ValueKey('library-record-actions')));
      m.source.setScenario(SampleWorkspaceScenario.waiting);
      await tap(t, find.text('采用资料模板'));
      expect(find.text('正在读取资料与模板…'), findsOneWidget);
      await tap(t, find.byKey(const ValueKey('adoption-cancel')));
      m.source.setScenario(SampleWorkspaceScenario.ready);
      await t.pumpAndSettle();
      expect(find.byType(DesktopDialog), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
