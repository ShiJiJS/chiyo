@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/runtime_page.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_remote/connection_profile.dart';
import 'support/online_ui_harness.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/online_desktop_runtime.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/runtime_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/file_transport.dart';
import '../../server/test/support/device_credential_fixture.dart';
import 'support/desktop_platform_fixture.dart';

class _Http extends HttpOverrides {}

class _Native extends NativeDesktopFixture {
  int hides = 0, exits = 0;
  Future<void> Function()? beforeHideReply;
  @override
  Future<bool> hideWindow() async {
    hides++;
    final result = await super.hideWindow();
    await beforeHideReply?.call();
    return result;
  }

  @override
  Future<void> terminate() async {
    exits++;
    await super.terminate();
  }
}

class _Dispatch implements OwnerFileOpenDispatcher {
  InformationDeliveryLease? lease;
  int count = 0;
  @override
  Future<OwnerFileDispatchOutcome> open(
    String id,
    String digest,
    InformationDeliveryLease copy,
    int length,
    String hash,
  ) async {
    count++;
    lease = copy;
    await NativeInformationDeliveryFiles().verify(copy, length, hash);
    return OwnerFileDispatchOutcome.opened;
  }

  @override
  Future<OwnerFileDispatchOutcome?> status(String id, String digest) async =>
      OwnerFileDispatchOutcome.opened;
}

class _App {
  _App(this.s, this.desktop, this.native)
    : m = WorkspaceRuntimeController(s.runtime, const Stream.empty());
  final RemoteWorkspaceSource s;
  final OnlineDesktopRuntime desktop;
  final _Native native;
  final WorkspaceRuntimeController m;
  static Future<_App> open(
    DeviceCredentialFixture f, {
    _Dispatch? dispatch,
  }) async {
    final native = _Native();
    late final RemoteWorkspaceSource source;
    final desktop = OnlineDesktopRuntime(
      platform: native,
      beforeExit: () => source.dispose(),
      onResume: () async {},
    );
    final c = await OwnerClient.connect(
      address: f.owner.address,
      token: f.token,
      trust: f.trust,
    );
    source = RemoteWorkspaceSource(
      c,
      desktopRuntime: desktop,
      deviceFilesDirectory: '${f.root.path}/app-files',
      onClosing: desktop.release,
      openDispatcher: dispatch ?? _Dispatch(),
    );
    final app = _App(source, desktop, native);
    addTearDown(() async {
      app.m.dispose();
      desktop.dispose();
      await source.dispose();
    });
    await desktop.start();
    await desktop.bind(source);
    await app.m.load();
    expect(app.m.readFailure, isNull);
    return app;
  }
}

Matcher _fails(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'original runtime controller observes current App actions, rejects stale quit preview and never ends server chats',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final a = await _App.open(f);
        expect(a.m.value!.independentServer, isTrue);
        await a.m.write(WorkspaceRuntimeAction.hideWindow);
        expect(a.m.failure, isNull);
        expect(a.m.value!.windowHidden, isTrue);
        final result = a.m.result!;
        final original = WorkspaceRuntimeChange(
          operationId: result.operationId,
          action: result.action,
          expectedVersion: result.expectedVersion,
        );
        expect(
          (await a.s.runtime.change(original)).commandDigest,
          result.commandDigest,
        );
        expect(a.native.hides, 1);
        await expectLater(
          a.s.runtime.change(
            WorkspaceRuntimeChange(
              operationId: result.operationId,
              action: WorkspaceRuntimeAction.showWindow,
              expectedVersion: result.expectedVersion,
            ),
          ),
          _fails('operation_conflict'),
        );
        await a.m.prepareQuit();
        await f.agents.first.call('/session/lifecycle', {
          'chatLabel': 'still-working',
        });
        await a.m.write(WorkspaceRuntimeAction.quit);
        expect(a.m.failure!.code, 'conflict');
        expect(a.native.exits, 0);
        await a.m.prepareQuit();
        expect(a.m.quitPreview!.sessions, 1);
        await a.m.write(WorkspaceRuntimeAction.quit);
        expect(a.m.failure, isNull);
        expect(a.native.exits, 1);
        expect(a.m.value!.phase, WorkspaceRuntimePhase.stopped);
        expect(f.runtime.service.owner.sessions.single.ended, isFalse);
        expect(
          (await f.agents.first.call('/capabilities', {}))['status'],
          'ok',
        );
        expect(
          (await a.s.runtime.receipt(a.m.result!.operationId))!.phase,
          WorkspaceRuntimePhase.stopped,
        );
      }, _Http());
    },
  );
  test(
    'actual Owner copy maintenance preserves active App copy and closes only that registered copy',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final dispatch = _Dispatch();
        final a = await _App.open(f, dispatch: dispatch);
        final candidate = fileCandidateFromJson(
          (await f.owner.request('POST', '/v1/owner/files/uploads', {
            'operationId': 'runtime-upload',
            'originalName': 'synthetic.txt',
            'mediaType': 'text/plain',
            'bytes': base64Encode(utf8.encode('SYNTHETIC OWNER FILE')),
          }))['candidate'],
        );
        final ref = await a.s.importFile(
          WorkspaceFileImport(
            operationId: 'runtime-import',
            selectionId: candidate.selectionId,
            name: '合成附件',
          ),
        );
        final detail = await a.s.readDetail(ref),
            key = (await a.s.readDetail(ref)).fieldIds.keys.single;
        await a.s.fileAction(
          ref,
          key,
          1,
          WorkspaceFileAction.open,
          operationId: 'runtime-owner-open',
        );
        await a.m.load();
        expect(a.m.value!.ownerCopies, hasLength(1));
        expect(a.m.value!.ownerCopies.single.active, isTrue);
        expect(a.m.value!.copies, isEmpty);
        await a.m.write(WorkspaceRuntimeAction.checkAttachments);
        expect(a.m.failure, isNull);
        expect(a.m.result!.checked, 1);
        expect(a.m.result!.released, 0);
        expect(a.m.result!.retained, 1);
        expect(
          await File(dispatch.lease!.filePath).readAsString(),
          'SYNTHETIC OWNER FILE',
        );
        expect(dispatch.count, 1);
        await a.s.finishFileOpen('runtime-owner-open');
        await a.m.load();
        expect(a.m.value!.ownerCopies, isEmpty);
        expect(await File(dispatch.lease!.filePath).exists(), isFalse);
        expect(
          (await a.s.readFilePreview(ref, key, version: 1)).text,
          'SYNTHETIC OWNER FILE',
        );
        expect((await a.s.readDetail(ref)).version, detail.version);
      }, _Http());
    },
  );
  test(
    'failed result publication keeps exact known action and reconciliation does not hide the window twice',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final a = await _App.open(f);
        const id = 'runtime-result-write-failure';
        final scope = sha256.convert(utf8.encode(a.s.client.serverId));
        final file = File(
          '${f.root.path}/app-files/runtime/$scope/${sha256.convert(utf8.encode(id))}.json',
        );
        final held = '${file.path}.synthetic-held';
        a.native.beforeHideReply = () async {
          a.native.beforeHideReply = null;
          await file.rename(held);
          await Directory(file.path).create();
        };
        final c = WorkspaceRuntimeChange(
          operationId: id,
          action: WorkspaceRuntimeAction.hideWindow,
          expectedVersion: a.m.value!.version,
        );
        await expectLater(a.s.runtime.change(c), _fails('unknown_outcome'));
        expect(a.native.hides, 1);
        await expectLater(a.s.runtime.receipt(id), _fails('unknown_outcome'));
        await Directory(file.path).delete();
        await File(held).rename(file.path);
        final r = (await a.s.runtime.receipt(id))!;
        expect(r.matches(c), isTrue);
        expect(r.windowHidden, isTrue);
        expect((await a.s.runtime.change(c)).commandDigest, c.digest);
        expect(a.native.hides, 1);
        await file.delete();
        await expectLater(a.s.runtime.receipt(id), _fails('unknown_outcome'));
      }, _Http());
    },
  );
  testWidgets(
    'normal online runtime page separates server reports and App files and exits without ending chats',
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
        final profiles = await ui.resolve(() async {
          f = await DeviceCredentialFixture.create();
          await f!.agents.first.call('/session/lifecycle', {
            'chatLabel': 'UI continuing chat',
          });
          final p = PrivateConnectionProfileStore('${f!.root.path}/profile');
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
        live =
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source
                as RemoteWorkspaceSource;
        await ui.tap('workspace-nav-settings');
        await ui.tap('settings-section-runtime');
        await ui.until(
          () =>
              find.byType(WorkspaceRuntimePage).evaluate().isNotEmpty &&
              t
                      .widget<WorkspaceRuntimePage>(
                        find.byType(WorkspaceRuntimePage),
                      )
                      .controller
                      .value !=
                  null,
        );
        final m = t
            .widget<WorkspaceRuntimePage>(find.byType(WorkspaceRuntimePage))
            .controller;
        expect(m.value!.independentServer, isTrue);
        expect(m.readFailure, isNull);
        await ui.tap('runtime-materials');
        await ui.tap('runtime-maintenance-check');
        await ui.until(
          () =>
              m.result?.action == WorkspaceRuntimeAction.checkMaterials &&
              !m.busy,
        );
        expect(find.textContaining('没有处理这些进程'), findsOneWidget);
        await ui.tap('runtime-maintenance-close');
        await ui.tap('runtime-quit');
        await ui.until(() => m.quitPreview != null && !m.preparing);
        expect(find.textContaining('将结束'), findsNothing);
        expect(find.textContaining('本次退出不会使它们失效'), findsOneWidget);
        await ui.tap('runtime-quit-confirm');
        await ui.until(() => native.terminated);
        expect(f!.runtime.service.owner.sessions.single.ended, isFalse);
        expect(
          (await ui.resolve(
            () => f!.agents.first.call('/capabilities', {}),
          ))['status'],
          'ok',
        );
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
    'reopening preserves an old unresolved native result without replaying it or blocking a fresh window lifetime',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final a = await _App.open(f);
        const id = 'runtime-crash-before-result';
        final scope = sha256.convert(utf8.encode(a.s.client.serverId));
        final file = File(
          '${f.root.path}/app-files/runtime/$scope/${sha256.convert(utf8.encode(id))}.json',
        );
        final held = '${file.path}.synthetic-held';
        a.native.beforeHideReply = () async {
          a.native.beforeHideReply = null;
          await file.rename(held);
          await Directory(file.path).create();
        };
        final c = WorkspaceRuntimeChange(
          operationId: id,
          action: WorkspaceRuntimeAction.hideWindow,
          expectedVersion: a.m.value!.version,
        );
        await expectLater(a.s.runtime.change(c), _fails('unknown_outcome'));
        await Directory(file.path).delete();
        await File(held).rename(file.path);
        a.desktop.dispose();
        await a.s.dispose();
        final fresh = await _App.open(f);
        await expectLater(
          fresh.s.runtime.receipt(id),
          _fails('unknown_outcome'),
        );
        await expectLater(fresh.s.runtime.change(c), _fails('unknown_outcome'));
        expect(fresh.native.hides, 0);
        await fresh.m.write(WorkspaceRuntimeAction.hideWindow);
        expect(fresh.m.failure, isNull);
        expect(fresh.native.hides, 1);
        expect(jsonDecode(await file.readAsString())['state'], 'pending');
      }, _Http());
    },
  );
}
