// Ordinary Flutter application; real Cocoa notification permission and clicks.
// File gates coordinate dispatch only. They never inject native open callbacks.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/approvals.dart';
import 'package:info_desktop/inbox_queue.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 117);
  @override
  Future<void> create(List<int> key) async => throw StateError('QA key exists');
}

class _Platform extends NativeDesktopPlatform {
  Future<void> Function()? beforeTerminate;
  final events = <Map<String, Object?>>[];
  final submissionResults = <Map<String, Object?>>[];
  int permissionActions = 0, submissions = 0;
  @override
  Future<DesktopAvailability> initialize(
    Future<void> Function(DesktopEvent) callback,
  ) => super.initialize((event) async {
    events.add({'event': event.name, 'requestId': openedRequestId});
    await callback(event);
  });
  @override
  Future<DesktopAvailability> requestNotificationPermission() {
    permissionActions++;
    return super.requestNotificationPermission();
  }

  @override
  Future<bool> notifyNewRequest(String requestId) async {
    submissions++;
    final accepted = await super.notifyNewRequest(requestId);
    submissionResults.add({'requestId': requestId, 'accepted': accepted});
    return accepted;
  }

  @override
  Future<void> terminate() async {
    await beforeTerminate?.call();
    await super.terminate();
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Map<String, Object?> rendered(String id) {
  var detail = false, row = false;
  String? search, filter, focused;
  int? offset, activeTab;
  void visit(Element element) {
    final widget = element.widget;
    detail |= widget.key == PageStorageKey('detail-$id');
    row |= widget.key == ValueKey('request-$id');
    if (widget is TextField && widget.key == const ValueKey('inbox-search')) {
      search = widget.controller?.text;
    }
    if (widget is InboxQueue) {
      filter = widget.filter.name;
      offset = widget.page.offset;
      focused = widget.focused;
    }
    if (widget is IndexedStack &&
        widget.children.any((child) => child is Approvals)) {
      activeTab = widget.index;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return {
    'detailPresent': detail,
    'rowPresent': row,
    'inboxSearch': search,
    'inboxFilter': filter,
    'pageOffset': offset,
    'focusedRequestId': focused,
    'activeTab': activeTab,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final owner = Platform.environment['MAC_NOTIFICATION_OWNER'];
  final reusePermission =
      Platform.environment['MAC_NOTIFICATION_REUSE_PERMISSION'] == '1';
  final permissionSettings =
      Platform.environment['MAC_NOTIFICATION_PERMISSION_SETTINGS'] == '1';
  final stalePermission =
      Platform.environment['MAC_NOTIFICATION_STALE_PERMISSION'] == '1';
  final allowedOnce =
      Platform.environment['MAC_NOTIFICATION_ALLOWED_ONCE'] == '1';
  check(
    Platform.isMacOS &&
        owner != null &&
        RegExp(r'^[a-f0-9]{32}$').hasMatch(owner),
    'QA environment',
  );
  final root = await Directory.systemTemp.createTemp('aim-mac-notifications-');
  final canonical = await root.resolveSymbolicLinks();
  await File('$canonical/.qa-owner').writeAsString(owner!);
  stdout.writeln('MAC_NOTIFICATION_ROOT=$canonical');
  final report = File('$canonical/result.json');
  final facts = <String, Object?>{'complete': false, 'cases': <Object>[]};
  Future<void> save() => report.writeAsString(jsonEncode(facts), flush: true);
  Future<void> phase(String value) async {
    facts['phase'] = value;
    await save();
    stdout.writeln('MAC_NOTIFICATION_PHASE=$value');
  }

  Future<void> until(FutureOr<bool> Function() done, String description) async {
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    while (!await done()) {
      check(
        DateTime.now().isBefore(deadline),
        'Operator/OS deadline: $description',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  final platform = _Platform();
  var closes = 0, errors = 0;
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    errors++;
    previous?.call(details);
  };
  final bootstrap = DesktopBootstrap(
    port: 0,
    platform: platform,
    openLibrary: () async {
      final repository = await EncryptedInformationRepository.open(
        '$canonical/library',
        _Keys(),
      );
      final service = InformationService(repository: repository);
      // Prepared before runtime subscribes: no automatic notification burst.
      final item = await service.owner.createInformation('通知合成资料', '', [
        const FieldInput(
          '合成字段',
          '公开说明',
          'PRIVATE_SYNTHETIC_VALUE_NOT_FOR_NOTIFICATIONS',
        ),
      ]);
      final field = FieldRef(item.id, item.fields.single.id);
      for (var i = 0; i < 25; i++) {
        final session = service.agent.openSession('合成通知聊天 $i');
        service.agent.request(session, '通知定位合成场景 $i', [field]);
      }
      await service.owner.retryAuditStorage();
      return DesktopLibrary(
        service: service,
        close: () async {
          await repository.close();
          closes++;
        },
      );
    },
  );
  platform.beforeTerminate = () async {
    facts.addAll({
      'nativeTerminationRequested': true,
      'libraryCloses': closes,
      'flutterErrors': errors,
      'nativeEvents': platform.events,
      'permissionActions': platform.permissionActions,
      'submissions': platform.submissions,
      'terminatedBeforeComplete': facts['complete'] != true,
    });
    await save();
  };
  try {
    await bootstrap.start();
    check(bootstrap.state == DesktopStartupState.ready, 'Startup');
    final runtime = bootstrap.runtime!;
    final service = bootstrap.library!.service;
    final targets = service.owner
        .queryInbox(limit: 100)
        .entries
        .reversed
        .take(2)
        .toList();
    for (final target in targets) {
      check(
        service.owner.queryInbox(limit: 8, focusRequestId: target.id).offset >
            0,
        'Target must be outside first inbox page',
      );
    }
    facts.addAll({
      'initialNotificationState': runtime.availability.notifications.name,
      'permissionActionsBeforeUI': platform.permissionActions,
      'submissionsBeforeUI': platform.submissions,
      'tray': runtime.availability.tray,
      'port': bootstrap.boundPort,
    });
    check(
      platform.permissionActions == 0 && platform.submissions == 0,
      'Startup prompted or dispatched',
    );
    runApp(DesktopLauncher(bootstrap: bootstrap));
    facts['reusePermission'] = reusePermission;
    if (reusePermission) {
      // Reuse the prior real system decision; do not request permission or
      // silently simulate authorization if the grant is no longer available.
      check(
        runtime.availability.notifications == NotificationAvailability.enabled,
        'Existing notification permission unavailable; no request made',
      );
      await phase('reused-existing-system-permission');
    } else {
      await phase('permission-via-actual-settings');
      await until(
        () =>
            runtime.availability.notifications ==
                NotificationAvailability.enabled &&
            platform.permissionActions > 0,
        'actual Settings permission action',
      );
    }
    facts['notificationStateAfterUI'] = runtime.availability.notifications.name;
    facts['permissionActionsAfterUI'] = platform.permissionActions;
    if (allowedOnce) {
      check(reusePermission && !permissionSettings, 'Allowed probe mode');
      await service.owner.setNotificationsEnabled(true);
      final gate = File('$canonical/dispatch-allowed-once');
      await phase('allowed-ready-activate-qa-app-before-owned-dispatch-gate');
      await until(
        gate.exists,
        'CUA actual foreground before one allowed request',
      );
      check(
        await gate.readAsString() == owner,
        'Foreign allowed-dispatch gate',
      );
      final item = service.owner.information.single;
      final session = service.agent.openSession('允许通知正向合成聊天');
      final request = service.agent.request(session, '系统允许时正常提交一次', [
        FieldRef(item.id, item.fields.single.id),
      ]);
      await until(
        () => platform.submissionResults.length == 1,
        'Single allowed native completion',
      );
      check(
        platform.submissionResults.single['accepted'] == true,
        'Allowed path did not submit',
      );
      check(
        runtime.availability.notifications ==
                NotificationAvailability.enabled &&
            platform.permissionActions == 0,
        'Allowed path changed permission state',
      );
      check(
        service.owner
            .queryInbox(limit: 100)
            .entries
            .singleWhere((r) => r.id == request.id)
            .pending,
        'Allowed notification approved or lost request',
      );
      (facts['cases'] as List).add({
        'label': 'allowed-single-production-request',
        'requestId': request.id,
        'nativeAccepted': true,
        'notificationState': runtime.availability.notifications.name,
        'requestPending': true,
        'permissionActions': platform.permissionActions,
        'submissions': platform.submissions,
      });
      facts['complete'] = true;
      await phase('complete-await-native-quit');
      return;
    }
    if (permissionSettings) {
      check(reusePermission, 'Settings test requires existing system decision');
      await service.owner.setNotificationsEnabled(true);
      if (stalePermission) {
        final gate = File('$canonical/dispatch-after-system-denial');
        await phase('disable-only-qa-app-then-create-owned-dispatch-gate');
        await until(
          gate.exists,
          'CUA disabled actual system permission before request',
        );
        check(
          await gate.readAsString() == owner,
          'Foreign denied-dispatch gate',
        );
        check(
          runtime.availability.notifications ==
                  NotificationAvailability.enabled &&
              platform.permissionActions == 0,
          'App must retain actual initial cache until dispatch',
        );
        final item = service.owner.information.single;
        final session = service.agent.openSession('系统设置变化合成聊天');
        final request = service.agent.request(session, '系统关闭通知后保留申请', [
          FieldRef(item.id, item.fields.single.id),
        ]);
        await until(
          () => platform.submissionResults.length == 1,
          'Single actual native notification completion',
        );
        facts['deliveryAttempt'] = platform.submissionResults.single;
        await save();
        check(
          platform.submissionResults.single['accepted'] == false,
          'Stale system permission allowed notification submission',
        );
        await until(
          () =>
              runtime.availability.notifications ==
              NotificationAvailability.denied,
          'Production stale permission refresh',
        );
        check(
          service.owner
              .queryInbox(limit: 100)
              .entries
              .singleWhere((r) => r.id == request.id)
              .pending,
          'Changed permission lost request',
        );
        facts['stalePermissionObserved'] = true;
        (facts['cases'] as List).add({
          'label': 'actual-native-stale-permission',
          'requestId': request.id,
          'accepted': false,
          'runtimeState': runtime.availability.notifications.name,
          'requestPending': true,
          'submissions': platform.submissions,
        });
        await phase('stale-permission-observed-check-denied-in-app');
      }
      if (!stalePermission) {
        await phase('settings-enabled-ready-disable-only-this-qa-app');
      }
      await until(
        () =>
            runtime.availability.notifications ==
                NotificationAvailability.denied &&
            platform.permissionActions == 1,
        'CUA system Settings denial and actual app check button',
      );
      final item = service.owner.information.single;
      final session = service.agent.openSession('系统拒绝时的合成聊天');
      final request = service.agent.request(session, '系统拒绝不丢访问申请', [
        FieldRef(item.id, item.fields.single.id),
      ]);
      // Let the production request stream settle while denied. No direct call
      // to notify, no injected availability event or native settings response.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      check(
        service.owner.notificationsEnabled,
        'Application reminders must remain enabled',
      );
      check(
        platform.submissions == (stalePermission ? 1 : 0),
        'Denied system permission dispatched notification',
      );
      check(
        service.owner
            .queryInbox(limit: 100)
            .entries
            .singleWhere((r) => r.id == request.id)
            .pending,
        'Denied system permission lost request',
      );
      facts['pendingRequestPreservedWhileDenied'] = true;
      (facts['cases'] as List).add({
        'label': 'actual-settings-denied',
        'notificationState': runtime.availability.notifications.name,
        'permissionActions': platform.permissionActions,
        'submissions': platform.submissions,
        'requestId': request.id,
        'requestPending': true,
        'totalPending': service.owner
            .queryInbox(limit: 100)
            .entries
            .where((r) => r.pending)
            .length,
      });
      await phase('settings-denied-verified-restore-only-this-qa-app');
      await until(
        () =>
            runtime.availability.notifications ==
                NotificationAvailability.enabled &&
            platform.permissionActions == 2,
        'CUA system Settings restore and actual app check button',
      );
      check(
        platform.submissions == (stalePermission ? 1 : 0),
        'Restoring permission replayed notification',
      );
      check(
        service.owner
            .queryInbox(limit: 100)
            .entries
            .singleWhere((r) => r.id == request.id)
            .pending,
        'Restoring permission approved request',
      );
      facts['permissionSettingsRestored'] = true;
      (facts['cases'] as List).add({
        'label': 'actual-settings-restored',
        'notificationState': runtime.availability.notifications.name,
        'permissionActions': platform.permissionActions,
        'submissions': platform.submissions,
        'requestPending': true,
      });
      facts['complete'] = true;
      await phase('complete-await-native-quit');
      return;
    }
    for (var i = 0; i < targets.length; i++) {
      final label = i == 0 ? 'foreground' : 'background';
      final target = targets[i];
      final gate = File('$canonical/dispatch-$label');
      facts['currentTarget'] = {
        'label': label,
        'requestId': target.id,
        'purpose': target.purpose,
        'pageOffset': service.owner
            .queryInbox(limit: 8, focusRequestId: target.id)
            .offset,
      };
      await phase('prepare-$label-search-filter-and-other-page');
      await until(gate.exists, 'coordinated single $label dispatch');
      check(await gate.readAsString() == owner, 'Foreign dispatch');
      final before = rendered(target.id);
      facts['before-$label'] = before;
      await save();
      check(
        before['inboxSearch'] == 'no-such-notification-fixture' &&
            before['detailPresent'] == false,
        'CUA must leave a real nonmatching inbox search and another page',
      );
      if (reusePermission) {
        check(
          before['inboxFilter'] == 'handled' &&
              before['activeTab'] is int &&
              before['activeTab'] != 0,
          'CUA must also leave a handled filter and another actual page',
        );
      }
      final revision = runtime.openApprovalsRevision;
      final calls = platform.submissions;
      await phase('dispatching-$label');
      final submitted = await platform.notifyNewRequest(target.id);
      facts['apiAccepted-$label'] = submitted;
      check(
        platform.submissions == calls + 1,
        'Exactly one submission per coordinated case',
      );
      await phase('await-actual-system-click-$label');
      // Callback identity, not app activation or API return, proves routing.
      await until(
        () =>
            runtime.openApprovalsRevision > revision &&
            platform.openedRequestId == target.id &&
            runtime.openRequestId == target.id,
        'genuine system click $label',
      );
      await WidgetsBinding.instance.endOfFrame;
      final after = rendered(target.id);
      check(
        after['detailPresent'] == true &&
            after['rowPresent'] == true &&
            after['inboxSearch'] == '',
        'Actual notification did not reveal exact request and clear search',
      );
      if (reusePermission) {
        check(
          after['inboxFilter'] == 'all' &&
              after['activeTab'] == 0 &&
              after['focusedRequestId'] == target.id &&
              after['pageOffset'] ==
                  service.owner
                      .queryInbox(limit: 8, focusRequestId: target.id)
                      .offset,
          'Notification did not clear filter and select exact off-page request',
        );
      }
      check(
        service.owner
            .queryInbox(limit: 100)
            .entries
            .singleWhere((r) => r.id == target.id)
            .pending,
        'Click approved or changed request',
      );
      (facts['cases'] as List).add({
        'label': label,
        'requestId': target.id,
        'apiAccepted': submitted,
        'before': before,
        'after': after,
        'revisionAdvanced': true,
        'nativeOpenedRequestId': platform.openedRequestId,
        'runtimeOpenedRequestId': runtime.openRequestId,
        'pendingUnchanged': true,
        'submissions': platform.submissions,
      });
      await phase('verified-$label');
    }
    facts.addAll({
      'complete': true,
      'flutterErrors': errors,
      'submissions': platform.submissions,
    });
    await phase('complete-await-native-quit');
  } catch (error) {
    facts['failed'] = error.toString();
    facts['flutterErrors'] = errors;
    await phase('failed');
    stdout.writeln('MAC_NOTIFICATION_FAILED=${error.runtimeType}');
  }
}
