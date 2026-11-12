import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/credential_fill_permissions.dart';
import 'package:info_desktop/workspace/credential_fill_settings.dart';

class _Permissions extends CredentialFillPermissions {
  int reads = 0;
  int requests = 0;
  CredentialFillPermissionState state =
      CredentialFillPermissionState.permissionRequired;

  @override
  bool get canRequest => true;

  @override
  Future<CredentialFillPermissionState> read() async {
    reads++;
    return state;
  }

  @override
  Future<CredentialFillPermissionState> request() async {
    requests++;
    return state;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('only the explicit button requests OS permission', (
    tester,
  ) async {
    final permissions = _Permissions();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CredentialFillSettings(permissions: permissions)),
      ),
    );
    await tester.pumpAndSettle();
    expect(permissions.reads, 1);
    expect(permissions.requests, 0);
    expect(find.text('需要开启辅助功能权限'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fill-check-permission')));
    await tester.pumpAndSettle();
    expect(permissions.requests, 0);
    await tester.tap(find.byKey(const ValueKey('fill-request-permission')));
    await tester.pumpAndSettle();
    expect(permissions.requests, 1);
    // Returning from System Settings rechecks actual permission. The click
    // itself never assumes the user enabled it.
    permissions.state = CredentialFillPermissionState.ready;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('填写权限已开启'), findsOneWidget);
    expect(find.byKey(const ValueKey('fill-request-permission')), findsNothing);
    expect(permissions.requests, 1);
  });

  test(
    'an absent native helper does not advertise permission readiness',
    () async {
      const channel = MethodChannel('agent_info_manage/focused_fill');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw MissingPluginException();
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(
        await const CredentialFillPermissions().read(),
        CredentialFillPermissionState.unavailable,
      );
    },
  );
}
