import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/approvals.dart';

void main() {
  testWidgets(
    'ended chat preserves its label and explains reapproval without approval controls',
    (tester) async {
      final service = InformationService.fictional();
      final session = service.agent.openSession('fictional root');
      service.agent.request(session, 'Address', [
        const FieldRef('demo-server', 'host'),
      ]);
      await tester.pumpWidget(
        MaterialApp(home: Approvals(service: service, port: 47125)),
      );
      service.agent.endSession(session);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('fictional root'), findsWidgets);
      expect(find.text('聊天已结束。恢复聊天需要重新连接并申请授权。'), findsOneWidget);
      expect(find.text('批准所选字段'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await service.close();
    },
  );
}
