import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

// Keep the binding's existing real-IO/fake-frame clocks. The policy guard
// normalizes paths without calling File factories, which would recurse.
final class _PreviewFiles extends IOOverrides {
  _PreviewFiles(this.root);
  final String root;
  final files = <String>[], directories = <String>[], rejected = <String>[];
  bool permitted(String path) {
    final normalized = Uri.file(
      path.startsWith('/') ? path : '$root/$path',
    ).normalizePath().toFilePath();
    return normalized.startsWith('/System/Library/Fonts/') ||
        normalized.startsWith(
          '/System/Library/AssetsV2/com_apple_MobileAsset_Font8/',
        ) ||
        normalized == '/System/Library/AssetsV2/com_apple_MobileAsset_Font8' ||
        normalized.startsWith('$root/assets/zhiyu_files/') ||
        normalized.startsWith('$root/build/unit_test_assets/') ||
        normalized.startsWith(
          '$root/test/',
        ); // Failure source diagnostics only.
  }

  void check(String path) {
    if (!permitted(path)) {
      rejected.add(path);
      throw StateError('Unexpected filesystem access');
    }
  }

  @override
  File createFile(String path) {
    check(path);
    files.add(path);
    return super.createFile(path);
  }

  @override
  Directory createDirectory(String path) {
    check(path);
    directories.add(path);
    return super.createDirectory(path);
  }
}

final class _PreviewNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('Network is outside UI preview');
  }
}

void main() {
  testWidgets(
    'Mac preview composition, plugins, adoption and legacy conversion avoid production channels, network and personal paths',
    (t) async {
      final previousIo = IOOverrides.current,
          previousHttp = HttpOverrides.current;
      final filesystem = _PreviewFiles(Directory.current.absolute.path),
          network = _PreviewNetwork();
      IOOverrides.global = filesystem;
      HttpOverrides.global = network;
      addTearDown(() {
        IOOverrides.global = previousIo;
        HttpOverrides.global = previousHttp;
      });
      final forbidden = <String>[], calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channels = [
        'agent_info_manage/database_key',
        'agent_info_manage/backup_files',
        'agent_info_manage/desktop',
        'agent_info_manage/tool_directories',
        'agent_info_manage/focused_fill',
        'agent_info_manage/secret_editor',
      ];
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          forbidden.add('$name/${call.method}');
          throw StateError('Production capability requested');
        });
      }
      messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'initialize') {
          return {
            'isolated': true,
            'productionServices': false,
            'savedDirectories': false,
            'title': MacPreviewDesktop.windowTitle,
          };
        }
        if (call.method == 'setNavigationEnabled') return null;
        forbidden.add('preview/${call.method}');
        throw StateError('Unexpected native action');
      });
      addTearDown(() {
        for (final name in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(name), null);
        }
        messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, null);
      });
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.runAsync(loadDesktopFonts);
      final desktop = MacPreviewDesktop();
      await desktop.initialize();
      await t.pumpWidget(PreviewWorkspace(desktop: desktop));
      await t.pumpAndSettle();
      final controller = t
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller;
      final source = controller.source;
      expect((await source.loadSummary()).records, 31);
      for (final name in ['个人档案', '域名与 HTTPS', '服务端开发简历', 'Azure SSH 私钥']) {
        await t.tap(find.byKey(const ValueKey('library-directory-all')));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const ValueKey('library-search')), name);
        await t.pumpAndSettle();
        final result = controller.results!.items.singleWhere(
          (r) => r.name == name,
        );
        await t.tap(find.byKey(ValueKey('library-record-${result.ref.key}')));
        await t.pumpAndSettle();
        expect(controller.detail?.record.ref, result.ref);
      }
      await t.tap(find.text('编辑信息'));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('credential-edit-note')),
        '隔离检查的合成备注',
      );
      await t.tap(find.byKey(const ValueKey('credential-edit-save')));
      await t.pumpAndSettle();
      const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
      expect((await source.credentials.read(ssh)).privateNote, '隔离检查的合成备注');
      expect((await source.readDetail(ssh)).values, isEmpty);
      await t.tap(find.byKey(const ValueKey('workspace-nav-settings')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('plugin-tab-settings')));
      await t.tap(find.byKey(const ValueKey('plugin-tab-settings')));
      await t.pumpAndSettle();
      await t.ensureVisible(
        find.byKey(const ValueKey('host-open-information:azure')),
      );
      await t.tap(find.byKey(const ValueKey('host-open-information:azure')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('host-revoke')));
      await t.tap(find.byKey(const ValueKey('host-revoke')));
      await t.pumpAndSettle();
      expect(
        (await source.hosts.read(
          const WorkspaceHostTarget.record(
            WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
          ),
        )).state,
        WorkspaceHostState.revoked,
      );
      await t.tap(find.byKey(const ValueKey('host-close')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('plugin-install')));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('域名管理-1.0.0.json').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('plugin-change-submit')));
      await t.pumpAndSettle();
      expect((await source.plugins.load()).packages, hasLength(4));
      await t.tap(find.byKey(const ValueKey('plugin-create')));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('library-edit-name')),
        '隔离检查域名',
      );
      final domain = find.byKey(const ValueKey('library-edit-domain'));
      await t.ensureVisible(domain);
      await t.enterText(domain, 'isolation.example');
      await t.tap(find.byKey(const ValueKey('library-edit-save')));
      await t.pumpAndSettle();
      expect(controller.detail!.record.type.id, 'local.domain/domain');
      expect(controller.detail!.values['domain'], 'isolation.example');
      final domainIdentity = controller.detail!.fieldIds['domain'];
      await t.tap(find.byKey(const ValueKey('library-record-actions')));
      await t.pumpAndSettle();
      await t.tap(find.text('采用资料模板'));
      await t.pumpAndSettle();
      await t.ensureVisible(
        find.byKey(const ValueKey('adoption-target-local.domain/domain')),
      );
      await t.tap(
        find.byKey(const ValueKey('adoption-target-local.domain/domain')),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('adoption-source-domain')));
      await t.pumpAndSettle();
      await t.tap(find.text('域名 · text').last);
      await t.pumpAndSettle();
      await t.ensureVisible(
        find.byKey(const ValueKey('adoption-meaning-domain')),
      );
      await t.tap(find.byKey(const ValueKey('adoption-meaning-domain')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('adoption-preview')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('adoption-apply')));
      await t.pumpAndSettle();
      expect(controller.detail!.fieldIds['domain'], domainIdentity);
      expect(controller.detail!.values['domain'], 'isolation.example');
      expect((await source.loadSummary()).records, 32);
      await t.tap(find.text('编辑信息'));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('library-edit-name')),
        '隔离检查草稿',
      );
      final beforeConflict = await source.readDetail(
        controller.detail!.record.ref,
      );
      await source.saveRecord(
        WorkspaceEdit(
          operationId: 'guard-concurrent-edit',
          expectedVersion: beforeConflict.version,
          record: beforeConflict.record.copyWith(name: '隔离检查当前版本'),
          values: const {},
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('library-edit-save')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('library-edit-review-current')));
      await t.pumpAndSettle();
      expect(find.text('核对当前版本与草稿'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('library-edit-review-keep')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('library-edit-save')));
      await t.pumpAndSettle();
      expect(controller.detail!.record.name, '隔离检查草稿');
      expect(controller.detail!.fieldIds['domain'], domainIdentity);
      await t.tap(find.byKey(const ValueKey('workspace-nav-settings')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('legacy-menu')));
      await t.pumpAndSettle();
      final legacy = await source.legacyTemplates.read('legacy-resource');
      final fields = legacy.definition['fields'] as List;
      await t.ensureVisible(find.byKey(const ValueKey('legacy-create')));
      await t.tap(find.byKey(const ValueKey('legacy-create')));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('library-edit-name')),
        '隔离检查旧版录入',
      );
      for (final f in fields) {
        final input = find.byKey(ValueKey('library-edit-${f['key']}'));
        await t.ensureVisible(input);
        await t.enterText(input, '虚构的旧版字段内容');
      }
      await t.tap(find.byKey(const ValueKey('library-edit-save')));
      await t.pumpAndSettle();
      expect(controller.detail!.record.type.id, 'generic');
      expect(controller.detail!.definition, legacy.definition);
      expect(
        controller.detail!.fieldIds.values.toSet().intersection(
          legacy.fields.map((f) => f.id).toSet(),
        ),
        isEmpty,
      );
      final legacyRecord = controller.detail!;
      await t.tap(find.byKey(const ValueKey('workspace-nav-settings')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('legacy-convert')));
      await t.tap(find.byKey(const ValueKey('legacy-convert')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('plugin-change-submit')));
      await t.pumpAndSettle();
      expect((await source.plugins.load()).packages, hasLength(5));
      expect(
        (await source.readDetail(legacyRecord.record.ref)).definition,
        legacyRecord.definition,
      );
      await t.tap(find.byKey(const ValueKey('plugin-authoring-guide')));
      await t.pumpAndSettle();
      expect(find.textContaining('生成后调用只读校验'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('plugin-authoring-close')));
      await t.pumpAndSettle();
      expect((await source.loadSummary()).records, 33);
      final historyBefore = await source.credentials.history(ssh);
      await t.tap(find.byKey(const ValueKey('workspace-nav-approvals')));
      await t.pumpAndSettle();
      final approval = t
          .widget<ApprovalsPage>(find.byType(ApprovalsPage))
          .controller;
      expect(approval.selection, 'server');
      // Earlier owner edits changed the reviewed versions; acknowledge them
      // through the same explicit control before narrowing this request.
      expect(approval.needsReview, true);
      final review = find.byKey(const ValueKey('approval-review-current'));
      await t.ensureVisible(review);
      await t.pumpAndSettle();
      await t.tap(review);
      await t.pumpAndSettle();
      expect(approval.needsReview, false);
      final host = approval.detail!.scopes.firstWhere(
        (x) => x.fieldKey == 'host',
      );
      for (final scope in approval.detail!.scopes.where(
        (x) => x.requested && x.id != host.id,
      )) {
        final choice = find.byKey(ValueKey('approval-scope-${scope.id}'));
        await t.ensureVisible(choice);
        await t.pumpAndSettle();
        await t.tap(choice);
        await t.pumpAndSettle();
      }
      final approve = find.byKey(const ValueKey('approval-approve'));
      await t.ensureVisible(approve);
      await t.pumpAndSettle();
      await t.tap(approve);
      await t.pumpAndSettle();
      expect((await source.approvals.read('server')).approved, {host.id});
      expect((await source.loadSummary()).pending, 4);
      expect(
        (await source.credentials.history(ssh)).length,
        historyBefore.length,
      );
      expect((await source.credentials.read(ssh)).privateNote, '隔离检查的合成备注');
      final tokenRequest = find.byKey(const ValueKey('approval-select-token'));
      await t.ensureVisible(tokenRequest);
      await t.pumpAndSettle();
      await t.tap(tokenRequest);
      await t.pumpAndSettle();
      await t.ensureVisible(approve);
      await t.pumpAndSettle();
      await t.tap(approve);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('preview-guide')));
      await t.pumpAndSettle();
      final demoUses = find.byKey(
        const ValueKey('preview-approval-executions'),
      );
      await t.ensureVisible(demoUses);
      await t.tap(demoUses);
      await t.pumpAndSettle();
      final uses = (await source.approvals.read('token')).executions;
      expect(uses, hasLength(3));
      final lookup = find.byKey(
        ValueKey('approval-operation-refresh-${uses.last.operationId}'),
      );
      await t.ensureVisible(lookup);
      await t.pumpAndSettle();
      await t.tap(lookup);
      await t.pumpAndSettle();
      expect(
        (await source.approvals.execution(
          'token',
          uses.last.operationId,
        )).state,
        WorkspaceExecutionState.unknown,
      );
      await t.tap(find.byKey(const ValueKey('preview-guide')));
      await t.pumpAndSettle();
      await t.tap(find.text('重置预览资料'));
      await t.pumpAndSettle();
      expect((await source.credentials.read(ssh)).privateNote, isEmpty);
      expect((await source.loadSummary()).records, 31);
      expect((await source.loadSummary()).pending, 5);
      expect((await source.approvals.read('token')).executions, isEmpty);
      expect(
        (await source.approvals.read('server')).request.state,
        WorkspaceApprovalState.pending,
      );
      expect(
        (await source.credentials.requests(ref: ssh)).single.state,
        WorkspaceCredentialRequestState.pending,
      );
      expect((await source.plugins.load()).packages, hasLength(3));
      expect((await source.legacyTemplates.read('legacy-resource')).version, 1);
      expect(
        (await source.hosts.read(
          const WorkspaceHostTarget.record(
            WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
          ),
        )).state,
        WorkspaceHostState.trusted,
      );
      expect(forbidden, isEmpty);
      expect(network.calls, 0);
      expect(filesystem.rejected, isEmpty);
      expect(filesystem.files, contains('/System/Library/Fonts/SFNS.ttf'));
      expect(calls.first.method, 'initialize');
      expect(
        calls.every(
          (c) => ['initialize', 'setNavigationEnabled'].contains(c.method),
        ),
        isTrue,
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
