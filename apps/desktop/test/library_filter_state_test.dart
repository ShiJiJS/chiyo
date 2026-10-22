import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/information_workspace.dart';
import 'package:info_desktop/ui.dart';
import 'package:info_desktop/desktop_scroll.dart';

void main() {
  testWidgets(
    'library keeps directory, query and tag intersection visible across modes; invalid filters recover',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final refresh = ValueNotifier(0);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        final closing = service.close();
        await tester.pump();
        await closing;
        refresh.dispose();
      });
      final owner = service.owner;
      final parent = await owner.createDirectory('Project');
      final child = await owner.createDirectory(
        'Services',
        parentId: parent.id,
      );
      final a = await owner.createTag('Work'),
          b = await owner.createTag('Pinned');
      final match = await owner.createInformation(
        'Alpha docs',
        '',
        const [FieldInput('URL', '', 'docs.invalid')],
        directoryId: child.id,
        tagIds: [a.id, b.id],
      );
      await owner.createInformation(
        'Beta docs',
        '',
        const [FieldInput('URL', '', 'beta.invalid')],
        directoryId: child.id,
        tagIds: [a.id],
      );
      await owner.createInformation('Loose note', '', const [
        FieldInput('Text', '', 'loose'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          scrollBehavior: const DesktopScrollBehavior(),
          home: Scaffold(
            body: InformationWorkspace(owner: owner, refresh: refresh),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('library-list'));
      Finder inList(String name) =>
          find.descendant(of: list, matching: find.text(name));
      await tester.tap(find.byKey(ValueKey('directory-${parent.id}')));
      await tester.pumpAndSettle();
      expect(inList('Loose note'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'docs',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-tag-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work').last);
      await tester.tap(find.text('Pinned').last);
      await tester.tap(find.text('使用所选标签'));
      await tester.pumpAndSettle();
      expect(inList('Alpha docs'), findsOneWidget);
      expect(inList('Beta docs'), findsNothing);
      expect(find.byKey(ValueKey('information-${match.id}')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-credentials-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('信息').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('library-search')))
            .controller!
            .text,
        'docs',
      );
      expect(inList('Alpha docs'), findsOneWidget);
      expect(inList('Beta docs'), findsNothing);
      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();
      expect(inList('Alpha docs'), findsOneWidget);
      expect(inList('Beta docs'), findsOneWidget);
      expect(inList('Loose note'), findsNothing);
      await tester.tap(find.text('未分类').first);
      await tester.pumpAndSettle();
      expect(inList('Loose note'), findsOneWidget);
      expect(inList('Alpha docs'), findsNothing);
      await tester.tap(find.text('全部信息').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-tag-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pinned').last);
      await tester.tap(find.text('使用所选标签'));
      await tester.pumpAndSettle();
      await owner.deleteTag(b.id, b.version);
      refresh.value++;
      await tester.pumpAndSettle();
      expect(find.text('已移除失效的标签筛选。'), findsOneWidget);
      expect(inList('Loose note'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
