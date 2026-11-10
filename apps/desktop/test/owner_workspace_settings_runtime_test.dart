import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/workspace/owner_workspace_settings.dart';
import 'package:info_desktop/workspace/owner_workspace_runtime.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'support/desktop_platform_fixture.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async {
    value = List.of(key);
  }
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late NativeDesktopFixture native;
  late DesktopRuntime runtime;
  late OwnerWorkspaceSettings settings;
  late OwnerWorkspaceRuntime source;
  var changes = 0;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
    native = NativeDesktopFixture();
    runtime = DesktopRuntime(
      service: service,
      platform: native,
      closeServer: () async {},
      closeRepository: repo.close,
    );
    await runtime.start();
    settings = OwnerWorkspaceSettings(
      owner: service.owner,
      runtime: runtime,
      changed: () => changes++,
    );
    source = OwnerWorkspaceRuntime(runtime: runtime, changed: () => changes++);
  }

  Future<void> close() async {
    if (!runtime.stopped) await runtime.stop();
    runtime.dispose();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-settings-runtime-');
    keys = _Keys();
    changes = 0;
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Future<WorkspaceRuntimeReceipt> action(
    WorkspaceRuntimeAction a, {
    String? token,
    int? version,
  }) async {
    final s = await source.status();
    return source.change(
      WorkspaceRuntimeChange(
        operationId: workspaceOperationId(),
        action: a,
        expectedVersion: version ?? s.version,
        quitToken: token,
      ),
    );
  }

  test(
    'real preferences persist, enabling reminders requests actual platform permission',
    () async {
      final p = await settings.read();
      final off = WorkspaceSettingsChange(
        operationId: 'off',
        expectedVersion: p.version,
        desired: p.copyWith(
          theme: WorkspaceTheme.dark,
          notifications: false,
          requestMinutes: 30,
        ),
      );
      await settings.change(off);
      native.availability = const DesktopAvailability(
        tray: true,
        notifications: NotificationAvailability.notEnabled,
      );
      runtime.availability = native.availability;
      final latest = await settings.read();
      await settings.change(
        WorkspaceSettingsChange(
          operationId: 'on',
          expectedVersion: latest.version,
          desired: latest.copyWith(notifications: true),
        ),
      );
      expect(native.permissionRequests, 1);
      expect(changes, 2);
      await close();
      await open();
      final reopened = await settings.read();
      expect(reopened.theme, WorkspaceTheme.dark);
      expect(reopened.requestMinutes, 30);
      expect(reopened.notifications, isTrue);
      expect((await settings.receipt('off'))!.commandDigest, off.digest);
      expect((await settings.change(off)).commandDigest, off.digest);
      expect((await settings.read()).notifications, isTrue);
    },
  );
  test(
    'real window hide/show and maintenance have reconciliable original outcomes',
    () async {
      final hide = await action(WorkspaceRuntimeAction.hideWindow);
      expect(hide.windowHidden, isTrue);
      expect(native.hidden, isTrue);
      expect(
        (await source.receipt(hide.operationId))!.commandDigest,
        hide.commandDigest,
      );
      await action(WorkspaceRuntimeAction.showWindow);
      expect(runtime.windowHidden, isFalse);
      expect(native.hidden, isFalse);
      await action(WorkspaceRuntimeAction.checkMaterials);
      await action(WorkspaceRuntimeAction.checkAttachments);
      final s = await source.status();
      expect(s.serviceAvailable, isTrue);
      expect(s.materials, isEmpty);
      expect(s.copies, isEmpty);
    },
  );
  test('new live session invalidates quit scope before any shutdown', () async {
    await source.status();
    final preview = await source.previewQuit();
    service.agent.openSession('合成新会话');
    await expectLater(
      action(
        WorkspaceRuntimeAction.quit,
        token: preview.token,
        version: preview.version,
      ),
      throwsA(
        isA<WorkspaceFailure>().having((e) => e.code, 'code', 'conflict'),
      ),
    );
    expect(runtime.stopped, isFalse);
    expect(native.terminated, isFalse);
    await source.status();
    final fresh = await source.previewQuit();
    final receipt = await action(
      WorkspaceRuntimeAction.quit,
      token: fresh.token,
      version: fresh.version,
    );
    expect(receipt.phase, WorkspaceRuntimePhase.stopped);
    expect(native.terminated, isTrue);
    expect(receipt.quitScope!.sessions, 1);
  });
  test(
    'saved close preference controls native close after independent reopen',
    () async {
      final p = await settings.read();
      await settings.change(
        WorkspaceSettingsChange(
          operationId: 'close-pref',
          expectedVersion: p.version,
          desired: p.copyWith(background: false),
        ),
      );
      await close();
      await open();
      await runtime.handleEvent(DesktopEvent.closeWindow);
      expect(runtime.stopped, isTrue);
      expect(native.terminated, isTrue);
      expect(native.hidden, isFalse);
    },
  );
}
