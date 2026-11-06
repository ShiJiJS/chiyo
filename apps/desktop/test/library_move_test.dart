import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/library_move_controller.dart';
import 'package:info_desktop/workspace/library_move_dialog.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Source extends OwnerWorkspaceSource {
  _Source(core.OwnerAccess owner)
    : super(owner: owner, refreshInterval: Duration.zero);
  bool loseBefore = false,
      loseAfter = false,
      wrongReceipt = false,
      failSave = false;
  int writes = 0, lookups = 0;
  @override
  Future<WorkspaceLibraryMoveReceipt> moveLibrarySelection(
    WorkspaceLibraryMoveCommand command,
  ) async {
    writes++;
    if (failSave) throw const WorkspaceFailure('save_failed', '合成保存失败，原位置未变。');
    if (loseBefore) {
      loseBefore = false;
      throw StateError('synthetic loss before commit');
    }
    final result = await super.moveLibrarySelection(command);
    if (loseAfter) {
      loseAfter = false;
      throw StateError('synthetic reply loss');
    }
    return result;
  }

  @override
  Future<WorkspaceLibraryMoveReceipt?> libraryMoveOperationReceipt(
    String id,
  ) async {
    lookups++;
    final result = await super.libraryMoveOperationReceipt(id);
    return result == null || !wrongReceipt
        ? result
        : WorkspaceLibraryMoveReceipt(
            operationId: result.operationId,
            inputHash: '0' * 64,
            targetId: result.targetId,
          );
  }
}

class _Fixture {
  _Fixture(
    this.service,
    this.source,
    this.root,
    this.child,
    this.parent,
    this.target,
    this.item,
    this.direct,
    this.credential,
  );
  final core.InformationService service;
  final _Source source;
  final core.InformationDirectory root, child, parent, target;
  final core.InformationItem item, direct;
  final core.ManagedCredential credential;
  static Future<_Fixture> create() async {
    final service = core.InformationService(
      repository: core.MemoryInformationRepository(),
    );
    final root = await service.owner.createDirectory('服务');
    final child = await service.owner.createDirectory('配置', parentId: root.id);
    final parent = await service.owner.createDirectory('目标上级');
    final target = await service.owner.createDirectory(
      '目标',
      parentId: parent.id,
    );
    final item = await service.owner.createInformation('服务器资料', '', [
      const core.FieldInput('正文', '', 'PRIVATE-NESTED'),
    ], directoryId: child.id);
    final direct = await service.owner.createInformation('独立资料', '', [
      const core.FieldInput('正文', '', 'PRIVATE-DIRECT'),
    ]);
    final credential = await service.owner.createStringCredential(
      name: '应用凭据',
      publicPurpose: '',
      secret: 'PRIVATE-TOKEN',
    );
    return _Fixture(
      service,
      _Source(service.owner),
      root,
      child,
      parent,
      target,
      item,
      direct,
      credential,
    );
  }

  WorkspaceLibrarySelection get selection => WorkspaceLibrarySelection(
    directoryIds: [root.id, child.id],
    records: [
      WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
      WorkspaceRecordRef(WorkspaceRecordKind.information, direct.id),
      WorkspaceRecordRef(WorkspaceRecordKind.credential, credential.id),
    ],
  );
  Future<void> close() async {
    await source.dispose();
    await service.close();
  }
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pumpAndSettle();
}

Future<void> _close(WidgetTester t, _Fixture f) async {
  await t.pumpWidget(const SizedBox());
  await t.runAsync(f.source.dispose);
  var closed = false;
  final closing = f.service.close().then((_) => closed = true);
  for (var i = 0; i < 100 && !closed; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 10));
  }
  expect(closed, isTrue);
  await closing;
}

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

  test(
    'conflicts prevent writes; a known failed save keeps the chosen target and scope',
    () async {
      final f = await _Fixture.create();
      final m = LibraryMoveController(
        f.source,
        f.selection,
        targetId: f.target.id,
      );
      try {
        final collision = await f.service.owner.createDirectory(
          '服务',
          parentId: f.target.id,
        );
        await m.load();
        expect(m.canSave, isFalse);
        expect(m.preview!.conflicts.single, contains('同名目录'));
        await m.save();
        expect(f.source.writes, 0);
        await f.service.owner.deleteDirectory(collision.id, collision.version);
        await m.load();
        f.source.failSave = true;
        await m.save();
        expect(m.failure?.code, 'save_failed');
        expect(m.uncertain, isFalse);
        expect(m.targetId, f.target.id);
        expect(m.preview!.scope.directories, hasLength(2));
        expect(f.service.owner.credential(f.credential.id).directoryId, isNull);
        f.source.failSave = false;
        await m.save();
        expect(m.receipt, isNotNull);
        expect(f.source.writes, 2);
      } finally {
        m.dispose();
        await f.close();
      }
    },
  );
  test(
    'Owner move adapter returns full paths and reconciles exactly the submitted command',
    () async {
      final f = await _Fixture.create();
      try {
        final p = await f.source.previewLibraryMove(f.selection, f.target.id);
        expect(p.targetPath, ['目标上级', '目标']);
        expect(p.roots, [f.root.id]);
        expect(p.records.map((r) => r.ref.id).toSet(), {
          f.direct.id,
          f.credential.id,
        });
        expect(p.scope.directories, hasLength(2));
        expect(p.scope.informationCount, 2);
        final command = WorkspaceLibraryMoveCommand(
          operationId: 'adapter-move',
          selection: f.selection,
          targetId: f.target.id,
          reviewToken: p.token,
        );
        final receipt = await f.source.moveLibrarySelection(command);
        expect(receipt.matches(command), isTrue);
        expect(
          (await f.source.libraryMoveOperationReceipt(
            command.operationId,
          ))!.matches(command),
          isTrue,
        );
        expect(
          f.service.owner.directories
              .singleWhere((d) => d.id == f.root.id)
              .parentId,
          f.target.id,
        );
        expect(
          f.service.owner.credential(f.credential.id).useGeneration,
          f.credential.useGeneration,
        );
      } finally {
        await f.close();
      }
    },
  );

  test(
    'lost move reply freezes the original target until a matching read-only acknowledgement arrives',
    () async {
      final f = await _Fixture.create();
      final m = LibraryMoveController(
        f.source,
        f.selection,
        targetId: f.target.id,
      );
      try {
        await m.load();
        f.source.loseAfter = true;
        await m.save();
        expect(m.uncertain, isTrue);
        expect(f.source.writes, 1);
        await m.chooseTarget(null);
        await m.save();
        expect(m.targetId, f.target.id);
        expect(f.source.writes, 1);
        f.source.wrongReceipt = true;
        await m.reconcile();
        expect(m.uncertain, isTrue);
        expect(m.receipt, isNull);
        f.source.wrongReceipt = false;
        await m.reconcile();
        expect(m.receipt?.targetId, f.target.id);
        expect(f.source.writes, 1);
        expect(f.source.lookups, 2);
        expect(m.canSave, isFalse);
      } finally {
        m.dispose();
        await f.close();
      }
    },
  );

  test(
    'confirmed absence refreshes the preview and never automatically repeats a write',
    () async {
      final f = await _Fixture.create();
      final m = LibraryMoveController(
        f.source,
        f.selection,
        targetId: f.target.id,
      );
      try {
        await m.load();
        f.source.loseBefore = true;
        await m.save();
        expect(m.uncertain, isTrue);
        await m.reconcile();
        expect(f.source.writes, 1);
        expect(m.uncertain, isFalse);
        expect(m.canSave, isTrue);
        expect(m.notice, contains('尚未提交'));
        expect(f.service.owner.credential(f.credential.id).directoryId, isNull);
        await m.save();
        expect(m.receipt, isNotNull);
        expect(f.source.writes, 2);
      } finally {
        m.dispose();
        await f.close();
      }
    },
  );

  testWidgets(
    'shared move dialog chooses a complete path, excludes selected subtrees, cancels and saves as one operation',
    (t) async {
      t.view.physicalSize = const Size(1100, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = (await t.runAsync(_Fixture.create))!;
      WorkspaceLibraryMoveReceipt? receipt;
      try {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    receipt = await showLibraryMove(
                      context,
                      f.source,
                      f.selection,
                    );
                  },
                  child: const Text('移动'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('移动'));
        await _settle(t);
        expect(find.text('2 个目录、2 条资料、1 项凭据'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('library-move-pick-target')));
        await _settle(t);
        expect(find.text('服务'), findsNothing);
        expect(find.text('服务 / 配置'), findsNothing);
        await t.tap(find.text('目标上级 / 目标'));
        await _settle(t);
        expect(find.text('目标：目标上级 / 目标'), findsOneWidget);
        await t.tap(find.text('查看完整范围'));
        await t.pumpAndSettle();
        expect(find.textContaining('PRIVATE-'), findsNothing);
        expect(find.text('服务器资料'), findsOneWidget);
        await t.tap(find.text('取消'));
        await _settle(t);
        expect(receipt, isNull);
        expect(f.source.writes, 0);
        await t.tap(find.text('移动'));
        await _settle(t);
        await t.tap(find.byKey(const ValueKey('library-move-pick-target')));
        await _settle(t);
        await t.tap(find.text('目标上级 / 目标'));
        await _settle(t);
        await t.tap(find.byKey(const ValueKey('library-move-confirm')));
        await _settle(t);
        expect(receipt?.targetId, f.target.id);
        expect(f.source.writes, 1);
        expect(
          f.service.owner.directories
              .singleWhere((d) => d.id == f.child.id)
              .parentId,
          f.root.id,
        );
        expect(
          f.service.owner.credential(f.credential.id).directoryId,
          f.target.id,
        );
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f);
      }
    },
  );

  testWidgets(
    'lost target can be replaced; an uncertain dialog cannot be dismissed or submitted again',
    (t) async {
      t.view.physicalSize = const Size(1100, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = (await t.runAsync(_Fixture.create))!;
      try {
        await t.runAsync(
          () => f.service.owner.deleteDirectory(f.target.id, f.target.version),
        );
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showLibraryMove(
                    context,
                    f.source,
                    f.selection,
                    initialTarget: f.target.id,
                  ),
                  child: const Text('移动'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('移动'));
        await _settle(t);
        expect(find.text('目标目录已移除，请重新选择位置。'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('library-move-pick-target')));
        await _settle(t);
        await t.tap(find.text('目标上级').last);
        await _settle(t);
        f.source.loseAfter = true;
        await t.tap(find.byKey(const ValueKey('library-move-confirm')));
        await _settle(t);
        expect(
          t
              .widget<DesktopButton>(
                find.byKey(const ValueKey('library-move-confirm')),
              )
              .onPressed,
          isNull,
        );
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(t);
        expect(find.text('移动所选内容'), findsOneWidget);
        expect(f.source.writes, 1);
        await t.tap(find.byKey(const ValueKey('library-move-reconcile')));
        await _settle(t);
        expect(find.text('移动所选内容'), findsNothing);
        expect(f.source.writes, 1);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f);
      }
    },
  );

  testWidgets(
    'production dark move window stays scrollable with large text and a long scope',
    (t) async {
      t.view.physicalSize = const Size(510, 760);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = (await t.runAsync(_Fixture.create))!;
      try {
        await t.runAsync(() async {
          for (var i = 0; i < 80; i++) {
            await f.service.owner.createDirectory(
              '较长的子目录名称第$i项',
              parentId: f.root.id,
            );
          }
        });
        await t.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('move-capture'),
            child: MaterialApp(
              theme: zhiyuTheme(Brightness.dark),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.4)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showLibraryMove(
                      context,
                      f.source,
                      f.selection,
                      initialTarget: f.target.id,
                    ),
                    child: const Text('移动'),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('移动'));
        await _settle(t);
        expect(find.text('82 个目录、2 条资料、1 项凭据'), findsOneWidget);
        await t.ensureVisible(find.text('查看完整范围'));
        await t.tap(find.text('查看完整范围'));
        await t.pumpAndSettle();
        expect(
          t
              .widget<ListView>(
                find.byKey(const ValueKey('library-move-scope')),
              )
              .childrenDelegate
              .estimatedChildCount,
          85,
        );
        if (evidence.isNotEmpty) {
          final boundary = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('move-capture')),
          );
          await t.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '$evidence/dark-narrow-move.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(t);
        expect(f.source.writes, 0);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f);
      }
    },
  );

  testWidgets(
    'library mixed multi-selection cancels intact then moves once and refreshes placement and counts',
    (t) async {
      t.view.physicalSize = const Size(1100, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = (await t.runAsync(_Fixture.create))!;
      final m = LibraryController(f.source);
      await t.runAsync(
        () => m.load(const WorkspaceQuery(sort: WorkspaceSort.name)),
      );
      try {
        await t.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('library-selection-capture'),
            child: MaterialApp(
              theme: zhiyuTheme(Brightness.dark),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.4)),
                child: child!,
              ),
              home: Scaffold(
                body: LibraryPage(controller: m, onNavigate: (_, _) {}),
              ),
            ),
          ),
        );
        await _settle(t);
        await t.tap(find.byKey(const ValueKey('library-select-mode')));
        await _settle(t);
        for (final key in [
          'library-directory-${f.root.id}',
          'library-directory-${f.child.id}',
          'library-record-information:${f.item.id}',
          'library-record-credential:${f.credential.id}',
        ]) {
          await t.tap(find.byKey(ValueKey(key)));
          await _settle(t);
        }
        expect(find.text('已选 4 项'), findsOneWidget);
        if (evidence.isNotEmpty) {
          final boundary = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('library-selection-capture')),
          );
          await t.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '$evidence/library-multiselect-dark.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await t.tap(find.byKey(const ValueKey('library-selection-move')));
        await _settle(t);
        expect(find.text('2 个目录、1 条资料、1 项凭据'), findsOneWidget);
        await t.tap(find.text('取消'));
        await _settle(t);
        expect(m.selectedCount, 4);
        expect(f.source.writes, 0);
        await t.tap(find.byKey(const ValueKey('library-selection-move')));
        await _settle(t);
        await t.tap(find.byKey(const ValueKey('library-move-pick-target')));
        await _settle(t);
        await t.tap(find.text('目标上级 / 目标'));
        await _settle(t);
        await t.tap(find.byKey(const ValueKey('library-move-confirm')));
        await _settle(t);
        expect(f.source.writes, 1);
        expect(m.selectedCount, 0);
        expect(m.selecting, isFalse);
        expect(
          f.service.owner.directories
              .singleWhere((d) => d.id == f.root.id)
              .parentId,
          f.target.id,
        );
        expect(
          f.service.owner.credential(f.credential.id).directoryId,
          f.target.id,
        );
        expect(
          f.service.owner.information
              .singleWhere((i) => i.id == f.direct.id)
              .directoryId,
          isNull,
        );
        expect(m.catalog!.directoryCounts[f.target.id], 2);
        expect(t.takeException(), isNull);
      } finally {
        m.dispose();
        await _close(t, f);
      }
    },
  );

  testWidgets(
    'Mac right-click, Control-click and detail menu reach the common move and recycle dialogs',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = (await t.runAsync(_Fixture.create))!;
      final m = LibraryController(f.source);
      await t.runAsync(
        () => m.load(const WorkspaceQuery(sort: WorkspaceSort.name)),
      );
      try {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibraryPage(controller: m, onNavigate: (_, _) {}),
            ),
          ),
        );
        await _settle(t);
        final directory = find.byKey(
          ValueKey('library-directory-${f.root.id}'),
        );
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.tap(directory, kind: PointerDeviceKind.mouse);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await _settle(t);
        expect(
          m.query.directoryId,
          isNull,
          reason: 'Control-click must not also open the directory',
        );
        expect(find.text('新建子目录'), findsOneWidget);
        await t.tap(find.text('重命名'));
        await _settle(t);
        expect(find.text('重命名目录'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('library-directory-parent')),
          findsNothing,
        );
        await t.tap(find.text('取消'));
        await _settle(t);
        final record = find.byKey(
          ValueKey('library-record-information:${f.direct.id}'),
        );
        await t.tap(
          record,
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await _settle(t);
        await t.tap(find.text('移动'));
        await _settle(t);
        expect(find.text('0 个目录、1 条资料、0 项凭据'), findsOneWidget);
        await t.tap(find.text('取消'));
        await _settle(t);
        await t.tap(record);
        await _settle(t);
        await t.tap(find.byKey(const ValueKey('library-record-actions')));
        await _settle(t);
        await t.tap(find.text('移动'));
        await _settle(t);
        expect(
          find.byKey(const ValueKey('library-move-confirm')),
          findsOneWidget,
        );
        await t.tap(find.text('取消'));
        await _settle(t);
        await t.tap(find.byKey(const ValueKey('library-record-actions')));
        await _settle(t);
        await t.tap(find.text('移到回收站'));
        await _settle(t);
        expect(
          find.byKey(const ValueKey('library-recycle-submit')),
          findsOneWidget,
        );
        await t.tap(find.text('取消'));
        await _settle(t);
        expect(f.source.writes, 0);
        expect(f.service.owner.recycleEntries, isEmpty);
        expect(t.takeException(), isNull);
      } finally {
        m.dispose();
        await _close(t, f);
      }
    },
  );

  testWidgets(
    'selected parent, child, information and credential recycle as one group from the context menu',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = (await t.runAsync(_Fixture.create))!;
      final m = LibraryController(f.source);
      await t.runAsync(
        () => m.load(const WorkspaceQuery(sort: WorkspaceSort.name)),
      );
      try {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibraryPage(controller: m, onNavigate: (_, _) {}),
            ),
          ),
        );
        await _settle(t);
        await t.tap(find.byKey(const ValueKey('library-select-mode')));
        await _settle(t);
        final record = find.byKey(
          ValueKey('library-record-information:${f.item.id}'),
        );
        for (final key in [
          'library-directory-${f.root.id}',
          'library-directory-${f.child.id}',
          'library-record-information:${f.item.id}',
          'library-record-credential:${f.credential.id}',
        ]) {
          await t.tap(find.byKey(ValueKey(key)));
          await _settle(t);
        }
        await t.tap(find.byKey(const ValueKey('library-selection-recycle')));
        await _settle(t);
        await t.tap(find.text('取消'));
        await _settle(t);
        expect(m.selectedCount, 4);
        await t.tap(
          record,
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await _settle(t);
        await t.tap(find.text('移到回收站').last);
        await _settle(t);
        expect(find.text('2 个目录、1 条资料、1 项凭据'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('batch-recycle-confirm')));
        await _settle(t);
        expect(m.selecting, isFalse);
        expect(m.selectedCount, 0);
        final batch = f.service.owner.libraryRecycleBatches.single;
        expect(batch.directories.map((d) => d.id).toSet(), {
          f.root.id,
          f.child.id,
        });
        expect(batch.records.map((r) => r.id).toSet(), {
          f.item.id,
          f.credential.id,
        });
        expect(f.service.owner.information.single.id, f.direct.id);
        expect(m.results!.total, 1);
        expect(m.catalog!.recycledCount, 1);
        expect(m.catalog!.directoryCounts['all'], 1);
        expect(t.takeException(), isNull);
      } finally {
        m.dispose();
        await _close(t, f);
      }
    },
  );

  test(
    'manual ordering uses complete siblings before filtering and paging and observation detects a pure reorder',
    () async {
      final f = await _Fixture.create();
      try {
        final a = await f.service.owner.createInformation('可见A', '', [
          const core.FieldInput('正文', '', 'PRIVATE-A'),
        ], directoryId: f.child.id);
        final hidden = await f.service.owner.createInformation('隐藏B', '', [
          const core.FieldInput('正文', '', 'PRIVATE-B'),
        ], directoryId: f.child.id);
        final c = await f.service.owner.createInformation('可见C', '', [
          const core.FieldInput('正文', '', 'PRIVATE-C'),
        ], directoryId: f.child.id);
        f.source.refreshFromOwner();
        await Future<void>.delayed(Duration.zero);
        final query = WorkspaceQuery(
          directoryId: f.child.id,
          keyword: '可见',
          sort: WorkspaceSort.manual,
          limit: 1,
        );
        expect((await f.source.queryRecords(query)).items.single.ref.id, a.id);
        final selection = WorkspaceLibrarySelection(
          records: [WorkspaceRecordRef(WorkspaceRecordKind.information, c.id)],
        );
        final position = WorkspaceLibraryPosition.record(
          WorkspaceRecordRef(WorkspaceRecordKind.information, a.id),
        );
        final preview = await f.source.previewLibraryMove(
          selection,
          f.child.id,
          position: position,
        );
        expect(preview.anchorName, '可见A');
        final command = WorkspaceLibraryMoveCommand(
          operationId: 'manual-source-order',
          selection: selection,
          targetId: f.child.id,
          reviewToken: preview.token,
          position: position,
        );
        expect(
          (await f.source.moveLibrarySelection(command)).matches(command),
          isTrue,
        );
        expect((await f.source.queryRecords(query)).items.single.ref.id, c.id);
        expect(
          (await f.source.queryRecords(
            query.copyWith(offset: 1),
          )).items.single.ref.id,
          a.id,
        );
        final complete = await f.source.queryRecords(
          query.copyWith(keyword: '', limit: 50),
        );
        expect(complete.items.map((r) => r.ref.id), [
          f.item.id,
          c.id,
          a.id,
          hidden.id,
        ]);
        expect(
          f.service.owner.information
              .singleWhere((i) => i.id == hidden.id)
              .version,
          hidden.version,
        );
        f.source.refreshFromOwner();
        await Future<void>.delayed(Duration.zero);
        final changed = f.source.changes.first;
        final coreSelection = core.LibrarySelection(informationIds: [a.id]);
        final corePosition = core.LibraryMovePosition(
          core.LibraryEntryRef('information', hidden.id),
          after: true,
        );
        final p = await f.service.owner.previewLibraryMove(
          coreSelection,
          f.child.id,
          position: corePosition,
        );
        await f.service.owner.moveLibrarySelection(
          'external-reorder',
          coreSelection,
          f.child.id,
          p.token,
          position: corePosition,
        );
        f.source.refreshFromOwner();
        await changed.timeout(const Duration(seconds: 2));
        expect(
          (await f.source.queryRecords(
            query.copyWith(keyword: '', limit: 50),
          )).items.map((r) => r.ref.id),
          [f.item.id, c.id, hidden.id, a.id],
        );
        expect(
          f.service.owner.information.singleWhere((i) => i.id == a.id).version,
          a.version,
        );
      } finally {
        await f.close();
      }
    },
  );

  testWidgets(
    'the common dialog describes before or after placement and preserves the chosen anchor through save',
    (t) async {
      t.view.physicalSize = const Size(1100, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = (await t.runAsync(_Fixture.create))!;
      try {
        final selection = WorkspaceLibrarySelection(
          records: [
            WorkspaceRecordRef(WorkspaceRecordKind.information, f.direct.id),
          ],
        );
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showLibraryMove(
                    context,
                    f.source,
                    selection,
                    initialTarget: f.child.id,
                    position: WorkspaceLibraryPosition.record(
                      WorkspaceRecordRef(
                        WorkspaceRecordKind.information,
                        f.item.id,
                      ),
                    ),
                  ),
                  child: const Text('调整顺序'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('调整顺序'));
        await _settle(t);
        expect(find.text('目标：服务 / 配置'), findsOneWidget);
        expect(find.text('排在“服务器资料”之前'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('library-move-confirm')));
        await _settle(t);
        expect(f.source.writes, 1);
        final rows = (await t.runAsync(
          () => f.source.queryRecords(
            WorkspaceQuery(directoryId: f.child.id, sort: WorkspaceSort.manual),
          ),
        ))!;
        expect(rows.items.map((r) => r.ref.id), [f.direct.id, f.item.id]);
        expect(f.service.owner.credential(f.credential.id).directoryId, isNull);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f);
      }
    },
  );

  testWidgets(
    'library manual view is distinct from name and time sorting and displays the actual full directory',
    (t) async {
      t.view.physicalSize = const Size(1500, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = (await t.runAsync(_Fixture.create))!;
      final m = LibraryController(f.source);
      await t.runAsync(() => m.load(const WorkspaceQuery()));
      try {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibraryPage(controller: m, onNavigate: (_, _) {}),
            ),
          ),
        );
        await _settle(t);
        await t.tap(find.byKey(const ValueKey('library-sort')));
        await _settle(t);
        expect(find.text('最近更新优先'), findsOneWidget);
        expect(find.text('按名称'), findsOneWidget);
        await t.tap(find.text('手动顺序'));
        await _settle(t);
        expect(m.query.sort, WorkspaceSort.manual);
        final card = find.byKey(
          ValueKey('library-record-information:${f.item.id}'),
        );
        expect(
          find.descendant(of: card, matching: find.text('服务 / 配置')),
          findsOneWidget,
        );
        expect(find.text('不分组 · 手动顺序'), findsOneWidget);
        expect(t.takeException(), isNull);
      } finally {
        m.dispose();
        await _close(t, f);
      }
    },
  );
}
