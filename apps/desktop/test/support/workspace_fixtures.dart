// Fixture preparation lives in tests, not in a user-facing application mode.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/zhiyu_app.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/grant_history_page.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/sample_workspace_stress_fixture.dart';
import 'package:info_desktop/workspace/workspace_inputs.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'sample_input_choices.dart';

WorkspaceInputs fixtureInputs(BuildContext context) {
  final s =
      context.findAncestorWidgetOfExactType<ZhiyuApp>()!.controller.source
          as SampleWorkspaceSource;
  return WorkspaceInputs(
    file: () => showWorkspaceFileChoices(context, s.fileChoices),
    credential: (form) => showWorkspaceCredentialChoices(
      context,
      s.credentials.candidates,
      form: form,
    ),
    plugin: () =>
        showPluginChoices(context, s.pluginChoices, s.plugins.releaseCandidate),
    hostFile: () =>
        showHostFileChoices(context, s.hostFileChoices, s.hosts.releaseImport),
    backup: (kind) =>
        showWorkspaceBackupChoices(context, () => s.backups.choices(kind)),
  );
}

SampleWorkspaceSource fixtureSource(WidgetTester t) =>
    t.widget<ZhiyuApp>(find.byType(ZhiyuApp)).controller.source
        as SampleWorkspaceSource;

void _refresh(WidgetTester t) {
  unawaited(t.widget<ZhiyuApp>(find.byType(ZhiyuApp)).controller.refresh());
  for (final e in find.byType(LibraryPage).evaluate()) {
    final m = (e.widget as LibraryPage).controller;
    unawaited(m.load(m.query));
  }
  for (final e in find.byType(ApprovalsPage).evaluate()) {
    unawaited((e.widget as ApprovalsPage).controller.load());
  }
  for (final e in find.byType(ProposalsPage).evaluate()) {
    unawaited((e.widget as ProposalsPage).controller.load());
  }
  for (final e in find.byType(GrantHistoryPage).evaluate()) {
    unawaited((e.widget as GrantHistoryPage).controller.load());
  }
  for (final e in find.byType(WorkspaceSettingsPage).evaluate()) {
    final w = e.widget as WorkspaceSettingsPage;
    unawaited(w.controller.load());
    unawaited(w.plugins.load());
    unawaited(w.classifications.load());
    unawaited(w.backups.load());
    unawaited(w.runtime.load());
    unawaited(w.agents.load());
  }
}

Future<void> _settings(WidgetTester t, WorkspaceSettingsSection section) async {
  final app = t.widget<ZhiyuApp>(find.byType(ZhiyuApp)).controller;
  app.navigate(WorkspacePage.settings);
  await t.pump();
  t
      .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
      .controller
      .select(section);
  await t.pump();
}

/// Adapts old scenario tests to direct fixture preparation. No widget, menu,
/// keyboard shortcut or runtime switch is introduced into the application.
Future<bool> prepareFixtureAction(WidgetTester t, Finder target) async {
  final key = RegExp(
    r'preview-[\w-]+',
  ).firstMatch(target.describeMatch(Plurality.zero))?.group(0);
  if (target.describeMatch(Plurality.zero).contains('重置预览资料')) {
    sReset(t);
    await t.pumpAndSettle();
    return true;
  }
  if (target.describeMatch(Plurality.zero).contains('下次保存失败')) {
    fixtureSource(t).nextSaveFailure = const WorkspaceFailure(
      'sample_save_failed',
      '保存失败，输入已保留，请重试。',
    );
    return true;
  }
  if (key == null) return false;
  if (key == 'preview-guide') return true;
  final s = fixtureSource(t);
  switch (key) {
    case 'preview-theme-light':
    case 'preview-theme-dark':
      final p = await s.settings.read();
      await s.settings.change(
        WorkspaceSettingsChange(
          operationId: workspaceOperationId(),
          expectedVersion: p.version,
          desired: p.copyWith(
            theme: key.endsWith('dark')
                ? WorkspaceTheme.dark
                : WorkspaceTheme.light,
          ),
        ),
      );
      final fixture = find.byKey(const ValueKey('foundation-controls'));
      if (fixture.evaluate().isNotEmpty) {
        Navigator.pop(t.element(fixture));
      }
    case 'preview-dataset-stress':
    case 'preview-dataset-reference':
      await runFixture(
        t,
        () => s.replaceFixture(
          key.endsWith('stress')
              ? buildWorkspaceStressFixture()
              : sampleWorkspaceJson,
        ),
      );
      _refresh(t);
      for (final e in find.byType(LibraryPage).evaluate()) {
        final m = (e.widget as LibraryPage).controller;
        await m.resetView();
        if (key.endsWith('stress')) await m.showAll();
      }
    case 'preview-backup-complete':
      await runFixture(t, s.prepareBackupExportFixture);
      await _settings(t, WorkspaceSettingsSection.backups);
    case 'preview-backup-recipient':
      await runFixture(t, s.prepareBackupRecipient);
      await _settings(t, WorkspaceSettingsSection.backups);
    case 'preview-runtime-maintenance':
      await runFixture(t, s.prepareRuntimeMaintenance);
      await _settings(t, WorkspaceSettingsSection.runtime);
    case 'preview-runtime-cleanup-ready':
      s.runtime.allowCleanup();
    case 'preview-runtime-saveFailed':
      s.runtime.nextQuitPhase = WorkspaceRuntimePhase.saveFailed;
      await _settings(t, WorkspaceSettingsSection.runtime);
    case 'preview-runtime-resume':
      s.runtime.resumePreview();
    case 'preview-agents-ready':
      await s.agents.setScenario(SampleAgentScenario.ready);
      await _settings(t, WorkspaceSettingsSection.agents);
    case 'preview-approval-executions':
      final m = t.widget<ApprovalsPage>(find.byType(ApprovalsPage)).controller;
      s.demonstrateApprovalExecutions(m.selection!);
    case 'preview-approval-execution-observe':
      final m = t.widget<ApprovalsPage>(find.byType(ApprovalsPage)).controller;
      s.publishApprovalExecutionObservation(m.selection!);
    case 'preview-approval-execution-failure':
      s.nextApprovalExecutionReadFailure = const WorkspaceFailure(
        'offline',
        '原操作暂时无法查询，原状态已保留。不要重跑。',
      );
    case 'preview-approval-expire':
      s.advanceApprovalClock(const Duration(hours: 9));
    case 'preview-approval-session-end':
      s.endApprovalSession('session-maintenance');
    case 'preview-organization-observe':
      s.publishOrganizationObservation();
    case 'preview-organization-legacy':
      await s.demonstrateLegacyOrganization();
    case 'preview-organization-applied':
    case 'preview-organization-unknown':
    case 'preview-organization-conflicted':
      await s.demonstrateOrganization(
        outcome: WorkspaceOrganizationOutcome.values.byName(
          key.substring('preview-organization-'.length),
        ),
      );
    case 'preview-proposal-unknown':
      s.loseNextProposalReply = true;
    case 'preview-proposal-deletion':
      s.setScenario(SampleWorkspaceScenario.ready);
      await s.demonstrateDeletionProposal();
    case 'preview-proposal-fields':
    case 'preview-proposal-batch-unknown':
      s.setScenario(SampleWorkspaceScenario.ready);
      await s.demonstrateFieldProposals();
      if (key.endsWith('unknown')) s.loseReplyForProposal('fields-server');
    case 'preview-proposal-conflict':
      s.setScenario(SampleWorkspaceScenario.ready);
      await s.demonstrateProposalConflict();
    case 'preview-credential-error':
      s.nextCredentialReadFailure = const WorkspaceFailure(
        'unavailable',
        '凭据资料读取失败，请重试。',
      );
    case 'preview-file-error':
      s.nextFilePreviewFailure = const WorkspaceFailure(
        'preview_unavailable',
        '文件预览失败，文件信息仍可查看。',
      );
    case 'preview-host-fingerprintChanged':
      s.setScenario(SampleWorkspaceScenario.ready);
      await s.demonstrateHost(SampleHostScenario.fingerprintChanged);
      await _settings(t, WorkspaceSettingsSection.plugins);
      t
          .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
          .plugins
          .showHostSettings(null);
    default:
      if (!key.startsWith('preview-scenario-')) return false;
      s.setScenario(
        SampleWorkspaceScenario.values.byName(
          key.substring('preview-scenario-'.length),
        ),
      );
      _refresh(t);
  }
  await t.pump();
  if (s.scenario != SampleWorkspaceScenario.waiting) {
    await settleFixture(t);
  }
  return true;
}

Future<WorkspaceCredentialUseRequest> submitAgentCredentialRequest(
  WidgetTester t,
  WorkspaceRecordRef ref,
  String purpose,
) async {
  final s = fixtureSource(t), detail = await s.credentials.read(ref);
  final receipt = await s.credentials.requestUse(
    WorkspaceCredentialUseDraft(
      operationId: workspaceOperationId(),
      ref: ref,
      expectedRecordVersion: detail.recordVersion,
      expectedMaterialVersion: detail.materialVersion,
      useGeneration: detail.useGeneration,
      purpose: purpose,
      sessionId: (await s.credentials.sessions()).first.id,
      receiverId: (await s.credentials.receivers(ref)).first.id,
      minutes: 15,
    ),
  );
  await t.pumpAndSettle();
  return (await s.credentials.requests(
    ref: ref,
  )).singleWhere((r) => r.id == receipt.requestId);
}

Future<void> fixtureTap(WidgetTester t, Finder target) async {
  if (!await prepareFixtureAction(t, target)) await t.tap(target);
}

void sReset(WidgetTester t) {
  fixtureSource(t).reset();
  for (final e in find.byType(ApprovalsPage).evaluate()) {
    (e.widget as ApprovalsPage).controller.resetView();
  }
  for (final e in find.byType(ProposalsPage).evaluate()) {
    (e.widget as ProposalsPage).controller.resetView();
  }
  for (final e in find.byType(GrantHistoryPage).evaluate()) {
    (e.widget as GrantHistoryPage).controller.resetView();
  }
  _refresh(t);
}

Future<void> settleFixture(WidgetTester t) async {
  for (var i = 0; i < 200; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await t.pump();
    var loading = false;
    for (final e in find.byType(LibraryPage).evaluate()) {
      loading |=
          (e.widget as LibraryPage).controller.loadState ==
          WorkspaceLoad.loading;
    }
    for (final e in find.byType(ApprovalsPage).evaluate()) {
      final m = (e.widget as ApprovalsPage).controller;
      loading |= m.loading || m.reading || m.busy;
    }
    for (final e in find.byType(WorkspaceSettingsPage).evaluate()) {
      final w = e.widget as WorkspaceSettingsPage;
      loading |=
          w.controller.loading ||
          w.backups.loading ||
          w.runtime.loading ||
          w.agents.loading ||
          w.plugins.loading;
    }
    if (!loading) {
      await t.pumpAndSettle();
      return;
    }
  }
  throw StateError('Fixture projections did not become ready.');
}

Future<void> runFixture(WidgetTester t, Future<void> Function() action) async {
  var done = false;
  Object? failure;
  unawaited(
    action().then(
      (_) {
        done = true;
      },
      onError: (Object error) {
        failure = error;
        done = true;
      },
    ),
  );
  for (var i = 0; i < 500; i++) {
    await t.pump();
    if (done) {
      if (failure != null) throw failure!;
      return;
    }
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
  }
  throw StateError('Fixture preparation did not complete.');
}
