import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/agents_controller.dart';
import 'package:info_desktop/workspace/agents_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  testWidgets('real session selector opens only owner-selected association', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final service = core.InformationService(
      repository: core.MemoryInformationRepository(),
    );
    final source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
    service.agent.openSession('first visible chat');
    service.agent.openSession('second visible chat');
    final target = service.owner.sessions.last;
    final m = WorkspaceAgentsController(source.agents, const Stream.empty());
    addTearDown(m.dispose);
    unawaited(m.load());
    for (var i = 0; i < 20 && m.loading; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(m.available, isTrue);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceAgentsPage(
            controller: m,
            onRequest: (_) => fail('empty session cannot navigate to request'),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(m.value!.session.state, WorkspaceAgentSessionState.unselected);
    final selector = find.byKey(const ValueKey('agents-session-select'));
    await t.ensureVisible(selector);
    await t.tap(selector);
    await t.pumpAndSettle();
    await t.tap(find.textContaining('second visible chat').last);
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(m.value!.session.id, target.id);
    await t.ensureVisible(find.byKey(const ValueKey('agents-session')));
    await t.tap(find.byKey(const ValueKey('agents-session')));
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(m.session!.session.id, target.id);
    expect(m.session!.requests, isEmpty);
    expect(t.takeException(), isNull);
    await t.tap(find.byKey(const ValueKey('agents-flow-close')));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pumpAndSettle();
    }

    final disposing = source.dispose();
    await settle();
    await disposing;
    final closing = service.close();
    await settle();
    await closing;
  });
}
