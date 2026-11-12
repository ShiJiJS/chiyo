import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/credential_fill_permissions.dart';
import 'package:info_desktop/workspace/credential_fill_settings.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows verifies the bundled broker and labels module readiness without an OS permission button',
    (tester) async {
      const permissions = CredentialFillPermissions();
      // This exercises the actual runner channel, fixed sibling path and SHA,
      // not a mocked plugin. It never queries focus or sends input.
      expect(permissions.canRequest, isFalse);
      expect(await permissions.read(), CredentialFillPermissionState.ready);
      await tester.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: const Scaffold(
            body: SingleChildScrollView(child: CredentialFillSettings()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('填写模块已就绪'), findsOneWidget);
      expect(find.text('填写权限已开启'), findsNothing);
      expect(find.text('需要开启辅助功能权限'), findsNothing);
      expect(
        find.byKey(const ValueKey('fill-request-permission')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
    skip: !Platform.isWindows,
  );
}
