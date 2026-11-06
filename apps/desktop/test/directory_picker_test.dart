import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/directory_picker.dart';
import 'package:info_desktop/workspace/library_widgets.dart';
import 'package:info_desktop/workspace/proposal_directory.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

final catalog = WorkspaceCatalog(
  directories: const [
    WorkspaceDirectory('a', '账号与服务'),
    WorkspaceDirectory('apps', '应用', parentId: 'a'),
    WorkspaceDirectory('vpn', 'VPN', parentId: 'apps', proposed: true),
    WorkspaceDirectory('b', '个人档案'),
    WorkspaceDirectory('other-apps', '应用', parentId: 'b'),
  ],
  tags: const [],
  types: const [],
);

void main() {
  test(
    'shared tree preserves sibling order with moved parents and deep hierarchies',
    () {
      final dirs = <WorkspaceDirectory>[
        const WorkspaceDirectory('child', '子目录', parentId: 'parent'),
        const WorkspaceDirectory('other', '其他'),
        const WorkspaceDirectory('parent', '上级'),
        for (var i = 0; i < 3500; i++)
          WorkspaceDirectory(
            'deep-$i',
            '层级$i',
            parentId: i == 0 ? 'child' : 'deep-${i - 1}',
          ),
      ];
      final tree = libraryDirectoryTree(
        WorkspaceCatalog(directories: dirs, tags: const [], types: const []),
      );
      expect(tree.take(3).map((d) => d.id), ['other', 'parent', 'child']);
      expect(tree.last.id, 'deep-3499');
      expect(tree, hasLength(3503));
    },
  );
  testWidgets(
    'shared picker shows complete paths, searches and distinguishes same names',
    (t) async {
      String? selected;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryDirectorySelect(
              catalog: catalog,
              value: 'apps',
              onChanged: (id) => selected = id,
            ),
          ),
        ),
      );
      await t.tap(find.text('浏览完整目录树'));
      await t.pumpAndSettle();
      expect(find.text('账号与服务 / 应用 / VPN'), findsOneWidget);
      await t.tap(find.byTooltip('收起账号与服务'));
      await t.pumpAndSettle();
      expect(find.text('账号与服务 / 应用 / VPN'), findsNothing);
      await t.enterText(find.byType(TextField), '应用');
      await t.pumpAndSettle();
      expect(find.text('账号与服务 / 应用'), findsOneWidget);
      await t.tap(find.text('个人档案 / 应用'));
      await t.pumpAndSettle();
      expect(selected, 'other-apps');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'proposal location identifies existing and new levels without editing a record',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProposalDirectoryLocation(
              catalog: catalog,
              directoryId: 'vpn',
            ),
          ),
        ),
      );
      expect(find.text('账号与服务 / 应用 / VPN'), findsOneWidget);
      expect(find.text('账号与服务 · 已有'), findsOneWidget);
      expect(find.text('VPN · 将新建'), findsOneWidget);
      await t.tap(find.text('查看完整目录树'));
      await t.pumpAndSettle();
      expect(find.text('查看目录结构'), findsOneWidget);
      expect(directoryPath(catalog, null), '未分类');
    },
  );
  testWidgets(
    'new paths validate, reuse existing names, and accept keyboard submission',
    (t) async {
      t.view.physicalSize = const Size(510, 760);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      DirectorySelection? selected;
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.4)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showDirectoryPicker(
                    context,
                    catalog,
                    allowNew: true,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.tap(find.text('调整拟建目录路径'));
      await t.pumpAndSettle();
      final input = find.byKey(const ValueKey('proposed-directory-path'));
      await t.enterText(input, '账号与服务//不合法');
      await t.tap(find.text('使用此路径'));
      await t.pumpAndSettle();
      expect(selected, isNull);
      expect(find.textContaining('请填写最多8层'), findsOneWidget);
      await t.enterText(input, ' 账号与服务 / 应用 / 新目录 ');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(selected!.proposedPath, '账号与服务/应用/新目录');
      expect(selected!.id, isNull);
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.tap(find.text('调整拟建目录路径'));
      await t.pumpAndSettle();
      await t.enterText(input, '账号与服务 / 应用');
      await t.tap(find.text('使用此路径'));
      await t.pumpAndSettle();
      expect(selected!.id, 'apps');
      expect(selected!.proposedPath, isEmpty);
    },
  );

  testWidgets(
    'large tree supports normalized path search, narrow windows, keyboard and cancellation',
    (t) async {
      t.view.physicalSize = const Size(510, 760);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final large = WorkspaceCatalog(
        directories: [
          ...catalog.directories,
          for (var i = 0; i < 400; i++)
            WorkspaceDirectory('extra-$i', '很长的目录名称第$i项用于核对换行', parentId: 'b'),
        ],
        tags: [],
        types: [],
      );
      DirectorySelection? selected;
      bool closed = false;
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.4)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showDirectoryPicker(context, large);
                  closed = true;
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '个人档案/很长的目录名称第399');
      await t.pumpAndSettle();
      final choice = find.widgetWithText(TextButton, '很长的目录名称第399项用于核对换行');
      expect(choice, findsOneWidget);
      Focus.of(t.element(find.text('很长的目录名称第399项用于核对换行'))).requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(closed, true);
      expect(selected!.id, 'extra-399');
      expect(t.takeException(), isNull);
      closed = false;
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(closed, true);
      expect(selected, isNull);
    },
  );

  test(
    'proposal overview deduplicates new parent paths and reuses actual names',
    () {
      final reviews = [
        for (final path in ['账号与服务/应用/新目录', '账号与服务/应用/新目录/子目录'])
          WorkspaceProposalItemReview(
            itemId: path,
            name: '合成',
            description: '',
            values: {},
            suggestedDirectory: path,
          ),
      ];
      final result = proposalDirectoryCatalog(catalog, reviews);
      expect(result.directories.where((d) => d.proposed).map((d) => d.name), [
        'VPN',
        '新目录',
        '子目录',
      ]);
      expect(
        directoryPath(result, proposalReviewDirectory(result, reviews.first)),
        '账号与服务 / 应用 / 新目录',
      );
    },
  );
}
