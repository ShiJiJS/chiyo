import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/credential_fill_permissions.dart';
import 'package:info_desktop/workspace/credential_fill_settings.dart';

const requiredReport = CredentialFillPermissionReport(
  native: CredentialFillPermissionState.permissionRequired,
  focus: CredentialFillPermissionState.permissionRequired,
  applicationPath: '/Applications/chiyo.app',
);
const nativeReadyReport = CredentialFillPermissionReport(
  native: CredentialFillPermissionState.ready,
  focus: CredentialFillPermissionState.permissionRequired,
  applicationPath: '/Applications/chiyo.app',
);

class _Permissions extends CredentialFillPermissions {
  int reads = 0, requests = 0, focusRequests = 0, settings = 0, reveals = 0;
  CredentialFillPermissionReport report = requiredReport;
  Completer<CredentialFillPermissionReport>? delayedRead;
  bool settingsOpen = true, mac = true;
  @override
  bool get canRequest => mac;
  @override
  Future<CredentialFillPermissionReport> readReport() async {
    reads++;
    final pending = delayedRead;
    delayedRead = null;
    return pending == null ? report : pending.future;
  }

  @override
  Future<CredentialFillPermissionReport> requestNative() async {
    requests++;
    return report;
  }

  @override
  Future<CredentialFillPermissionReport> requestFocus() async {
    focusRequests++;
    return report;
  }

  @override
  Future<bool> openSettings() async {
    settings++;
    return settingsOpen;
  }

  @override
  Future<bool> revealApplication() async {
    reveals++;
    return true;
  }
}

Future<void> _mount(WidgetTester tester, _Permissions permissions) async {
  tester.view.resetPhysicalSize();
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: CredentialFillSettings(permissions: permissions)),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native AX readiness is independent of keyboard event permission', () {
    final report = CredentialFillPermissionReport.fromMac({
      'format': 2,
      'platform': 'macos',
      'state': 'checked',
      'accessibilityTrusted': true,
      'postEventsTrusted': false,
    });
    expect(report.native, CredentialFillPermissionState.ready);
    expect(report.focus, CredentialFillPermissionState.permissionRequired);
    expect(
      () => CredentialFillPermissionReport.fromMac({
        'format': 2,
        'platform': 'macos',
        'state': 'checked',
        'accessibilityTrusted': 'true',
        'postEventsTrusted': true,
      }),
      throwsFormatException,
    );
    expect(
      () => CredentialFillPermissionReport.fromMac({
        'format': 1,
        'platform': 'macos',
        'state': 'ready',
      }),
      throwsFormatException,
    );
  });

  test(
    'unavailable helper preserves owner identity without permission flags',
    () {
      final report = CredentialFillPermissionReport.fromMac({
        'format': 2,
        'platform': 'macos',
        'state': 'unavailable',
        'errorCode': 'session_unavailable',
        'applicationName': 'chiyo',
        'applicationPath': '/Applications/chiyo.app',
      });
      expect(report.native, CredentialFillPermissionState.unavailable);
      expect(report.applicationPath, '/Applications/chiyo.app');
      expect(
        () => CredentialFillPermissionReport.fromMac({
          'format': 2,
          'platform': 'macos',
          'state': 'unavailable',
          'errorCode': 'session_unavailable',
          'accessibilityTrusted': true,
        }),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'guide opens actual settings only after an explicit native request',
    (tester) async {
      final p = _Permissions();
      await _mount(tester, p);
      await tester.pumpAndSettle();
      expect(p.reads, 1);
      expect(p.requests, 0);
      expect(p.settings, 0);
      expect(find.text('尚未获得辅助功能权限'), findsOneWidget);
      expect(find.text('/Applications/chiyo.app'), findsOneWidget);
      expect(find.textContaining('旧程序的授权记录'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fill-check-permission')));
      await tester.pumpAndSettle();
      expect(p.requests, 0);
      await tester.tap(find.byKey(const ValueKey('fill-request-permission')));
      await tester.pumpAndSettle();
      expect(p.requests, 1);
      expect(p.focusRequests, 0);
      expect(p.settings, 1);
      // Opening Settings and clicking an authorization button never grants access.
      expect(find.text('尚未获得辅助功能权限'), findsOneWidget);
      p.report = nativeReadyReport;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('后台填写权限已开启'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('fill-request-permission')),
        findsNothing,
      );
      expect(p.requests, 1);
    },
  );

  testWidgets('helper failure is not presented as missing system permission', (
    tester,
  ) async {
    final p = _Permissions()
      ..report = const CredentialFillPermissionReport.unavailable(
        'session_unavailable',
      );
    await _mount(tester, p);
    await tester.pumpAndSettle();
    expect(find.text('无法连接填写组件'), findsOneWidget);
    expect(find.text('尚未获得辅助功能权限'), findsNothing);
    expect(find.byKey(const ValueKey('fill-request-permission')), findsNothing);
    expect(find.textContaining('这不表示你没有打开系统开关'), findsOneWidget);
    expect(p.settings, 0);
  });

  testWidgets(
    'returning while a check is in flight queues a fresh passive check',
    (tester) async {
      final pending = Completer<CredentialFillPermissionReport>();
      final p = _Permissions()..delayedRead = pending;
      await _mount(tester, p);
      p.report = nativeReadyReport;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      pending.complete(requiredReport);
      await tester.pumpAndSettle();
      expect(p.reads, 2);
      expect(p.requests, 0);
      expect(find.text('后台填写权限已开启'), findsOneWidget);
    },
  );

  testWidgets(
    'native ready and compatibility blocked have separate visible states',
    (tester) async {
      final p = _Permissions()..report = nativeReadyReport;
      await _mount(tester, p);
      await tester.pumpAndSettle();
      final details = find.byKey(const ValueKey('fill-focus-details'));
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('后台填写权限已开启'), findsOneWidget);
      expect(find.text('兼容填写所需的系统权限尚未就绪'), findsOneWidget);
      expect(find.textContaining('浏览器连接接口，不需要上方'), findsOneWidget);
      expect(p.focusRequests, 0);
    },
  );

  testWidgets('failed settings navigation keeps the recovery steps visible', (
    tester,
  ) async {
    final p = _Permissions()..settingsOpen = false;
    await _mount(tester, p);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fill-request-permission')));
    await tester.pumpAndSettle();
    expect(find.textContaining('未能打开系统设置'), findsOneWidget);
    expect(find.text('尚未获得辅助功能权限'), findsOneWidget);
  });

  test('malformed or absent helper cannot advertise readiness', () async {
    const channel = MethodChannel('agent_info_manage/focused_fill');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'format': 1, 'platform': 'macos', 'state': 'ready'},
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(
      await const CredentialFillPermissions().read(),
      CredentialFillPermissionState.unavailable,
    );
  });
}
