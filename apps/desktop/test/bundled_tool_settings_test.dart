import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_desktop/bundled_tool_settings.dart';
import 'package:info_desktop/ui.dart';

void main() {
  testWidgets(
    'available path copies exactly; failed entry cannot be copied; refresh recovers',
    (tester) async {
      var available = false;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: BundledToolSettings(
                read: () async => [
                  CredentialToolLocation(
                    receiver: 'gh_token',
                    source: 'app_bundle',
                    available: available,
                    version: '2.102.0',
                    executable: available
                        ? '/移动 中文.app/Contents/Resources/ThirdParty/gh/bin/gh'
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final copy = find.byKey(const ValueKey('copy-tool-gh_token'));
      expect(tester.widget<TextButton>(copy).onPressed, isNull);
      available = true;
      await tester.tap(find.text('刷新随包工具状态'));
      await tester.pumpAndSettle();
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, '/移动 中文.app/Contents/Resources/ThirdParty/gh/bin/gh');
      expect(find.text('已复制工具路径。'), findsOneWidget);
      expect(find.textContaining('入口核对不代表凭据已授权'), findsOneWidget);
    },
  );
}
