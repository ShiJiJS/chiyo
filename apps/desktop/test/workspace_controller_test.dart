import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/workspace_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';

class _DeferredSource extends Fake implements WorkspaceSource {
  final requests = <Completer<WorkspaceSummary>>[];
  @override
  Future<WorkspaceSummary> loadSummary() {
    final request = Completer<WorkspaceSummary>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a late response cannot overwrite the latest refresh', () async {
    final source = _DeferredSource();
    final controller = WorkspaceController(source);
    addTearDown(controller.dispose);
    final first = controller.refresh();
    final second = controller.refresh();
    source.requests[1].complete(
      const WorkspaceSummary(records: 12, pending: 1, proposals: 0),
    );
    await second;
    source.requests[0].complete(
      const WorkspaceSummary(records: 99, pending: 9, proposals: 9),
    );
    await first;
    expect(controller.summary!.records, 12);
    expect(controller.load, WorkspaceLoad.ready);
  });

  test(
    'failure is visible, and retry replaces it with the source result',
    () async {
      final source = _DeferredSource();
      final controller = WorkspaceController(source);
      addTearDown(controller.dispose);
      final failing = controller.refresh();
      source.requests.single.completeError(
        const WorkspaceFailure('offline', '连接暂时中断。'),
      );
      await failing;
      expect(controller.load, WorkspaceLoad.error);
      expect(controller.failure!.code, 'offline');
      expect(controller.summary, isNull);
      final retry = controller.refresh();
      source.requests.last.complete(const WorkspaceSummary.empty());
      await retry;
      expect(controller.load, WorkspaceLoad.empty);
      expect(controller.failure, isNull);
    },
  );

  test(
    'closing while a read is pending produces no post-dispose notification',
    () async {
      final source = _DeferredSource();
      final controller = WorkspaceController(source);
      var notifications = 0;
      controller.addListener(() => notifications++);
      final pending = controller.refresh();
      controller.dispose();
      source.requests.single.completeError(StateError('late failure'));
      await pending;
      expect(notifications, 1);
    },
  );

  test('return preserves the prior page and stable selected identity', () {
    final controller = WorkspaceController(_DeferredSource());
    addTearDown(controller.dispose);
    controller.navigate(WorkspacePage.library, objectId: 'server-jp');
    controller.navigate(
      WorkspacePage.history,
      objectId: 'grant-4',
      remember: true,
    );
    controller.setBrightness(Brightness.dark);
    controller.goBack();
    expect(controller.location.page, WorkspacePage.library);
    expect(controller.location.objectId, 'server-jp');
    expect(controller.brightness, Brightness.dark);
    expect(controller.canGoBack, isFalse);
  });

  test(
    'sample waiting is deterministic, cancelled on reset, and isolated',
    () async {
      final first = SampleWorkspaceSource();
      final second = SampleWorkspaceSource();
      final controller = WorkspaceController(first);
      addTearDown(controller.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      first.setScenario(SampleWorkspaceScenario.waiting);
      final pending = controller.refresh();
      expect(controller.load, WorkspaceLoad.loading);
      first.reset();
      await controller.refresh();
      await pending;
      expect(controller.load, WorkspaceLoad.ready);
      second.setScenario(SampleWorkspaceScenario.empty);
      expect((await second.loadSummary()).isEmpty, isTrue);
      expect(
        controller.summary!.records,
        SampleWorkspaceSource.initial.records,
      );
    },
  );
}
