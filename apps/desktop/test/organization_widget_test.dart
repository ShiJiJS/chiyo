import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';

void main() {
  testWidgets('owner creates hierarchy and tags then organizes an item', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = InformationService.fictional();
    addTearDown(() async {
      final closing = service.close();
      await tester.pump();
      await closing;
    });
    await service.owner.createInformation('Other item', '', [
      const FieldInput('Host', '', 'other.invalid'),
    ]);
    await tester.pumpWidget(
      MaterialApp(home: InformationLibrary(owner: service.owner)),
    );
    await tester.tap(find.text('目录与标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建目录'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('organization-name')),
      'Project',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建目录'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('organization-name')),
      'Servers',
    );
    await tester.tap(find.byKey(const ValueKey('organization-parent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Project').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建标签'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('organization-name')),
      'Work',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fictional demo server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('整理位置和标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('item-directory')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Project / Servers').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work').last);
    await tester.tap(find.text('保存整理'));
    await tester.pumpAndSettle();
    expect(
      service.owner.directories.last.parentId,
      service.owner.directories.first.id,
    );
    expect(
      service.owner.information.first.directoryId,
      service.owner.directories.last.id,
    );
    expect(service.owner.information.first.tagIds, [
      service.owner.tags.single.id,
    ]);
    expect(service.owner.information.first.fields.first.id, 'host');
    expect(
      service.agent.searchCatalog(tagId: service.owner.tags.single.id).total,
      1,
    );
    await tester.tap(find.byKey(const ValueKey('browse-directory')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Project').last);
    await tester.pumpAndSettle();
    expect(find.text('Other item'), findsNothing);
    expect(find.text('Fictional demo server'), findsOneWidget);
  });
  testWidgets('public description drafts stay private until owner saves', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = InformationService.fictional();
    addTearDown(() async {
      final closing = service.close();
      await tester.pump();
      await closing;
    });
    await tester.pumpWidget(
      MaterialApp(home: InformationLibrary(owner: service.owner)),
    );
    await tester.tap(find.text('Fictional demo server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑公开说明'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('catalog-name')),
      'Reviewed server',
    );
    await tester.enterText(
      find.byKey(const ValueKey('catalog-description')),
      'Reviewed purpose',
    );
    await tester.enterText(
      find.byKey(const ValueKey('catalog-field-host')),
      'Reviewed address',
    );
    expect(service.agent.catalog().single['name'], 'Fictional demo server');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.agent.catalog().single['name'], 'Fictional demo server');
    await tester.tap(find.text('编辑公开说明'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('catalog-name')),
      'Reviewed server',
    );
    await tester.enterText(
      find.byKey(const ValueKey('catalog-field-host')),
      'Reviewed address',
    );
    await tester.tap(find.text('保存公开说明'));
    await tester.pumpAndSettle();
    expect(
      service.agent
          .searchCatalog(query: 'Reviewed address')
          .items
          .single['name'],
      'Reviewed server',
    );
    expect(service.owner.information.single.fields.first.id, 'host');
  });
}
