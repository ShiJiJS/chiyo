@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_remote/connection_profile.dart';
import 'support/online_ui_harness.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/online_desktop_runtime.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';
import 'support/desktop_platform_fixture.dart';

class _Http extends HttpOverrides {}

class _Native extends NativeDesktopFixture {
  int exits = 0;
  bool exitFails = false;
  Future<void>? showGate;
  Future<void>? noticeGate;
  final requestIds = <String>[];
  @override
  Future<void> terminate() async {
    exits++;
    if (exitFails) throw StateError('synthetic native failure');
    await super.terminate();
  }

  @override
  Future<void> showWindow() async {
    await showGate;
    await super.showWindow();
  }

  @override
  Future<bool> notifyNewRequest(String id) async {
    requestIds.add(id);
    await noticeGate;
    return super.notifyNewRequest(id);
  }
}

Future<RemoteWorkspaceSource> _source(
  DeviceCredentialFixture f, {
  Future<void> Function()? onNotificationEnable,
  Future<void> Function(RemoteWorkspaceSource)? onClosing,
}) async {
  final client = await OwnerClient.connect(
    address: f.owner.address,
    token: f.token,
    trust: f.trust,
  );
  final s = RemoteWorkspaceSource(
    client,
    deviceFilesDirectory: '${f.root.path}/app-files',
    onNotificationEnable: onNotificationEnable,
    onClosing: onClosing,
  );
  addTearDown(s.dispose);
  return s;
}

Future<WorkspaceSettingsReceipt> _save(
  RemoteWorkspaceSource s,
  WorkspacePreferences Function(WorkspacePreferences) change,
) async {
  final before = await s.settings.read();
  return s.settings.change(
    WorkspaceSettingsChange(
      operationId: workspaceOperationId(),
      expectedVersion: before.version,
      desired: change(before),
    ),
  );
}

Future<(String, Map<String, dynamic>)> _request(
  DeviceCredentialFixture f,
  String operation,
) async {
  final item = await f.runtime.run(
    () => f.runtime.service.owner.createInformation('合成资料', '', [
      const FieldInput('内容', '', 'SYNTHETIC_PRIVATE_BODY'),
    ]),
  );
  final chat = await f.agents.first.call('/session/lifecycle', {
    'chatLabel': '合成聊天',
  });
  final result = await f.agents.first.call('/request', {
    'sessionSecret': chat['sessionSecret'],
    'operationId': operation,
    'purpose': '合成读取',
    'fields': [
      {'itemId': item.id, 'fieldId': item.fields.single.id},
    ],
  });
  return (
    result['requestId'] as String,
    {...chat, 'itemId': item.id, 'fieldId': item.fields.single.id},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'normal online launcher hides, routes a real request notification, quits without ending CLI access and reconnects with the same profile',
    (t) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Http();
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      DeviceCredentialFixture? f;
      RemoteWorkspaceSource? live;
      try {
        late Map<String, dynamic> chat, grant;
        final profiles = await ui.resolve(() async {
          f = await DeviceCredentialFixture.create();
          final requested = await _request(f!, 'approved-before-launch');
          chat = requested.$2;
          await f!.runtime.run(
            () async => f!.runtime.service.owner.approve(requested.$1, [
              FieldRef(chat['itemId'] as String, chat['fieldId'] as String),
            ], lifetime: const Duration(minutes: 10)),
          );
          grant = await f!.agents.first.call('/claim', {
            'sessionSecret': chat['sessionSecret'],
            'requestId': requested.$1,
          });
          final p = PrivateConnectionProfileStore(
            '${f!.root.path}/online-profile',
          );
          await p.save(
            ConnectionProfile(
              address: f!.owner.address.toString(),
              token: f!.token,
              serverId: f!.owner.serverId,
              certificate: f!.certificate,
            ),
          );
          return p;
        });
        final native = _Native();
        await t.pumpWidget(
          OnlineDesktopLauncher(profiles: profiles, desktopPlatform: native),
        );
        await ui.until(() => find.byType(WorkspaceApp).evaluate().isNotEmpty);
        var app = t.widget<WorkspaceApp>(find.byType(WorkspaceApp));
        live = app.source as RemoteWorkspaceSource;
        final runtime = app.desktop! as OnlineDesktopRuntime;
        await ui.resolve(runtime.refresh);
        expect(runtime.preferences, isNotNull);
        await ui.resolve(() => native.events!(DesktopEvent.closeWindow));
        expect(runtime.windowHidden, isTrue);
        expect(native.terminated, isFalse);
        final request = await ui.resolve(() => _request(f!, 'new-while-open'));
        await ui.until(() => native.requestIds.contains(request.$1));
        native.openedRequestId = request.$1;
        await ui.resolve(() => native.events!(DesktopEvent.openApprovals));
        await ui.until(
          () =>
              find.byType(ApprovalsPage).evaluate().isNotEmpty &&
              t
                      .widget<ApprovalsPage>(find.byType(ApprovalsPage))
                      .controller
                      .detail
                      ?.request
                      .id ==
                  request.$1,
        );
        expect(runtime.windowHidden, isFalse);
        expect(
          f!.runtime.service.owner.requests
              .singleWhere((r) => r.id == request.$1)
              .state,
          AccessRequestState.pending,
        );
        await ui.resolve(() => native.events!(DesktopEvent.quit));
        expect(native.terminated, isTrue);
        expect(find.byType(WorkspaceApp), findsNothing);
        expect(runtime.closed, isTrue);
        expect(
          (await ui.resolve(
            () => f!.agents.first.call('/read', {
              'token': grant['token'],
              'itemId': chat['itemId'],
              'fieldId': chat['fieldId'],
            }),
          ))['value'],
          'SYNTHETIC_PRIVATE_BODY',
        );
        live = null;
        await t.pumpWidget(const SizedBox());
        final reopenedNative = _Native();
        await t.pumpWidget(
          OnlineDesktopLauncher(
            profiles: profiles,
            desktopPlatform: reopenedNative,
          ),
        );
        await ui.until(() => find.byType(WorkspaceApp).evaluate().isNotEmpty);
        app = t.widget<WorkspaceApp>(find.byType(WorkspaceApp));
        live = app.source as RemoteWorkspaceSource;
        final rows = await ui.resolve(
          () => live!.queryRecords(const WorkspaceQuery()),
        );
        expect(rows.total, 2);
        expect(
          (await ui.resolve(
            () => live!.approvals.read(request.$1),
          )).request.state,
          WorkspaceApprovalState.pending,
        );
        expect(reopenedNative.notices, isEmpty);
        expect(reopenedNative.permissionRequests, 0);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (live != null) await ui.resolve(live.dispose);
        if (f != null) await ui.resolve(f!.dispose);
        HttpOverrides.global = previous;
      }
    },
  );
  test(
    'quitting the App closes only its source and the same remote Agent can still read its valid grant',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final (request, chat) = await _request(f, 'continue-after-app-exit');
        await f.runtime.run(
          () async => f.runtime.service.owner.approve(request, [
            FieldRef(chat['itemId'] as String, chat['fieldId'] as String),
          ], lifetime: const Duration(minutes: 10)),
        );
        final grant = await f.agents.first.call('/claim', {
          'sessionSecret': chat['sessionSecret'],
          'requestId': request,
        });
        final s = await _source(f);
        final native = _Native();
        var closes = 0;
        final runtime = OnlineDesktopRuntime(
          platform: native,
          beforeExit: () async {
            closes++;
            await s.dispose();
          },
          onResume: () async {},
        );
        addTearDown(runtime.dispose);
        await runtime.start();
        await runtime.bind(s);
        await runtime.quit();
        await runtime.quit();
        expect(runtime.closed, isTrue);
        expect(runtime.shutdownFailed, isFalse);
        expect(native.exits, 1);
        expect(closes, 1);
        expect(
          (await f.owner.request('GET', '/v1/server'))['serverId'],
          f.owner.serverId,
        );
        expect(
          (await f.agents.first.call('/read', {
            'token': grant['token'],
            'itemId': chat['itemId'],
            'fieldId': chat['fieldId'],
          }))['value'],
          'SYNTHETIC_PRIVATE_BODY',
        );
        expect(f.runtime.service.owner.sessions.single.ended, isFalse);
      }, _Http());
    },
  );
  test(
    'startup and resume do not request notification permission or replay reminders; new pending requests use only opaque IDs',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        await _request(f, 'before-start');
        final s = await _source(f);
        final native = _Native();
        var resumes = 0;
        final runtime = OnlineDesktopRuntime(
          platform: native,
          beforeExit: () async {},
          onResume: () async {
            resumes++;
          },
        );
        addTearDown(runtime.dispose);
        await runtime.start();
        await runtime.bind(s);
        expect(native.notices, isEmpty);
        expect(native.permissionRequests, 0);
        final (request, _) = await _request(f, 'new-request');
        await runtime.refresh();
        await runtime.refresh();
        await native.events!(DesktopEvent.resumed);
        expect(resumes, 1);
        expect(native.requestIds, [request]);
        expect(native.permissionRequests, 0);
        await _save(s, (p) => p.copyWith(notifications: false));
        await runtime.refresh();
        await _request(f, 'disabled-request');
        await runtime.refresh();
        expect(native.requestIds, [request]);
        await runtime.bind(s);
        expect(native.requestIds, [request]);
      }, _Http());
    },
  );
  test(
    'only an explicit notification enabling save can request system permission, with no replay from receipt or unrelated saves',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final native = _Native()
          ..availability = const DesktopAvailability(
            tray: true,
            notifications: NotificationAvailability.notEnabled,
          );
        late final OnlineDesktopRuntime runtime;
        final s = await _source(
          f,
          onNotificationEnable: () => runtime.enableNotifications(),
        );
        runtime = OnlineDesktopRuntime(
          platform: native,
          beforeExit: () async {},
          onResume: () async {},
        );
        addTearDown(runtime.dispose);
        await runtime.start();
        await runtime.bind(s);
        expect(native.permissionRequests, 0);
        await _save(s, (p) => p.copyWith(notifications: false));
        final receipt = await _save(s, (p) => p.copyWith(notifications: true));
        expect(native.permissionRequests, 1);
        expect(
          (await s.settings.receipt(receipt.operationId))!.commandDigest,
          receipt.commandDigest,
        );
        await _save(s, (p) => p.copyWith(theme: WorkspaceTheme.dark));
        await runtime.handleEvent(DesktopEvent.resumed);
        expect(native.permissionRequests, 1);
        expect((await s.settings.read()).notifications, isTrue);
      }, _Http());
    },
  );
  test(
    'window hiding requires a reachable menu, and delayed navigation cannot escape a modal gate',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final s = await _source(f);
        final native = _Native();
        final runtime = OnlineDesktopRuntime(
          platform: native,
          beforeExit: () async {},
          onResume: () async {},
        );
        addTearDown(runtime.dispose);
        await runtime.start();
        await runtime.bind(s);
        await native.events!(DesktopEvent.closeWindow);
        expect(runtime.windowHidden, isTrue);
        final pages = <WorkspacePage>[], requests = <String>[];
        runtime.onNavigate = pages.add;
        runtime.onOpenRequest = requests.add;
        native.openedRequestId = 'opaque-request';
        await native.events!(DesktopEvent.openApprovals);
        expect(requests, ['opaque-request']);
        expect(runtime.windowHidden, isFalse);
        final show = Completer<void>();
        native.showGate = show.future;
        final delayed = native.events!(DesktopEvent.openSettings);
        await runtime.setNavigationEnabled(false);
        await runtime.setNavigationEnabled(true);
        show.complete();
        await delayed;
        expect(pages, isEmpty);
        native.showGate = null;
        await native.events!(DesktopEvent.openSettings);
        expect(pages, [WorkspacePage.settings]);
        native.availability = const DesktopAvailability(
          tray: false,
          notifications: NotificationAvailability.enabled,
        );
        await native.events!(DesktopEvent.availabilityChanged);
        expect(await runtime.hideWindow(), isFalse);
        expect(runtime.windowHidden, isFalse);
        await _save(s, (p) => p.copyWith(background: false));
        await runtime.refresh();
        await runtime.setNavigationEnabled(false);
        await native.events!(DesktopEvent.closeWindow);
        expect(native.exits, 0);
        await expectLater(native.events!(DesktopEvent.quit), throwsStateError);
        await runtime.setNavigationEnabled(true);
        await native.events!(DesktopEvent.closeWindow);
        expect(native.exits, 1);
      }, _Http());
    },
  );
  test(
    'failed native termination retries only termination and does not close resources twice',
    () async {
      final native = _Native()..exitFails = true;
      var closes = 0;
      final runtime = OnlineDesktopRuntime(
        platform: native,
        beforeExit: () async {
          closes++;
        },
        onResume: () async {},
      );
      addTearDown(runtime.dispose);
      await runtime.start();
      await runtime.quit();
      expect(runtime.closed, isFalse);
      expect(runtime.resourcesClosed, isTrue);
      expect(runtime.shutdownFailed, isTrue);
      native.exitFails = false;
      await runtime.quit();
      expect(closes, 1);
      expect(native.exits, 2);
      expect(runtime.closed, isTrue);
    },
  );
  test(
    'failed original App close is retained for explicit retry without stopping the independent server',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        var attempts = 0;
        final s = await _source(
          f,
          onClosing: (_) async {
            attempts++;
            if (attempts == 1) throw StateError('synthetic pre-close failure');
          },
        );
        final native = _Native();
        final runtime = OnlineDesktopRuntime(
          platform: native,
          beforeExit: s.dispose,
          onResume: () async {},
        );
        addTearDown(runtime.dispose);
        await runtime.start();
        await runtime.bind(s);
        await runtime.quit();
        expect(runtime.shutdownFailed, isTrue);
        expect(runtime.resourcesClosed, isFalse);
        expect(native.exits, 0);
        expect(
          (await f.owner.request('GET', '/v1/server'))['serverId'],
          f.owner.serverId,
        );
        await runtime.quit();
        expect(runtime.closed, isTrue);
        expect(attempts, 2);
        expect(native.exits, 1);
      }, _Http());
    },
  );
  testWidgets(
    'a pending system notification cannot delay the normal offline blocker',
    (t) async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _Http();
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      DeviceCredentialFixture? f;
      OwnerReplyProxy? proxy;
      RemoteWorkspaceSource? live;
      final delivery = Completer<void>();
      try {
        final profiles = await ui.resolve(() async {
          f = await DeviceCredentialFixture.create();
          proxy = await OwnerReplyProxy.start(
            tls: f!.tls,
            trust: f!.trust,
            target: () => f!.owner.address,
            serverId: f!.owner.serverId,
          );
          final p = PrivateConnectionProfileStore(
            '${f!.root.path}/health-profile',
          );
          await p.save(
            ConnectionProfile(
              address: proxy!.address.toString(),
              token: f!.token,
              serverId: f!.owner.serverId,
              certificate: f!.certificate,
            ),
          );
          return p;
        });
        final native = _Native()..noticeGate = delivery.future;
        await t.pumpWidget(
          OnlineDesktopLauncher(profiles: profiles, desktopPlatform: native),
        );
        await ui.until(() => find.byType(WorkspaceApp).evaluate().isNotEmpty);
        final app = t.widget<WorkspaceApp>(find.byType(WorkspaceApp));
        live = app.source as RemoteWorkspaceSource;
        await ui.resolve((app.desktop! as OnlineDesktopRuntime).refresh);
        final pending = await ui.resolve(
          () => _request(f!, 'slow-native-notification'),
        );
        await ui.until(() => native.requestIds.contains(pending.$1));
        proxy!.failGetPrefix = '/v1/server';
        await ui.until(
          () => ui.key('online-offline-blocker').evaluate().isNotEmpty,
        );
        expect(delivery.isCompleted, isFalse);
        expect(native.permissionRequests, 0);
      } finally {
        if (!delivery.isCompleted) delivery.complete();
        await t.pumpWidget(const SizedBox());
        if (live != null) await ui.resolve(live.dispose);
        if (proxy != null) await ui.resolve(proxy!.close);
        if (f != null) await ui.resolve(f!.dispose);
        HttpOverrides.global = previous;
      }
    },
  );
}
