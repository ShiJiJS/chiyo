import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';

void main() {
  testWidgets('owner manually saves named information fields', (tester) async {
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    await tester.pumpWidget(
      MaterialApp(home: InformationLibrary(owner: service.owner)),
    );
    await tester.tap(find.text('新建信息'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('item-name')), '虚构服务器');
    await tester.enterText(find.byKey(const ValueKey('field-name-0')), '地址');
    await tester.enterText(
      find.byKey(const ValueKey('field-value-0')),
      'fictional.invalid',
    );
    await tester.tap(find.text('保存信息'));
    await tester.pumpAndSettle();
    expect(
      service.owner.information.single.fields.single.value,
      'fictional.invalid',
    );
    expect(find.text('虚构服务器'), findsNWidgets(2));
  });
}
