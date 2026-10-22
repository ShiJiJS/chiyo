import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/organization_selectors.dart';
import 'support/isolated_desktop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final platform = Platform.isMacOS ? 'macOS' : 'Windows';
  testWidgets('$platform isolated library classification lifecycle', (
    tester,
  ) async {
    // Text injection uses a test IME; keep stale native editing messages from
    // overwriting a correction after a validation error. The window, storage
    // and platform encryption remain real.
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    final fixture = await IsolatedDesktopFixture.start(
      prepareLibrary: (service) async {
        for (var i = 0; i < 100; i++) {
          await service.owner.createTag(
            'Existing ${i.toString().padLeft(3, '0')}',
          );
        }
      },
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await fixture.close();
    });
    final owner = fixture.service.owner;
    await tester.pumpWidget(
      InformationApp(
        service: fixture.service,
        port: fixture.port,
        runtime: fixture.bootstrap.runtime,
      ),
    );
    await tester.pumpAndSettle();
    debugPrint(
      'LIBRARY_UX_NATIVE_VIEW physical=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio} logical=${tester.view.physicalSize / tester.view.devicePixelRatio}',
    );
    Future<void> tap(Finder target) async {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
      // Native SQLCipher writes can outlive a settled animation frame. Wait on
      // the visible saving state rather than assuming an in-memory repository.
      for (
        var n = 0;
        n < 200 && find.text('正在保存…').evaluate().isNotEmpty;
        n++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(find.text('正在保存…'), findsNothing);
      expect(tester.takeException(), isNull);
    }

    Future<void> type(Finder target, String value) async {
      await tester.ensureVisible(target);
      await tester.enterText(target, value);
      await tester.pumpAndSettle();
    }

    Future<void> directoryAction(String id, String action) async {
      await tap(find.byKey(ValueKey('directory-menu-$id')));
      await tap(find.text(action));
    }

    Future<void> createRoot(String name) async {
      await tap(find.byKey(const ValueKey('new-directory')));
      await type(find.byKey(const ValueKey('organization-name')), name);
      await tap(find.text('创建'));
    }

    await tap(find.byKey(const ValueKey('nav-1')));
    await createRoot('Project');
    final root = owner.directories.single;
    await directoryAction(root.id, '新建子目录');
    await type(find.byKey(const ValueKey('organization-name')), 'Root/Child');
    await tap(find.text('创建'));
    expect(find.text('请输入单级目录名称，不要填写路径。'), findsOneWidget);
    expect(owner.directories, hasLength(1));
    await type(find.byKey(const ValueKey('organization-name')), 'Operations');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('organization-name')))
          .controller!
          .text,
      'Operations',
    );
    await tap(find.text('创建'));
    expect(
      owner.directories.any((d) => d.name == 'Operations'),
      isTrue,
      reason:
          'After native save: ${owner.directories.map((d) => d.name).toList()}; visible feedback: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().toList()}',
    );
    final child = owner.directories.singleWhere((d) => d.name == 'Operations');
    expect(child.parentId, root.id);
    await directoryAction(root.id, '重命名');
    await type(find.byKey(const ValueKey('organization-name')), 'Work');
    await tap(find.text('保存'));
    expect(owner.directories.singleWhere((d) => d.id == root.id).name, 'Work');
    await createRoot('Personal');
    final personal = owner.directories.singleWhere((d) => d.name == 'Personal');
    await directoryAction(child.id, '移动');
    await tap(find.text('Personal').last);
    await tap(find.text('保存'));
    expect(
      owner.directories.firstWhere((d) => d.id == child.id).parentId,
      personal.id,
    );
    await directoryAction(child.id, '删除');
    await tap(find.text('删除').last);
    expect(owner.directories.any((d) => d.id == child.id), isFalse);
    await tap(find.text('全部信息').first);
    final info = owner.information.single;
    await tap(find.byKey(const ValueKey('edit-information-category')));
    await tap(find.byType(DirectoryField));
    await tap(find.text('Work').last);
    await type(find.widgetWithText(TextField, '搜索标签'), 'Existing 099');
    await tap(find.text('Existing 099').last);
    await tap(find.text('保存整理'));
    expect(owner.information.single.directoryId, root.id);
    expect(
      owner.information.single.fields.map((f) => f.id),
      info.fields.map((f) => f.id),
    );
    await directoryAction(root.id, '删除');
    expect(find.textContaining('包含 1 条信息'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '删除'))
          .onPressed,
      isNull,
    );
    await tap(find.text('取消'));
    await tap(find.byKey(const ValueKey('library-tag-filter')));
    await tap(find.text('管理标签'));
    await type(find.widgetWithText(TextField, '搜索标签'), 'Existing 099');
    await tap(find.text('重命名'));
    await type(find.byKey(const ValueKey('tag-name')), 'Selected tag');
    await tap(find.text('保存'));
    await type(find.widgetWithText(TextField, '搜索标签'), 'Selected tag');
    final selected = owner.tags.firstWhere((t) => t.name == 'Selected tag');
    await tap(find.text('删除'));
    expect(find.textContaining('1 条信息'), findsWidgets);
    await tap(find.text('删除').last);
    expect(owner.tags.any((t) => t.id == selected.id), isFalse);
    expect(owner.information.single.tagIds, isEmpty);
    expect(owner.information.single.id, info.id);
    await tap(find.text('新建标签'));
    await type(find.byKey(const ValueKey('tag-name')), 'My label');
    await tap(find.text('保存'));
    expect(owner.tags.any((t) => t.name == 'My label'), isTrue);
    await tap(find.text('完成'));
    await tap(find.byKey(ValueKey('directory-${personal.id}')));
    await tap(find.text('回收站'));
    await tap(find.text('×').last);
    expect(find.byKey(ValueKey('directory-${personal.id}')), findsOneWidget);
    expect(fixture.service.owner.information.single.id, info.id);
    debugPrint(
      'LIBRARY_UX_NATIVE_VERIFIED root/child/create-error/rename/move/empty-delete/nonempty-block/100-tag-search/assign/rename/delete/new-tag/recycle-return; isolated SQLCipher and ${Platform.isMacOS ? 'ephemeral synthetic key' : 'DPAPI'}',
    );
  });
}
