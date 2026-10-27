import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/backup_page.dart';
import 'package:info_desktop/workspace/backup_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _DeferredBackups extends Fake implements WorkspaceBackupSource {
  final reads = <Completer<WorkspaceBackupStatus>>[];
  @override
  Future<WorkspaceBackupStatus> status() {
    final read = Completer<WorkspaceBackupStatus>();
    reads.add(read);
    return read.future;
  }
}

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
  Future<void> ready(WidgetTester t) async {
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> tap(WidgetTester t, String key, {bool pending = false}) async {
    final f = find.byKey(ValueKey(key));
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    if (pending) {
      await t.pump();
    } else {
      await ready(t);
    }
  }

  Future<void> idle(WidgetTester t, BackupController m) async {
    for (var i = 0; i < 300; i++) {
      await t.pump(const Duration(milliseconds: 20));
      if (!m.busy && !m.loading) {
        await ready(t);
        return;
      }
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    fail('backup source did not complete');
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    if (name.contains('review') ||
        name.contains('result') ||
        name.endsWith('restored')) {
      await t.ensureVisible(find.byKey(const ValueKey('backup-counts')));
      await ready(t);
    }
    if (name.contains('wrong-key')) {
      await t.ensureVisible(find.byKey(const ValueKey('backup-error')));
      await ready(t);
    }
    if (name.contains('cleanup-pending')) {
      await t.ensureVisible(find.byKey(const ValueKey('backup-cleanup')));
      await ready(t);
    }
    await t.runAsync(() async {
      final b = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('backup-capture')),
          ),
          image = await b.toImage(pixelRatio: 1),
          bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<SampleWorkspaceSource> start(
    WidgetTester t, {
    bool dark = false,
  }) async {
    t.view.physicalSize = dark ? const Size(1280, 800) : const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = dark ? 2 : 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('backup-capture'),
        child: PreviewWorkspace(),
      ),
    );
    await ready(t);
    final s =
        t.widget<LibraryPage>(find.byType(LibraryPage)).controller.source
            as SampleWorkspaceSource;
    await tap(t, 'preview-guide');
    if (dark) {
      await tap(t, 'preview-theme-dark');
      await tap(t, 'preview-guide');
    }
    await tap(t, 'preview-backup-complete');
    expect(find.byType(WorkspaceBackupPage), findsOneWidget);
    return s;
  }

  BackupController model(WidgetTester t) => t
      .widget<WorkspaceBackupPage>(find.byType(WorkspaceBackupPage))
      .controller;
  Future<void> select(
    WidgetTester t,
    WorkspaceBackupPick kind, {
    String? id,
  }) async {
    await tap(t, 'backup-pick-${kind.name}');
    final choices = find.byWidgetPredicate(
      (w) =>
          w is DesktopButton &&
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('backup-resource-'),
    );
    final f = id == null
        ? choices.first
        : find.byKey(ValueKey('backup-resource-$id'));
    await t.ensureVisible(f);
    await ready(t);
    await t.tap(f);
    await ready(t);
  }

  Future<void> export(WidgetTester t) async {
    final m = model(t);
    await tap(t, 'backup-open-export');
    await tap(t, 'backup-enable');
    await tap(t, 'backup-key-reveal');
    expect(m.revealedKey, startsWith('preview-recovery:'));
    await select(t, WorkspaceBackupPick.keyOutput);
    await tap(t, 'backup-save-key');
    expect(m.value!.keySaved, true);
    expect(m.revealedKey, isNull);
    await select(t, WorkspaceBackupPick.archiveOutput);
    await tap(t, 'backup-export', pending: true);
    await idle(t, m);
    expect(m.result!.action, WorkspaceBackupAction.export);
    expect(m.result!.counts![WorkspaceBackupCategory.files], greaterThan(4));
    await capture(t, 'backup-1440-light-export-result');
    await tap(t, 'backup-flow-close');
  }

  testWidgets(
    'cold backup status and read failure never claim an empty recipient or enable operations',
    (t) async {
      final source = _DeferredBackups(),
          m = BackupController(source, const Stream.empty());
      addTearDown(m.dispose);
      final pending = m.load();
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: WorkspaceBackupPage(
              controller: m,
              picker: (_) async => null,
              onLibrary: () {},
            ),
          ),
        ),
      );
      await t.pump();
      expect(m.value, isNull);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('backup-open-restore')),
            )
            .onPressed,
        isNull,
      );
      source.reads.first.completeError(
        const WorkspaceFailure('offline', '备份状态读取失败'),
      );
      await pending;
      await ready(t);
      expect(find.text('备份状态读取失败'), findsOneWidget);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('backup-open-export')),
            )
            .onPressed,
        isNull,
      );
      final retry = m.load();
      source.reads.last.complete(
        WorkspaceBackupStatus(
          version: 1,
          keyCreated: false,
          keySaved: false,
          recipientEmpty: false,
          blockers: ['保留的历史'],
          cleanupCount: 0,
        ),
      );
      await retry;
      await ready(t);
      expect(find.textContaining('保留的历史'), findsOneWidget);
      expect(m.value!.recipientEmpty, false);
    },
  );

  testWidgets(
    'real settings entry exports full sample, inspects into empty recipient and restores readable records',
    (t) async {
      final s = await start(t);
      final m = model(t);
      await capture(t, 'backup-1440-light-overview');
      await export(t);
      await tap(t, 'preview-guide');
      await tap(t, 'preview-backup-recipient');
      await tap(t, 'backup-open-restore');
      await select(t, WorkspaceBackupPick.archiveInput);
      await select(t, WorkspaceBackupPick.keyInput);
      await tap(t, 'backup-inspect');
      expect(m.preview, isNotNull);
      expect((await s.queryRecords(const WorkspaceQuery())).total, 0);
      await capture(t, 'backup-1440-light-restore-review');
      await tap(t, 'backup-restore');
      expect(m.result!.action, WorkspaceBackupAction.restore);
      await capture(t, 'backup-1440-light-restored');
      await tap(t, 'backup-open-library');
      expect(find.byType(LibraryPage), findsOneWidget);
      final d = await s.readDetail(
        const WorkspaceRecordRef(WorkspaceRecordKind.information, 'proof'),
      );
      expect(d.record.name, '实习证明');
      expect(
        (await s.queryRecords(const WorkspaceQuery())).total,
        greaterThan(20),
      );
    },
  );

  testWidgets(
    'dark large-text restore errors retain inputs, cancellation does not restore, cleanup retries from settings',
    (t) async {
      final s = await start(t, dark: true), m = model(t);
      // Prepare through the same controller/source; the previous test covers export UI.
      await m.write(WorkspaceBackupAction.enableKey);
      final key = (await s.backups.choices(
        WorkspaceBackupPick.keyOutput,
      )).first;
      await m.pick(WorkspaceBackupPick.keyOutput, (_) async => key);
      await m.write(WorkspaceBackupAction.saveKey);
      final out = (await s.backups.choices(
        WorkspaceBackupPick.archiveOutput,
      )).first;
      await m.pick(WorkspaceBackupPick.archiveOutput, (_) async => out);
      final exporting = m.write(WorkspaceBackupAction.export);
      await idle(t, m);
      await exporting;
      await ready(t);
      await s.prepareBackupRecipient();
      await m.load();
      await ready(t);
      await tap(t, 'backup-open-restore');
      await select(t, WorkspaceBackupPick.archiveInput);
      await select(t, WorkspaceBackupPick.keyInput, id: 'wrong-key');
      await tap(t, 'backup-inspect');
      expect(m.failure!.code, 'invalid_backup');
      expect(m.archiveInput, isNotNull);
      expect(m.keyInput!.id, 'wrong-key');
      await capture(t, 'backup-1280-dark200-wrong-key');
      await tap(t, 'backup-pick-keyInput');
      await tap(t, 'backup-picker-cancel');
      expect(m.keyInput!.id, 'wrong-key');
      final correct = (await s.backups.choices(
        WorkspaceBackupPick.keyInput,
      )).firstWhere((r) => r.id == key.id);
      await select(t, WorkspaceBackupPick.keyInput, id: correct.id);
      await tap(t, 'backup-inspect');
      expect(m.preview, isNotNull);
      await capture(t, 'backup-1280-dark200-restore-review');
      s.backups.nextCleanupFailure = const WorkspaceFailure(
        'cleanup_failed',
        '清理失败',
      );
      await tap(t, 'backup-flow-close');
      expect((await s.backups.status()).recipientEmpty, true);
      expect(m.value!.cleanupCount, 1);
      await capture(t, 'backup-1280-dark200-cleanup-pending');
      await tap(t, 'backup-cleanup');
      expect(m.value!.cleanupCount, 0);
      expect(m.cleanupNotice, isNull);
    },
  );

  testWidgets(
    'unknown backup reply locks modal, section and workspace navigation and reconciles without repeated writes',
    (t) async {
      final s = await start(t), m = model(t);
      await tap(t, 'backup-open-export');
      s.backups.loseNextReply = true;
      await tap(t, 'backup-enable');
      expect(m.uncertain, true);
      final close = t.widget<DesktopButton>(
        find.byKey(const ValueKey('backup-flow-close')),
      );
      expect(close.onPressed, isNull);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await ready(t);
      expect(find.byKey(const ValueKey('backup-enable')), findsOneWidget);
      await capture(t, 'backup-1440-light-unknown');
      await tap(t, 'backup-reconcile');
      expect(m.uncertain, false);
      expect(m.value!.keyCreated, true);
      await tap(t, 'backup-flow-close');
      await tap(t, 'workspace-nav-library');
      expect(find.byType(LibraryPage), findsOneWidget);
    },
  );
}
