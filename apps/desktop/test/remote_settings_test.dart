@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_remote/connection_profile.dart';
import 'support/online_ui_harness.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/settings_transport.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';

class _Http extends HttpOverrides {}

class _App {
  _App(this.source) {
    model = WorkspaceSettingsController(
      source.settings,
      source.changes,
      onTheme: (_) {},
    );
  }
  final RemoteWorkspaceSource source;
  late final WorkspaceSettingsController model;
  bool closed = false;
  static Future<_App> open(
    DeviceCredentialFixture f,
    String device, {
    OwnerReplyProxy? proxy,
  }) async {
    final client = await OwnerClient.connect(
      address: proxy?.address ?? f.owner.address,
      token: f.token,
      trust: f.trust,
    );
    final app = _App(
      RemoteWorkspaceSource(
        client,
        deviceFilesDirectory: '${f.root.path}/$device',
      ),
    );
    addTearDown(app.close);
    await app.model.load();
    expect(app.model.readFailure, isNull);
    return app;
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    model.dispose();
    await source.dispose();
  }
}

Future<OwnerReplyProxy> _proxy(DeviceCredentialFixture f) async {
  final p = await OwnerReplyProxy.start(
    tls: f.tls,
    trust: f.trust,
    target: () => f.owner.address,
    serverId: f.owner.serverId,
  );
  addTearDown(p.close);
  return p;
}

Future<List<File>> _files(DeviceCredentialFixture f, String device) async =>
    (await Directory(
      '${f.root.path}/$device',
    ).list(recursive: true).toList()).whereType<File>().toList();
Matcher _fails(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'normal online settings page preserves a legacy duration, saves local appearance and shared policy, and reloads the same private profile',
    (t) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _Http();
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final ui = OnlineUiHarness(t);
      DeviceCredentialFixture? f;
      RemoteWorkspaceSource? live;
      try {
        final profiles = await ui.resolve(() async {
          f = await DeviceCredentialFixture.create();
          await f!.runtime.run(
            () => f!.runtime.service.owner.setRequestLifetime(
              const Duration(minutes: 47),
            ),
          );
          final profiles = PrivateConnectionProfileStore(
            '${f!.root.path}/ui-profile',
          );
          await profiles.save(
            ConnectionProfile(
              address: f!.owner.address.toString(),
              token: f!.token,
              serverId: f!.owner.serverId,
              certificate: f!.certificate,
            ),
          );
          return profiles;
        });
        Future<void> open() async {
          await t.pumpWidget(OnlineDesktopLauncher(profiles: profiles));
          await ui.until(() => find.byType(WorkspaceApp).evaluate().isNotEmpty);
          live =
              t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                  as RemoteWorkspaceSource;
          await ui.tap('workspace-nav-settings');
          await ui.until(
            () =>
                find.byType(WorkspaceSettingsPage).evaluate().isNotEmpty &&
                t
                        .widget<WorkspaceSettingsPage>(
                          find.byType(WorkspaceSettingsPage),
                        )
                        .controller
                        .value !=
                    null,
          );
        }

        await open();
        var model = t
            .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
            .controller;
        expect(model.value!.requestMinutes, 47);
        await ui.tap('settings-theme-dark');
        await ui.until(
          () =>
              !model.frozen &&
              !model.loading &&
              model.value!.theme == WorkspaceTheme.dark,
        );
        expect(model.writeFailure, isNull);
        await ui.tap('settings-section-records');
        expect(find.text('47 分钟'), findsOneWidget);
        await ui.tap('settings-request-minutes');
        await ui.until(() => find.text('60 分钟').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('60 分钟').last));
        await t.pump();
        await ui.until(() => model.draft!.requestMinutes == 60);
        await ui.tap('settings-records-save');
        await ui.until(
          () =>
              !model.frozen &&
              !model.loading &&
              model.value!.requestMinutes == 60,
        );
        expect(model.writeFailure, isNull);
        expect(
          WorkspaceServerPolicy.fromJson(
            await ui.resolve(
              () => f!.owner.request('GET', '/v1/owner/settings'),
            ),
          ).requestMinutes,
          60,
        );
        await t.pumpWidget(const SizedBox());
        await ui.resolve(live!.dispose);
        live = null;
        await open();
        model = t
            .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
            .controller;
        expect(model.value!.theme, WorkspaceTheme.dark);
        expect(model.value!.requestMinutes, 60);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        if (live != null) await ui.resolve(live!.dispose);
        if (f != null) await ui.resolve(f!.dispose);
        HttpOverrides.global = previousHttp;
      }
    },
  );
  test(
    'device preferences stay independent while request and retention policy is shared and survives reopen',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final proxy = await _proxy(f);
        final a = await _App.open(f, 'device-a', proxy: proxy);
        final b = await _App.open(f, 'device-b');
        expect(a.model.value!.retentionDays, 90);
        await a.model.setTheme(WorkspaceTheme.dark);
        await a.model.setNotifications(false);
        await a.model.setBackground(false);
        expect(a.model.writeFailure, isNull);
        expect(proxy.requests['POST /v1/owner/settings/changes'], isNull);
        a.model.stage(
          a.model.value!.copyWith(requestMinutes: 60, retentionDays: 180),
        );
        await a.model.save();
        expect(a.model.writeFailure, isNull);
        expect(proxy.requests['POST /v1/owner/settings/changes'], 1);
        await b.model.load();
        expect(b.model.value!.requestMinutes, 60);
        expect(b.model.value!.retentionDays, 180);
        expect(b.model.value!.theme, WorkspaceTheme.light);
        expect(b.model.value!.notifications, isTrue);
        expect(b.model.value!.background, isTrue);
        await a.close();
        await f.reopen();
        final reopened = await _App.open(f, 'device-a');
        expect(reopened.model.value!.theme, WorkspaceTheme.dark);
        expect(reopened.model.value!.notifications, isFalse);
        expect(reopened.model.value!.background, isFalse);
        expect(reopened.model.value!.requestMinutes, 60);
        for (final file in await _files(f, 'device-a')) {
          expect((await file.stat()).mode & 0x1ff, 0x180);
          expect(await file.readAsString(), isNot(contains(f.token)));
          expect(file.path, isNot(endsWith('.db')));
        }
      }, _Http());
    },
  );
  test(
    'lost shared save reply restores the original frozen draft across App and service restart and reconciles without another POST',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final proxy = await _proxy(f);
        final a = await _App.open(f, 'lost', proxy: proxy);
        proxy.dropNextPath = '/v1/owner/settings/changes';
        a.model.stage(
          a.model.value!.copyWith(
            theme: WorkspaceTheme.dark,
            requestMinutes: 60,
          ),
        );
        await a.model.save();
        expect(a.model.uncertain, isTrue);
        expect(a.model.value!.theme, WorkspaceTheme.light);
        expect(a.model.canSave, isFalse);
        final stateFile = (await _files(
          f,
          'lost',
        )).singleWhere((e) => e.path.endsWith('/state.json'));
        final pending = jsonDecode(await stateFile.readAsString())['pending'];
        final command = settingsChangeFromJson(pending['change']);
        expect(
          WorkspaceServerPolicy.fromJson(
            await f.owner.request('GET', '/v1/owner/settings'),
          ).requestMinutes,
          60,
        );
        proxy.failGetPrefix = '/v1/owner/settings/operations/';
        await a.close();
        await f.reopen();
        final b = await _App.open(f, 'lost', proxy: proxy);
        expect(b.model.uncertain, isTrue);
        expect(b.model.draft!.theme, WorkspaceTheme.dark);
        expect(b.model.draft!.requestMinutes, 60);
        expect(b.model.value!.requestMinutes, 30);
        await b.model.reconcile();
        expect(b.model.uncertain, isTrue);
        proxy.failGetPrefix = null;
        await b.model.reconcile();
        expect(b.model.writeFailure, isNull);
        expect(b.model.value!.theme, WorkspaceTheme.dark);
        expect(b.model.value!.requestMinutes, 60);
        expect(proxy.requests['POST /v1/owner/settings/changes'], 1);
        final replay = await b.source.settings.change(command);
        expect(replay.commandDigest, command.digest);
        expect(replay.preferences.version, command.expectedVersion + 1);
        expect(proxy.requests['POST /v1/owner/settings/changes'], 1);
      }, _Http());
    },
  );
  test(
    'a failed pre-submit request confirms absence without publishing local changes and explicit retry uses a new operation',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final proxy = await _proxy(f);
        final a = await _App.open(f, 'absent', proxy: proxy);
        proxy.failPostPrefix = '/v1/owner/settings/changes';
        a.model.stage(
          a.model.value!.copyWith(
            theme: WorkspaceTheme.dark,
            requestMinutes: 60,
          ),
        );
        await a.model.save();
        expect(a.model.uncertain, isTrue);
        final file = (await _files(
          f,
          'absent',
        )).singleWhere((e) => e.path.endsWith('/state.json'));
        final pending = jsonDecode(await file.readAsString())['pending'];
        final original = settingsChangeFromJson(pending['change']);
        await a.model.reconcile();
        expect(a.model.writeFailure!.code, 'not_submitted');
        expect(a.model.value!.theme, WorkspaceTheme.light);
        expect((await a.source.settings.read()).requestMinutes, 30);
        proxy.failPostPrefix = null;
        await expectLater(
          a.source.settings.change(original),
          _fails('not_submitted'),
        );
        await a.model.save();
        expect(a.model.writeFailure, isNull);
        expect(a.model.value!.theme, WorkspaceTheme.dark);
        expect(a.model.value!.requestMinutes, 60);
        expect(proxy.requests['POST /v1/owner/settings/changes'], 2);
      }, _Http());
    },
  );
  test(
    'missing original operation or state metadata is unavailable rather than false absence or a reset',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final a = await _App.open(f, 'metadata');
        await a.model.setTheme(WorkspaceTheme.dark);
        expect(a.model.writeFailure, isNull);
        final files = await _files(f, 'metadata');
        final op = files.singleWhere(
          (e) => e.path.split('/').last.startsWith('operation-'),
        );
        final record = jsonDecode(await op.readAsString());
        final id = record['pending']['change']['operationId'] as String;
        await op.delete();
        await expectLater(
          a.source.settings.receipt(id),
          _fails('unknown_outcome'),
        );
        final state = files.singleWhere((e) => e.path.endsWith('/state.json'));
        await state.delete();
        await expectLater(
          a.source.settings.read(),
          _fails('settings_unavailable'),
        );
        expect(await state.exists(), isFalse);
      }, _Http());
    },
  );
  test(
    'real atomic publication failure after server acknowledgement remains uncertain and recovers from the prepared original receipt without resubmitting',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final proxy = await _proxy(f);
        final a = await _App.open(f, 'disk-failure', proxy: proxy);
        final state = (await _files(
          f,
          'disk-failure',
        )).singleWhere((e) => e.path.endsWith('/state.json'));
        final savedPath = '${state.path}.synthetic-held';
        var injected = false;
        proxy.beforeReply = (path) async {
          if (path != '/v1/owner/settings/changes') return;
          proxy.beforeReply = null;
          await state.rename(savedPath);
          await Directory(state.path).create();
          injected = true;
        };
        a.model.stage(
          a.model.value!.copyWith(
            theme: WorkspaceTheme.dark,
            requestMinutes: 60,
          ),
        );
        await a.model.save();
        expect(injected, isTrue);
        expect(a.model.uncertain, isTrue);
        expect(a.model.value!.theme, WorkspaceTheme.light);
        final records = (await _files(f, 'disk-failure'))
            .where((e) => e.path.split('/').last.startsWith('operation-'))
            .toList();
        expect(
          jsonDecode(await records.single.readAsString())['status'],
          'ready',
        );
        expect(
          WorkspaceServerPolicy.fromJson(
            await f.owner.request('GET', '/v1/owner/settings'),
          ).requestMinutes,
          60,
        );
        await Directory(state.path).delete();
        await File(savedPath).rename(state.path);
        await a.close();
        await f.reopen();
        final b = await _App.open(f, 'disk-failure', proxy: proxy);
        expect(b.model.uncertain, isTrue);
        await b.model.reconcile();
        expect(b.model.writeFailure, isNull);
        expect(b.model.value!.theme, WorkspaceTheme.dark);
        expect(b.model.value!.requestMinutes, 60);
        expect(proxy.requests['POST /v1/owner/settings/changes'], 1);
      }, _Http());
    },
  );
  test(
    'restoring a library invalidates unpublished settings without discarding already saved device preferences',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final proxy = await _proxy(f);
        final a = await _App.open(f, 'restore', proxy: proxy);
        await a.model.setTheme(WorkspaceTheme.dark);
        final key = await f.runtime.run(() => f.repo.backups.enable());
        final archive = '${f.root.path}/settings.aimbackup';
        await f.runtime.run(() async {
          await f.repo.backups.saveRecoveryKeyTo('${f.root.path}/settings.key');
          await f.runtime.service.owner.exportLibrary(
            () => f.repo.backups.exportTo(archive),
          );
        });
        proxy.dropNextPath = '/v1/owner/settings/changes';
        a.model.stage(
          a.model.value!.copyWith(
            theme: WorkspaceTheme.light,
            requestMinutes: 60,
          ),
        );
        await a.model.save();
        expect(a.model.uncertain, isTrue);
        await f.runtime.run(
          () => f.runtime.service.owner.restoreLibrary(
            () => f.repo.backups.restoreFrom(archive, key),
          ),
        );
        await a.model.reconcile();
        expect(a.model.writeFailure!.code, 'library_changed');
        expect(a.model.uncertain, isFalse);
        expect(a.model.value!.theme, WorkspaceTheme.dark);
        expect(a.model.value!.requestMinutes, 30);
        expect(proxy.requests['POST /v1/owner/settings/changes'], 1);
        await a.close();
        final b = await _App.open(f, 'restore');
        expect(b.model.uncertain, isFalse);
        expect(b.model.value!.theme, WorkspaceTheme.dark);
        expect(b.model.value!.requestMinutes, 30);
      }, _Http());
    },
  );
  test(
    'strict device settings transport rejects injected fields, invalid booleans and nonmatching versions',
    () {
      final c = WorkspaceSettingsChange(
        operationId: 'strict-device',
        expectedVersion: 1,
        desired: const WorkspacePreferences(),
      );
      final wire = settingsChangeToJson(c);
      expect(settingsChangeFromJson(wire).digest, c.digest);
      expect(
        () => settingsChangeFromJson({...wire, 'token': 'synthetic'}),
        throwsFormatException,
      );
      expect(
        () => settingsChangeFromJson({...wire, 'expectedVersion': 2}),
        throwsFormatException,
      );
      final prefs = preferencesToJson(c.desired);
      expect(
        () => preferencesFromJson({...prefs, 'notifications': 1}),
        throwsFormatException,
      );
      expect(
        () => preferencesFromJson({...prefs, 'path': '/synthetic'}),
        throwsFormatException,
      );
      final receipt = WorkspaceSettingsReceipt(
        operationId: c.operationId,
        commandDigest: c.digest,
        expectedVersion: 1,
        preferences: c.desired.copyWith(version: 3),
      );
      expect(
        () => settingsReceiptFromJson(settingsReceiptToJson(receipt)),
        throwsFormatException,
      );
    },
  );
  test(
    'retention confirmation is tied to the actual shared version and cannot be reused after another device changes settings',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final a = await _App.open(f, 'retention-a');
        a.model.stage(a.model.value!.copyWith(retentionDays: 180));
        await a.model.save();
        expect(a.model.writeFailure, isNull);
        final b = await _App.open(f, 'retention-b');
        a.model.stage(a.model.value!.copyWith(retentionDays: 90));
        expect(a.model.canSave, isFalse);
        await a.model.prepareRetention();
        expect(a.model.retentionFailure, isNull);
        a.model.confirmRetention(a.model.retentionPreview!);
        expect(a.model.canSave, isTrue);
        b.model.stage(b.model.value!.copyWith(requestMinutes: 60));
        await b.model.save();
        expect(b.model.writeFailure, isNull);
        await a.model.save();
        expect(a.model.writeFailure!.code, 'conflict');
        expect(a.model.retentionPreview, isNull);
        expect(
          WorkspaceServerPolicy.fromJson(
            await f.owner.request('GET', '/v1/owner/settings'),
          ).retentionDays,
          180,
        );
        await a.model.load();
        a.model.discard();
        a.model.stage(a.model.value!.copyWith(retentionDays: 90));
        await a.model.prepareRetention();
        a.model.confirmRetention(a.model.retentionPreview!);
        await a.model.save();
        expect(a.model.writeFailure, isNull);
        expect(a.model.value!.retentionDays, 90);
        expect(a.model.value!.requestMinutes, 60);
        final server = await f.runtime.run(
          () async => f.runtime.service.owner.desktopPreferences,
        );
        expect(server.dark, isFalse);
        expect(server.notifications, isTrue);
        expect(server.background, isTrue);
      }, _Http());
    },
  );
  test(
    'two App sources using the same private profile cannot overwrite an older device draft',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final a = await _App.open(f, 'same-device');
        final b = await _App.open(f, 'same-device');
        await a.model.setTheme(WorkspaceTheme.dark);
        expect(a.model.writeFailure, isNull);
        await b.model.setNotifications(false);
        expect(b.model.writeFailure!.code, 'conflict');
        final saved = await b.source.settings.read();
        expect(saved.theme, WorkspaceTheme.dark);
        expect(saved.notifications, isTrue);
        expect(b.model.draft!.notifications, isFalse);
        await b.model.load();
        b.model.discard();
        await b.model.setNotifications(false);
        expect(b.model.writeFailure, isNull);
        expect(b.model.value!.theme, WorkspaceTheme.dark);
        expect(b.model.value!.notifications, isFalse);
      }, _Http());
    },
  );
}
