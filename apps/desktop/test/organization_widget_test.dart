import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/organization_selectors.dart';

void main() {
  testWidgets('owner creates hierarchy and tags then organizes an item', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
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
    await tester.tap(find.byKey(const ValueKey('new-directory')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('organization-name')),
      'Project',
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    final project = service.owner.directories.single;
    await tester.tap(find.byKey(ValueKey('directory-menu-${project.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建子目录'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('organization-name')),
      'Servers',
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-tag-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tag-name')), 'Work');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部信息').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fictional demo server').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-information-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DirectoryField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Servers').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work'));
    await tester.tap(find.text('保存整理'));
    await tester.pumpAndSettle();
    expect(service.owner.directories.last.parentId, project.id);
    final item = service.owner.information.firstWhere(
      (i) => i.id == 'demo-server',
    );
    expect(item.directoryId, service.owner.directories.last.id);
    expect(item.tagIds, [service.owner.tags.single.id]);
    expect(item.fields.first.id, 'host');
    expect(
      service.agent.searchCatalog(tagId: service.owner.tags.single.id).total,
      1,
    );
    await tester.tap(find.byKey(ValueKey('directory-${project.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Other item'), findsNothing);
    expect(find.text('Fictional demo server'), findsNWidgets(2));
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
    await tester.tap(find.text('Fictional demo server').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('edit-information-description')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('item-name')),
      'Reviewed server',
    );
    await tester.enterText(
      find.byKey(const ValueKey('item-description')),
      'Reviewed purpose',
    );
    await tester.enterText(
      find.byKey(const ValueKey('field-description-0')),
      'Reviewed address',
    );
    expect(service.agent.catalog().single['name'], 'Fictional demo server');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃更改'));
    await tester.pumpAndSettle();
    expect(service.agent.catalog().single['name'], 'Fictional demo server');
    await tester.tap(
      find.byKey(const ValueKey('edit-information-description')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('item-name')),
      'Reviewed server',
    );
    await tester.enterText(
      find.byKey(const ValueKey('field-description-0')),
      'Reviewed address',
    );
    await tester.tap(find.byKey(const ValueKey('save-information')));
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
