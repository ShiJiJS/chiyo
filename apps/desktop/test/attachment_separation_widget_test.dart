import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/library_attachment_separation.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_agent_templates.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import '../../../packages/info_core/test/fixtures/legacy_attachment_fixture.dart';

void main() {
  testWidgets('owner saves an old original as a dynamically selected file type', (
    t,
  ) async {
    final repo = core.MemoryInformationRepository();
    final service = core.InformationService(repository: repo);
    final original = (await t.runAsync(
      () => createLegacyAttachment(service, repo),
    ))!;
    // Use the actual host catalog. A fake plugin containing the built-in file
    // template hid the production bug: the package list does not include it.
    service.owner.configureInformationTemplates(
      () => currentAgentTemplates(service.owner),
    );
    final source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
    addTearDown(
      () => t.runAsync(() async {
        await source.dispose();
      }),
    );
    final detail = (await t.runAsync(
      () => source.readDetail(
        WorkspaceRecordRef(WorkspaceRecordKind.information, original.id),
      ),
    ))!;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAttachmentSeparation(
                context,
                source,
                detail,
                original.fields.first.id,
                '材料.md',
              ),
              child: const Text('整理旧附件'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('整理旧附件'));
    await t.pumpAndSettle();
    expect(find.text('资料类型'), findsOneWidget);
    await t.enterText(find.byType(TextField), '独立原件');
    await t.tap(find.text('保存'));
    for (var n = 0; n < 100 && repo.items.length != 2; n++) {
      await t.pump(const Duration(milliseconds: 10));
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    await t.pumpAndSettle();
    if (find.text('存为独立文件资料').evaluate().isNotEmpty) {
      fail(
        '整理未保存：${t.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' / ')}',
      );
    }
    expect(find.text('存为独立文件资料'), findsNothing);
    expect(repo.items.length, 2);
    expect(
      repo.items.singleWhere((i) => i.name == '独立原件').layout!.typeId,
      'file',
    );
    expect(
      repo.items.singleWhere((i) => i.id == original.id).fields.single.value,
      '重要事实',
    );
    expect(t.takeException(), isNull);
    final closing = service.close();
    await t.pumpAndSettle();
    await t.runAsync(() => closing);
  });
}
