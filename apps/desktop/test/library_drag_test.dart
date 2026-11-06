import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Source extends OwnerWorkspaceSource {
  _Source(core.OwnerAccess owner)
    : super(owner: owner, refreshInterval: Duration.zero);
  int writes = 0, lookups = 0;
  bool loseReply = false, failSave = false;
  @override
  Future<WorkspaceLibraryMoveReceipt> moveLibrarySelection(
    WorkspaceLibraryMoveCommand command,
  ) async {
    writes++;
    if (failSave) throw const WorkspaceFailure('save_failed', '合成保存失败，位置保持原样。');
    final receipt = await super.moveLibrarySelection(command);
    if (loseReply) {
      loseReply = false;
      throw StateError('synthetic lost reply');
    }
    return receipt;
  }

  @override
  Future<WorkspaceLibraryMoveReceipt?> libraryMoveOperationReceipt(
    String id,
  ) async {
    lookups++;
    return super.libraryMoveOperationReceipt(id);
  }
}

class _Fixture {
  _Fixture(
    this.service,
    this.source,
    this.root,
    this.child,
    this.target,
    this.a,
    this.b,
    this.c,
    this.outside,
    this.credential,
  );
  final core.InformationService service;
  final _Source source;
  final core.InformationDirectory root, child, target;
  final core.InformationItem a, b, c, outside;
  final core.ManagedCredential credential;
  static Future<_Fixture> create() async {
    final service = core.InformationService(
      repository: core.MemoryInformationRepository(),
    );
    final root = await service.owner.createDirectory('服务');
    final child = await service.owner.createDirectory('配置', parentId: root.id);
    final target = await service.owner.createDirectory('目标');
    final a = await service.owner.createInformation('可见A', '', [
      const core.FieldInput('正文', '', 'PRIVATE-A'),
    ], directoryId: child.id);
    final b = await service.owner.createInformation('隐藏B', '', [
      const core.FieldInput('正文', '', 'PRIVATE-B'),
    ], directoryId: child.id);
    final c = await service.owner.createInformation('可见C', '', [
      const core.FieldInput('正文', '', 'PRIVATE-C'),
    ], directoryId: child.id);
    final outside = await service.owner.createInformation('外部资料', '', [
      const core.FieldInput('正文', '', 'PRIVATE-OUTSIDE'),
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
      target,
      a,
      b,
      c,
      outside,
      credential,
    );
  }

  Finder info(String id) =>
      find.byKey(ValueKey('library-record-information:$id'));
  Finder credentialRow() =>
      find.byKey(ValueKey('library-record-credential:${credential.id}'));
  Finder directory(String id) => find.byKey(ValueKey('library-directory-$id'));
  core.InformationItem current(core.InformationItem item) =>
      service.owner.information.singleWhere((i) => i.id == item.id);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pumpAndSettle();
}

Future<LibraryController> _mount(
  WidgetTester t,
  _Fixture f, {
  WorkspaceQuery query = const WorkspaceQuery(sort: WorkspaceSort.manual),
  Size size = const Size(1500, 1000),
  bool dark = false,
  double textScale = 1,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final m = LibraryController(f.source);
  await t.runAsync(() => m.load(query));
  await t.pumpWidget(
    MaterialApp(
      theme: dark ? zhiyuTheme(Brightness.dark) : null,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('drag-evidence'),
          child: LibraryPage(controller: m, onNavigate: (_, _) {}),
        ),
      ),
    ),
  );
  await _settle(t);
  return m;
}

Future<void> _close(WidgetTester t, _Fixture f, LibraryController m) async {
  await t.pumpWidget(const SizedBox());
  m.dispose();
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

Future<void> _drop(
  WidgetTester t,
  Finder source,
  Offset target, {
  Future<void> Function(TestGesture)? hover,
}) async {
  await t.ensureVisible(source);
  await t.pumpAndSettle();
  final g = await t.startGesture(
    t.getCenter(source),
    kind: PointerDeviceKind.mouse,
  );
  var finished = false;
  try {
    await g.moveBy(const Offset(24, 0));
    await t.pump();
    await g.moveTo(target);
    await t.pump(const Duration(milliseconds: 20));
    if (hover != null) await hover(g);
    await g.up();
    finished = true;
  } finally {
    if (!finished) await g.cancel();
  }
  await _settle(t);
}

Future<void> _focusByTab(WidgetTester t, Finder target) async {
  final element = t.element(target);
  bool within() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (identical(context, element)) return true;
    var found = false;
    context?.visitAncestorElements((ancestor) {
      found = identical(ancestor, element);
      return !found;
    });
    return found;
  }

  for (var i = 0; i < 70 && !within(); i++) {
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
  }
  expect(within(), isTrue, reason: 'Record action should be reachable by Tab');
}

({String id, Rect rect})? _rowAt(
  WidgetTester t,
  Offset point,
  String prefix,
  Set<String> allowed,
) {
  for (final element
      in find
          .byWidgetPredicate(
            (w) =>
                w is DesktopButton &&
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith(prefix),
          )
          .evaluate()) {
    final id = (element.widget.key as ValueKey<String>).value.substring(
      prefix.length,
    );
    if (!allowed.contains(id)) continue;
    final box = element.findRenderObject() as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.contains(point)) return (id: id, rect: rect);
  }
  return null;
}

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    await Directory(evidence).create(recursive: true);
    await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'drag an information record into a directory saves once without a second confirmation',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(t, f);
      try {
        await _drop(
          t,
          f.info(f.outside.id),
          t.getCenter(f.directory(f.child.id)),
          hover: (_) async {
            expect(find.text('放入“服务 / 配置”'), findsOneWidget);
            expect(f.source.writes, 0);
          },
        );
        expect(f.source.writes, 1);
        expect(f.current(f.outside).directoryId, f.child.id);
        expect(f.current(f.a).version, f.a.version);
        expect(
          find.byKey(const ValueKey('library-move-confirm')),
          findsNothing,
        );
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets('drop into unfiled is a real location and remains queryable', (
    t,
  ) async {
    final f = (await t.runAsync(_Fixture.create))!;
    final m = await _mount(t, f);
    try {
      await t.ensureVisible(f.directory('unfiled'));
      await _drop(t, f.info(f.a.id), t.getCenter(f.directory('unfiled')));
      expect(f.current(f.a).directoryId, isNull);
      expect(f.source.writes, 1);
      await t.tap(f.directory('unfiled'));
      await _settle(t);
      expect(m.query.directoryId, 'unfiled');
      expect(
        m.results!.items.map((r) => r.ref.id),
        containsAll([f.a.id, f.outside.id, f.credential.id]),
      );
      expect(m.results!.items, hasLength(3));
      expect(t.takeException(), isNull);
    } finally {
      await _close(t, f, m);
    }
  });

  testWidgets(
    'records and credentials reorder together with a narrow dark insertion preview',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      await t.runAsync(() async {
        final selection = core.LibrarySelection(
          credentialIds: [f.credential.id],
        );
        final p = await f.service.owner.previewLibraryMove(
          selection,
          f.child.id,
        );
        await f.service.owner.moveLibrarySelection(
          'synthetic-prepare-credential',
          selection,
          f.child.id,
          p.token,
        );
      });
      final m = await _mount(
        t,
        f,
        query: WorkspaceQuery(
          directoryId: f.child.id,
          sort: WorkspaceSort.manual,
        ),
        size: const Size(1100, 1100),
        dark: true,
        textScale: 1.4,
      );
      try {
        await t.tap(find.byKey(const ValueKey('library-select-mode')));
        await _settle(t);
        for (final row in [f.info(f.a.id), f.credentialRow()]) {
          await t.ensureVisible(row);
          await t.tap(row);
          await _settle(t);
        }
        expect(m.selectedCount, 2);
        await t.ensureVisible(f.info(f.c.id));
        await t.pumpAndSettle();
        final target = t.getRect(f.info(f.c.id));
        await _drop(
          t,
          f.info(f.a.id),
          Offset(target.center.dx, target.bottom - 10),
          hover: (_) async {
            expect(
              find.byKey(const ValueKey('library-drop-insertion')),
              findsOneWidget,
            );
            expect(find.textContaining('可见C”之后'), findsOneWidget);
            if (evidence.isNotEmpty) {
              final boundary = t.renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('drag-evidence')),
              );
              await t.runAsync(() async {
                final image = await boundary.toImage(pixelRatio: 1);
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '$evidence/drag-insertion-dark-narrow.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
          },
        );
        final rows = (await t.runAsync(
          () => f.source.queryRecords(
            WorkspaceQuery(directoryId: f.child.id, sort: WorkspaceSort.manual),
          ),
        ))!.items.map((r) => r.ref.id).toList();
        expect(rows, [f.b.id, f.c.id, f.a.id, f.credential.id]);
        expect(f.current(f.a).version, f.a.version);
        expect(
          f.service.owner.credentials.single.version,
          f.credential.version,
        );
        expect(f.source.writes, 1);
        expect(m.selecting, isFalse);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'mixed drag keeps selected directory subtrees and moves an external credential atomically',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(t, f);
      try {
        await t.tap(find.byKey(const ValueKey('library-select-mode')));
        await _settle(t);
        for (final row in [
          f.directory(f.root.id),
          f.directory(f.child.id),
          f.info(f.a.id),
          f.credentialRow(),
        ]) {
          await t.ensureVisible(row);
          await t.tap(row);
          await _settle(t);
        }
        expect(m.selectedCount, 4);
        await _drop(
          t,
          f.directory(f.root.id),
          t.getCenter(f.directory(f.target.id)),
        );
        expect(f.source.writes, 1);
        expect(
          f.service.owner.directories
              .singleWhere((d) => d.id == f.root.id)
              .parentId,
          f.target.id,
        );
        expect(
          f.service.owner.directories
              .singleWhere((d) => d.id == f.child.id)
              .parentId,
          f.root.id,
        );
        expect(f.current(f.a).directoryId, f.child.id);
        expect(f.current(f.outside).directoryId, isNull);
        final c = f.service.owner.credential(f.credential.id);
        expect(c.directoryId, f.target.id);
        expect(c.version, f.credential.version);
        expect(c.useGeneration, f.credential.useGeneration);
        expect(m.selecting, isFalse);
        expect(m.selectedCount, 0);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'record insertion in a filtered manual view preserves hidden siblings',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(
        t,
        f,
        query: WorkspaceQuery(
          directoryId: f.child.id,
          keyword: '可见',
          sort: WorkspaceSort.manual,
        ),
      );
      try {
        final target = t.getRect(f.info(f.a.id));
        await _drop(
          t,
          f.info(f.c.id),
          Offset(target.center.dx, target.top + 8),
          hover: (_) async {
            expect(find.text('排在“服务 / 配置 / 可见A”之前'), findsOneWidget);
            expect(
              find.byKey(const ValueKey('library-drop-insertion')),
              findsOneWidget,
            );
          },
        );
        final rows = (await t.runAsync(
          () => f.source.queryRecords(
            WorkspaceQuery(directoryId: f.child.id, sort: WorkspaceSort.manual),
          ),
        ))!;
        expect(rows.items.map((r) => r.ref.id), [f.c.id, f.a.id, f.b.id]);
        expect(f.current(f.b).version, f.b.version);
        expect(f.source.writes, 1);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'directory edges reorder siblings while the center changes the parent',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(t, f);
      try {
        final target = t.getRect(f.directory(f.root.id));
        await _drop(
          t,
          f.directory(f.target.id),
          Offset(target.center.dx, target.top + 3),
          hover: (_) async {
            expect(find.text('排在“服务”之前'), findsOneWidget);
          },
        );
        expect(
          f.service.owner.directories
              .where((d) => d.parentId == null)
              .map((d) => d.id),
          [f.target.id, f.root.id],
        );
        expect(
          f.service.owner.directories
              .singleWhere((d) => d.id == f.target.id)
              .version,
          f.target.version,
        );
        await _drop(
          t,
          f.directory(f.root.id),
          t.getCenter(f.directory(f.target.id)),
        );
        expect(
          f.service.owner.directories
              .singleWhere((d) => d.id == f.root.id)
              .parentId,
          f.target.id,
        );
        expect(f.current(f.a).directoryId, f.child.id);
        expect(f.source.writes, 2);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'invalid subtree, name collision, aggregate and time-sorted record drops never write',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(
        t,
        f,
        query: const WorkspaceQuery(sort: WorkspaceSort.updated),
      );
      try {
        await _drop(
          t,
          f.directory(f.root.id),
          t.getCenter(f.directory(f.child.id)),
          hover: (_) async {
            expect(find.textContaining('不能移入自己'), findsOneWidget);
          },
        );
        await t.runAsync(
          () => f.service.owner.createDirectory('服务', parentId: f.target.id),
        );
        await t.runAsync(() => m.load(m.query));
        await _settle(t);
        await _drop(
          t,
          f.directory(f.root.id),
          t.getCenter(f.directory(f.target.id)),
          hover: (_) async {
            expect(find.textContaining('目标已有同名目录'), findsOneWidget);
          },
        );
        await _drop(
          t,
          f.info(f.outside.id),
          t.getCenter(f.directory('all')),
          hover: (_) async {
            expect(find.textContaining('全部资料不是存放目录'), findsOneWidget);
          },
        );
        await _drop(
          t,
          f.info(f.c.id),
          t.getCenter(f.info(f.a.id)),
          hover: (_) async {
            expect(find.textContaining('请先切换“手动顺序”'), findsOneWidget);
          },
        );
        expect(f.source.writes, 0);
        expect(f.current(f.outside).directoryId, isNull);
        expect(
          f.service.owner.directories
              .singleWhere((d) => d.id == f.root.id)
              .parentId,
          isNull,
        );
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'Escape cancels a drag and preserves multi-selection without a write',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(t, f);
      try {
        await t.tap(find.byKey(const ValueKey('library-select-mode')));
        await _settle(t);
        await t.tap(f.info(f.outside.id));
        await _settle(t);
        await _drop(
          t,
          f.info(f.outside.id),
          t.getCenter(f.directory(f.child.id)),
          hover: (_) async {
            await t.sendKeyEvent(LogicalKeyboardKey.escape);
            await t.pump();
          },
        );
        expect(f.source.writes, 0);
        expect(m.selectedCount, 1);
        expect(f.current(f.outside).directoryId, isNull);
        expect(find.byKey(const ValueKey('library-drop-hint')), findsNothing);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'hover expands a collapsed directory and the final child receives the record',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(t, f);
      try {
        await t.tap(
          find.byKey(ValueKey('library-directory-toggle-${f.root.id}')),
        );
        await _settle(t);
        expect(f.directory(f.child.id), findsNothing);
        await _drop(
          t,
          f.info(f.outside.id),
          t.getCenter(f.directory(f.root.id)),
          hover: (gesture) async {
            await t.pump(const Duration(milliseconds: 700));
            await t.pump();
            expect(f.directory(f.child.id), findsOneWidget);
            await gesture.moveTo(t.getCenter(f.directory(f.child.id)));
            await t.pump();
            expect(find.text('放入“服务 / 配置”'), findsOneWidget);
            expect(f.source.writes, 0);
          },
        );
        expect(f.current(f.outside).directoryId, f.child.id);
        expect(f.source.writes, 1);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'stationary edge scrolling drops into the directory visible at release, not the earlier candidate',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      await t.runAsync(() async {
        for (var i = 0; i < 70; i++) {
          await f.service.owner.createDirectory('目录$i');
        }
      });
      final m = await _mount(t, f);
      try {
        final viewport = t.getRect(
          find.byKey(const ValueKey('library-directory-scroll')),
        );
        final edge = Offset(viewport.center.dx, viewport.bottom - 12);
        final ids = f.service.owner.directories.map((d) => d.id).toSet();
        String? original, expected;
        await _drop(
          t,
          f.info(f.outside.id),
          edge,
          hover: (_) async {
            original = _rowAt(t, edge, 'library-directory-', ids)?.id;
            for (var i = 0; i < 45; i++) {
              await t.pump(const Duration(milliseconds: 16));
            }
            await t.pump();
            for (
              var i = 0;
              i < 8 && _rowAt(t, edge, 'library-directory-', ids) == null;
              i++
            ) {
              await t.pump(const Duration(milliseconds: 16));
              await t.pump();
            }
            expected = _rowAt(t, edge, 'library-directory-', ids)?.id;
            expect(expected, isNotNull);
            expect(expected, isNot(original));
            final name = f.service.owner.directories
                .singleWhere((d) => d.id == expected)
                .name;
            expect(find.text('放入“$name”'), findsOneWidget);
            expect(f.source.writes, 0);
          },
        );
        expect(f.current(f.outside).directoryId, expected);
        expect(f.source.writes, 1);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'drag survives disposal of the offscreen source and uses the final visible insertion anchor',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      await t.runAsync(() async {
        for (var i = 0; i < 60; i++) {
          await f.service.owner.createInformation('长列表$i', '', [
            const core.FieldInput('正文', '', 'PRIVATE-LONG'),
          ], directoryId: f.child.id);
        }
      });
      final m = await _mount(
        t,
        f,
        query: WorkspaceQuery(
          directoryId: f.child.id,
          sort: WorkspaceSort.manual,
          limit: 100,
        ),
      );
      try {
        final viewport = t.getRect(
          find.byKey(const ValueKey('library-results-scroll')),
        );
        final edge = Offset(viewport.center.dx, viewport.bottom - 12);
        final ids = f.service.owner.information.map((i) => i.id).toSet();
        String? expected;
        var after = false;
        await _drop(
          t,
          f.info(f.a.id),
          edge,
          hover: (_) async {
            for (var i = 0; i < 65; i++) {
              await t.pump(const Duration(milliseconds: 16));
            }
            await t.pump();
            for (
              var i = 0;
              i < 8 &&
                  _rowAt(t, edge, 'library-record-information:', ids) == null;
              i++
            ) {
              await t.pump(const Duration(milliseconds: 16));
              await t.pump();
            }
            expected = _rowAt(t, edge, 'library-record-information:', ids)?.id;
            expect(expected, isNotNull);
            expect(expected, isNot(f.a.id));
            final text = t
                .widget<Text>(find.byKey(const ValueKey('library-drop-hint')))
                .data!;
            final name = f.service.owner.information
                .singleWhere((i) => i.id == expected)
                .name;
            expect(text, contains(name));
            after = text.endsWith('之后');
            expect(f.source.writes, 0);
          },
        );
        final rows = (await t.runAsync(
          () => f.source.queryRecords(
            WorkspaceQuery(
              directoryId: f.child.id,
              sort: WorkspaceSort.manual,
              limit: 100,
            ),
          ),
        ))!.items.map((r) => r.ref.id).toList();
        expect(
          rows.indexOf(f.a.id),
          rows.indexOf(expected!) + (after ? 1 : -1),
        );
        expect(rows, hasLength(63));
        expect(f.current(f.a).version, f.a.version);
        expect(f.source.writes, 1);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'keyboard context menu and target picker adjust order without dragging',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(
        t,
        f,
        query: WorkspaceQuery(
          directoryId: f.child.id,
          sort: WorkspaceSort.updated,
        ),
      );
      try {
        await _focusByTab(t, f.info(f.c.id));
        await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.f10);
        await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await _settle(t);
        await t.tap(find.text('调整顺序'));
        await _settle(t);
        expect(
          find.descendant(
            of: find.byType(DesktopDialog),
            matching: find.textContaining('PRIVATE-'),
          ),
          findsNothing,
        );
        await t.enterText(
          find.byKey(const ValueKey('library-placement-search')),
          '可见A',
        );
        await _settle(t);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await _settle(t);
        expect(f.source.writes, 1);
        expect(m.query.sort, WorkspaceSort.manual);
        expect(m.results!.items.map((r) => r.ref.id), [f.c.id, f.a.id, f.b.id]);
        expect(f.current(f.b).version, f.b.version);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'a lost drop reply opens recovery for the original operation and never moves twice',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(t, f);
      try {
        f.source.loseReply = true;
        await _drop(
          t,
          f.info(f.outside.id),
          t.getCenter(f.directory(f.child.id)),
        );
        expect(f.source.writes, 1);
        expect(f.current(f.outside).directoryId, f.child.id);
        expect(
          find.byKey(const ValueKey('library-move-reconcile')),
          findsOneWidget,
        );
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
        expect(
          find.byKey(const ValueKey('library-move-reconcile')),
          findsOneWidget,
        );
        await t.tap(find.byKey(const ValueKey('library-move-reconcile')));
        await _settle(t);
        expect(f.source.writes, 1);
        expect(f.source.lookups, 1);
        expect(
          find.byKey(const ValueKey('library-move-reconcile')),
          findsNothing,
        );
        expect(f.service.owner.information, hasLength(4));
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );

  testWidgets(
    'a failed drop keeps actual positions and cancelling recovery preserves selection',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      final m = await _mount(t, f);
      try {
        await t.tap(find.byKey(const ValueKey('library-select-mode')));
        await _settle(t);
        await t.tap(f.info(f.outside.id));
        await _settle(t);
        f.source.failSave = true;
        await _drop(
          t,
          f.info(f.outside.id),
          t.getCenter(f.directory(f.child.id)),
        );
        expect(find.text('合成保存失败，位置保持原样。'), findsOneWidget);
        expect(f.current(f.outside).directoryId, isNull);
        expect(f.source.writes, 1);
        await t.tap(find.text('取消'));
        await _settle(t);
        expect(m.selectedCount, 1);
        expect(f.current(f.outside).directoryId, isNull);
        expect(t.takeException(), isNull);
      } finally {
        await _close(t, f, m);
      }
    },
  );
}
