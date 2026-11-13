import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/workspace/owner_workspace_runtime.dart';
import 'package:info_desktop/workspace/runtime_controller.dart';
import 'package:info_desktop/workspace/runtime_page.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_workspace/owner_runtime_observation.dart';
import 'package:info_workspace/runtime_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import '../../../packages/info_core/test_support/operation_history.dart';
import 'support/desktop_platform_fixture.dart';

class _Fixture {
  DateTime now = DateTime.utc(2026, 11, 14);
  final repo = core.MemoryInformationRepository();
  late final service = core.InformationService(
    repository: repo,
    clock: () => now,
  );
  late final records = OperationHistoryFixture(service, repo, now);
  late final runtime = DesktopRuntime(
    service: service,
    platform: NativeDesktopFixture(),
    closeServer: () async {},
    closeRepository: () async {},
  );
  late final source = OwnerWorkspaceRuntime(runtime: runtime, changed: () {});
  static final job = 'macos:AgentInfoRuntime-${'R' * 32}';
  Future<core.CredentialProgramClaim> open({bool file = false}) async {
    await records.open(program: true, programFile: file);
    final launch = records.businessPlan;
    return service.agent.beginCredentialProgramOperation(
      records.session,
      records.request.deviceId,
      records.request.id,
      launch,
      core.DeviceCredentialLaunch.fromPrivateJson({
        'version': 1,
        'planHash': launch.planHash,
        'executable': records.plan.identity!.toJson(),
        'cwd': records.plan.cwd,
      }),
      job,
      operationId: 'runtime-program',
    );
  }

  Future<void> close() async {
    await runtime.stop();
    runtime.dispose();
  }
}

void main() {
  test(
    'runtime sees non-file programs, has stable reads and rejects private or archived program wire',
    () async {
      final f = _Fixture();
      addTearDown(f.close);
      final claim = await f.open();
      final observed = OwnerRuntimeObservation(f.service.owner);
      final first = await observed.read();
      expect(first.programs, hasLength(1));
      expect(first.unconfirmedProcesses, 1);
      expect(first.grants, 1);
      expect(first.programs.single.holdsMaterial, isFalse);
      f.now = f.now.add(const Duration(seconds: 1));
      expect((await observed.read()).revision, first.revision);
      final wire = serverRuntimeToJson(first);
      expect(wire['wireVersion'], 2);
      expect(
        serverRuntimeFromJson(wire).programs.single.operation.state,
        'preparing',
      );
      for (final private in [
        'NEVER-PAGE-THIS-MATERIAL',
        'executionCapability',
        'workerPid',
        'materialLease',
      ]) {
        expect(jsonEncode(wire), isNot(contains(private)));
      }
      for (final mutation in [
        'path',
        'archive',
        'count',
        'duplicate',
        'version',
      ]) {
        final bad = jsonDecode(jsonEncode(wire)) as Map<String, dynamic>;
        final programs = bad['programs'] as List;
        switch (mutation) {
          case 'path':
            (programs.single as Map)['path'] = '/do-not-inspect';
          case 'archive':
            ((programs.single as Map)['operation'] as Map)['fromBackup'] = true;
          case 'count':
            bad['unconfirmedProcesses'] = 0;
          case 'duplicate':
            programs.add(programs.single);
          case 'version':
            bad['wireVersion'] = 3;
        }
        expect(() => serverRuntimeFromJson(bad), throwsFormatException);
      }
      f.now = f.now.add(const Duration(seconds: 31));
      final unknown = await observed.read();
      expect(unknown.programs.single.operation.state, 'unknown');
      expect(unknown.revision, isNot(first.revision));
      await f.service.agent.reportCredentialProgramExecution(
        f.records.request.deviceId,
        core.CredentialExecutionReport(
          executionId: claim.operation.id,
          executionCapability: claim.material!.executionCapability,
          state: 'prepare_failed',
          errorCode: 'material_prepare_failed',
          finishedAt: f.now,
          jobName: _Fixture.job,
        ),
      );
      final done = await observed.read();
      expect(done.programs, isEmpty);
      expect(done.unconfirmedProcesses, 0);
      expect(serverRuntimeToJson(done)['wireVersion'], 1);
    },
  );

  test(
    'root exit does not clear descendant/material reports, local maintenance cannot clear device files and quit counts include batch grants',
    () async {
      final f = _Fixture();
      addTearDown(f.close);
      final claim = await f.open(file: true);
      final cap = claim.material!.executionCapability, id = claim.operation.id;
      await f.service.agent.registerCredentialProgramMaterials(
        f.records.request.deviceId,
        id,
        cap,
        core.CredentialMaterialLease('/foreign-device/private', 'folder-id', {
          'credential-b1.bin': 'file-id',
        }),
      );
      await f.service.agent.registerCredentialProgramWorker(
        f.records.request.deviceId,
        id,
        cap,
        123,
        'foreign-worker-id',
      );
      await f.service.agent.reportCredentialProgramExecution(
        f.records.request.deviceId,
        core.CredentialExecutionReport(
          executionId: id,
          executionCapability: cap,
          state: 'running',
          pid: 456,
          processCreatedAt: 'foreign-target-id',
          startedAt: f.now,
          jobName: _Fixture.job,
        ),
      );
      final started = f.now;
      f.now = f.now.add(const Duration(seconds: 1));
      await f.service.agent.reportCredentialProgramExecution(
        f.records.request.deviceId,
        core.CredentialExecutionReport(
          executionId: id,
          executionCapability: cap,
          state: 'exited',
          pid: 456,
          processCreatedAt: 'foreign-target-id',
          startedAt: started,
          finishedAt: f.now,
          exitCode: 0,
          jobName: _Fixture.job,
        ),
      );
      final status = await f.source.status();
      expect(status.programs.single.operation.state, 'exited');
      expect(status.programs.single.processUnconfirmed, isTrue);
      expect(status.pendingMaterialKeys, hasLength(1));
      final preview = await f.source.previewQuit();
      expect(preview.materials, 1);
      expect(preview.unconfirmedProcesses, 1);
      expect(preview.grants, 1);
      final result = await f.source.change(
        WorkspaceRuntimeChange(
          operationId: 'read-device-reports',
          action: WorkspaceRuntimeAction.checkMaterials,
          expectedVersion: status.version,
        ),
      );
      expect(result.checked, 1);
      expect(result.released, 0);
      expect(result.retained, 1);
      expect(
        f.repo.credentialProgramOperations.single.progress.cleanupState,
        'pending',
      );
      await f.service.agent.acknowledgeCredentialProgramCleanup(
        f.records.request.deviceId,
        id,
        cap,
        treeEnded: true,
      );
      final done = await f.source.status();
      expect(done.programs, isEmpty);
      expect(done.unconfirmedProcesses, 0);
      expect(done.pendingMaterialKeys, isEmpty);
      // A fresh batch changes the quit scope even before it has an execution.
      final old = await f.source.previewQuit();
      await f.service.agent.requestCredentialBatch(
        f.records.session,
        f.records.request.deviceId,
        f.records.input,
        operationId: 'new-pending-in-same-chat',
      );
      expect((await f.source.previewQuit()).pendingRequests, 1);
      expect((await f.source.status()).version, greaterThan(old.version));
      await expectLater(
        f.source.change(
          WorkspaceRuntimeChange(
            operationId: 'stale-quit',
            action: WorkspaceRuntimeAction.quit,
            expectedVersion: old.version,
            quitToken: old.token,
          ),
        ),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(f.runtime.stopped, isFalse);
    },
  );

  testWidgets(
    'program report is visible in normal maintenance and opens its original request',
    (t) async {
      final f = _Fixture();
      await t.runAsync(() async {
        await f.open();
        // Construct the real runtime in the same event loop as its teardown.
        // Its readiness/maintenance futures must not belong to the fake UI clock.
        f.source;
      });
      final sample = SampleWorkspaceSource();
      final controller = WorkspaceRuntimeController(
        f.source,
        const Stream.empty(),
      );
      final preferences = WorkspaceSettingsController(
        sample.settings,
        const Stream.empty(),
        onTheme: (_) {},
      );
      final opened = <String>[];
      addTearDown(() async {
        controller.dispose();
        preferences.dispose();
        sample.dispose();
        await t.runAsync(f.close);
      });
      await t.runAsync(() async {
        await controller.load();
        await preferences.load();
      });
      t.view.physicalSize = const Size(1300, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: WorkspaceRuntimePage(
              controller: controller,
              preferences: preferences,
              onRequest: opened.add,
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('runtime-maintenance')));
      await t.pumpAndSettle();
      final button = find.byKey(const ValueKey('runtime-materials'));
      await t.ensureVisible(button);
      await t.tap(button);
      await t.pumpAndSettle();
      expect(find.text('程序 · business-tool'), findsOneWidget);
      expect(find.textContaining('进程尚未确认结束'), findsOneWidget);
      final link = find.byKey(
        ValueKey(
          'runtime-program-request-${f.records.request.id}-runtime-program',
        ),
      );
      await t.ensureVisible(link);
      await t.tap(link);
      await t.pumpAndSettle();
      expect(opened, [f.records.request.id]);
    },
  );
}
