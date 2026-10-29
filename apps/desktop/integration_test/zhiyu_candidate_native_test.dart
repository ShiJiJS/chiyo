import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/grant_history_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/settings_controller.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'support/native_frame_recording.dart';
import 'support/native_runtime.dart';

/// One bounded candidate walk-through. Deeper version/viewport coverage reuses
/// zhiyu_library_native_test on the same unchanged product source.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('fixed Mac candidate continuously connects U01 through U07', (
    t,
  ) async {
    if (!Platform.isMacOS) throw StateError('This candidate requires macOS.');
    await loadDesktopFonts();
    final desktop = MacPreviewDesktop();
    final native = await desktop.initialize();
    final directory = (await MacPreviewDesktop.channel.invokeMethod<String>(
      'createEvidenceDirectory',
    ))!;
    final runtime = recordNativeRuntime(binding, directory);
    // ignore: avoid_print
    print('ZHIYU_NATIVE_EVIDENCE=$directory');
    final root = Directory(directory), boundary = GlobalKey();
    final recording = NativeFrameRecording(boundary, root, '', '');
    addTearDown(recording.dispose);
    final checks = <String>[];
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: PreviewWorkspace(desktop: desktop),
      ),
    );
    await t.pumpAndSettle();
    await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
      'width': 1440.0,
      'height': 900.0,
    });
    await t.pumpAndSettle();
    final library = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
    final source = library.source as SampleWorkspaceSource;
    Finder key(String value) => find.byKey(ValueKey(value));
    Future<void> tap(Finder target) async {
      await t.ensureVisible(target);
      await t.pumpAndSettle();
      await t.tap(target);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }

    Future<void> press(String value) => tap(key(value));
    Future<void> enter(String value, String text) async {
      await t.ensureVisible(key(value));
      await t.enterText(key(value), text);
      await t.pumpAndSettle();
    }

    Future<void> stage(String name) async {
      checks.add(name);
      await recording.saveStill(name);
    }

    await press('preview-guide');
    await press('preview-theme-dark');
    await press('preview-guide');
    await press('preview-theme-light');
    await stage('u01-theme-roundtrip');

    await press('library-directory-all');
    await enter('library-search', 'Azure');
    expect(library.results!.items.any((r) => r.ref.id == 'azure'), true);
    await press('library-record-information:azure');
    await press('library-relation-information:aliyun');
    await press('library-back');
    expect(library.selection?.id, 'azure');
    source.nextSaveFailure = const WorkspaceFailure('offline', '候选保存失败，草稿保留');
    await tap(find.text('编辑信息'));
    await enter('library-edit-description', 'Mac 候选的虚构描述');
    await press('library-edit-save');
    expect(find.text('候选保存失败，草稿保留'), findsOneWidget);
    await press('library-edit-save');
    expect(library.detail!.record.description, 'Mac 候选的虚构描述');
    await stage('u02-find-related-return-save-retry');

    await enter('library-search', '服务端开发简历');
    await press('library-record-information:resume');
    await press('library-file-versions-file');
    await press('library-file-version-1');
    await press('library-file-restore');
    expect(find.text('恢复来源 · 历史 v1'), findsOneWidget);
    await tap(find.text('取消').last);
    await tap(find.text('关闭').last);
    await stage('u03-file-version-confirm-cancel');

    await press('workspace-nav-settings');
    await press('settings-section-plugins');
    await press('plugin-install');
    await tap(find.textContaining('域名管理-1.0.0.json').last);
    await press('plugin-change-submit');
    expect((await source.plugins.load()).packages, hasLength(4));
    await press('plugin-create');
    await enter('library-edit-name', 'Mac 候选域名');
    await enter('library-edit-domain', 'candidate.example');
    await press('library-edit-save');
    final identity = library.detail!.fieldIds['domain'];
    await press('library-record-actions');
    await tap(find.text('采用资料模板'));
    await press('adoption-target-local.domain/domain');
    await press('adoption-source-domain');
    await tap(find.text('域名 · text').last);
    await press('adoption-meaning-domain');
    await press('adoption-preview');
    await press('adoption-apply');
    expect(library.detail!.fieldIds['domain'], identity);
    expect(library.detail!.values['domain'], 'candidate.example');
    await stage('u04-plugin-preview-install-adopt');

    await recording.start();
    await press('workspace-nav-approvals');
    final approval = t
        .widget<ApprovalsPage>(find.byType(ApprovalsPage))
        .controller;
    if (approval.needsReview) await press('approval-review-current');
    final host = approval.detail!.scopes.firstWhere(
      (s) => s.fieldKey == 'host',
    );
    for (final scope in approval.detail!.scopes.where(
      (s) => s.requested && s.id != host.id,
    )) {
      await press('approval-scope-${scope.id}');
    }
    await press('approval-approve');
    expect((await source.approvals.read('server')).approved, {host.id});
    await press('workspace-nav-history');
    final history = t
        .widget<GrantHistoryPage>(find.byType(GrantHistoryPage))
        .controller;
    await history.open('request:server');
    await t.pumpAndSettle();
    expect(history.detail!.scopes.single.id, host.id);
    await stage('u05-approval-result-in-shared-history');

    await press('workspace-nav-proposals');
    final proposals = t
        .widget<ProposalsPage>(find.byType(ProposalsPage))
        .controller;
    await press('proposal-item-status');
    if (proposals.needsReview) await press('proposal-review-current');
    await press('proposal-confirm');
    expect(proposals.detail!.summary.status, WorkspaceProposalStatus.completed);
    final created = proposals.detail!.targets.single.record;
    await press('proposal-current-${created.key}');
    expect(library.detail!.record.ref, created);
    await press('workspace-back');
    expect(proposals.selection, 'import');
    await stage('u06-proposal-result-current-return');
    await recording.stop('native-controls');

    await press('workspace-nav-settings');
    await press('settings-section-appearance');
    source.nextSaveFailure = const WorkspaceFailure('disk_full', '候选设置失败，选择保留');
    await press('settings-theme-dark');
    final settings = t
        .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
        .controller;
    expect(settings.draft!.theme, WorkspaceTheme.dark);
    expect(settings.writeFailure!.code, 'disk_full');
    await press('settings-save');
    expect((await source.settings.read()).theme, WorkspaceTheme.dark);
    for (final section in WorkspaceSettingsSection.values) {
      final target = key('settings-section-${section.name}');
      if (target.evaluate().isEmpty) {
        await t.scrollUntilVisible(
          target,
          250,
          scrollable: find
              .descendant(
                of: key('settings-sidebar-scroll'),
                matching: find.byType(Scrollable),
              )
              .first,
        );
      }
      await tap(target);
      expect(settings.section, section);
    }
    await stage('u07-settings-failure-retry-eight-sections');
    for (final destination in [
      'library',
      'approvals',
      'proposals',
      'history',
      'settings',
    ]) {
      await press('workspace-nav-$destination');
    }
    expect(settings.section, WorkspaceSettingsSection.agents);
    await stage('all-primary-destinations-return');
    await File('$directory/native-checks.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'runtime': runtime,
        'nativeIsolationChecked': true,
        'nativePreview': native,
        'checks': checks,
        'status': 'passed',
        'databaseOpened': false,
        'inputScope':
            'Native Flutter rendering and Widget input; not actual OS keyboard/IME',
        'reusedCurrentLibraryChecks':
            'r5-library-live: credential materials and complete version/viewport coverage',
      }),
    );
    await t.pumpWidget(const SizedBox());
    desktop.dispose();
  });
}
