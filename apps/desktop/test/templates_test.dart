import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  testWidgets(
    'owner creates a template and only saves information after reviewing its form',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(() async {
        final closing = service.close();
        await tester.pump();
        await closing;
      });
      await tester.pumpWidget(InformationApp(service: service, port: 47125));
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-section-templates')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建模板'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('template-name')),
        '虚构服务器模板',
      );
      await tester.enterText(
        find.byKey(const ValueKey('template-field-name-0')),
        '地址',
      );
      await tester.tap(find.text('保存模板'));
      await tester.pumpAndSettle();
      expect(service.owner.templates.single.name, '虚构服务器模板');
      expect(service.owner.information, isEmpty);
      await tester.tap(find.text('使用模板 →'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('template-item-name')),
        '虚构测试机',
      );
      await tester.enterText(
        find.byKey(const ValueKey('template-value-0')),
        'fictional.invalid',
      );
      expect(service.owner.information, isEmpty);
      await tester.tap(find.text('保存信息'));
      await tester.pumpAndSettle();
      expect(
        service.owner.information.single.fields.single.value,
        'fictional.invalid',
      );
      await tester.tap(find.text('修改模板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑说明'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存模板不会修改已有信息'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('template-field-name-0')),
        '备注',
      );
      await tester.tap(find.text('保存模板'));
      await tester.pumpAndSettle();
      expect(service.owner.templates.single.version, 2);
      expect(service.owner.information.single.fields.single.name, '地址');
      expect(tester.takeException(), isNull);
    },
  );
}
