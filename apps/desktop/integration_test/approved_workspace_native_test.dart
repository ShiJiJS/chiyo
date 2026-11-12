import 'dart:io';
import 'dart:convert';
import 'package:info_remote/connection_profile.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_desktop/workspace/settings_page.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import '../test/support/desktop_platform_fixture.dart';
import '../test/support/online_ui_harness.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/connection_view.dart';
import 'package:info_desktop/onboarding/setup_configuration.dart';
import 'package:info_desktop/onboarding/setup_preview_adapter.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/proposal_directory.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/library_batch_recycle_dialog.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_workspace_proposals.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_core/info_core.dart' as core;
import '../test/support/workspace_fixtures.dart';
import 'support/native_semantics_lifetime.dart';

// Runs only through the isolated preview identity. Production storage and
// credential channels are not registered by that identity.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('approved workspace layout on a native Mac window', (t) async {
    final semantics = NativeSemanticsLifetime(t);
    expect(Platform.isMacOS, true);
    await loadDesktopFonts();
    final desktop = MacPreviewDesktop();
    await desktop.initialize();
    final output = (await MacPreviewDesktop.channel.invokeMethod<String>(
      'createEvidenceDirectory',
    ))!;
    // ignore: avoid_print
    print('APPROVED_UI_EVIDENCE=$output');
    final boundary = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: PreviewWorkspace(desktop: desktop, inputsBuilder: fixtureInputs),
      ),
    );
    await t.pumpAndSettle();
    Future<void> tap(Finder f) async {
      if (await prepareFixtureAction(t, f)) return;
      await t.ensureVisible(f);
      await t.tap(f);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }

    Future<void> capture(String name) async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    for (final width in [1440.0, 1000.0]) {
      await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
        'width': width,
        'height': 900.0,
      });
      for (var i = 0; i < 60; i++) {
        await t.pump(const Duration(milliseconds: 16));
        if (t.view.physicalSize.width / t.view.devicePixelRatio == width) break;
      }
      expect(t.view.physicalSize.width / t.view.devicePixelRatio, width);
      for (final dark in [false, true]) {
        await tap(find.byKey(const ValueKey('preview-guide')));
        await tap(
          find.byKey(ValueKey('preview-theme-${dark ? 'dark' : 'light'}')),
        );
        for (final page in [
          'library',
          'approvals',
          'proposals',
          'history',
          'settings',
        ]) {
          await tap(find.byKey(ValueKey('workspace-nav-$page')));
          expect(find.byKey(const ValueKey('workspace-back')), findsNothing);
          await capture('${width.toInt()}-${dark ? 'dark' : 'light'}-$page');
          if ((page == 'approvals' || page == 'proposals') &&
              find.byType(ProposalDirectoryLocation).evaluate().isNotEmpty) {
            await tap(
              find
                  .descendant(
                    of: find.byType(ProposalDirectoryLocation).first,
                    matching: find.byType(ExpansionTile),
                  )
                  .first,
            );
            await capture(
              '${width.toInt()}-${dark ? 'dark' : 'light'}-$page-directory',
            );
          }
          if (page == 'history') {
            await tap(find.byKey(const ValueKey('grant-filter-popup')));
            await capture(
              '${width.toInt()}-${dark ? 'dark' : 'light'}-history-filter-popup',
            );
            await tap(find.widgetWithText(ChoiceChip, '有效'));
            await tap(find.widgetWithText(ChoiceChip, '字段读取'));
            await tap(find.widgetWithText(ChoiceChip, '最近7天'));
            await tap(find.byKey(const ValueKey('grant-filters-apply')));
            await capture(
              '${width.toInt()}-${dark ? 'dark' : 'light'}-history-filter-applied',
            );
            await tap(find.byKey(const ValueKey('grant-filters-clear')));
          }
          if (page == 'library') {
            await t
                .widget<LibraryPage>(find.byType(LibraryPage))
                .controller
                .openRelated(
                  const WorkspaceRecordRef(
                    WorkspaceRecordKind.credential,
                    'sshkey',
                  ),
                );
            await t.pumpAndSettle();
            await capture(
              '${width.toInt()}-${dark ? 'dark' : 'light'}-credential',
            );
          }
        }
      }
    }
    await t.pumpWidget(const SizedBox());
    desktop.dispose();
    semantics.finishAfterUnmount();
  });
  testWidgets('connection presentation uses the native approved theme', (
    t,
  ) async {
    final semantics = NativeSemanticsLifetime(t);
    final desktop = MacPreviewDesktop();
    await desktop.initialize();
    final output = (await MacPreviewDesktop.channel.invokeMethod<String>(
      'createEvidenceDirectory',
    ))!;
    // ignore: avoid_print
    print('APPROVED_CONNECTION_EVIDENCE=$output');
    final draft = SetupPreviewDraft()..host.text = 'nas.example.local';
    draft.saveServer('SYNTHETIC_TEST_PASSWORD');
    final boundary = GlobalKey();
    await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
      'width': 1000.0,
      'height': 900.0,
    });
    for (final dark in [false, true]) {
      for (final state in ['form', 'loading', 'disconnected']) {
        await t.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: zhiyuTheme(dark ? Brightness.dark : Brightness.light),
              home: Scaffold(
                body: state == 'form'
                    ? ConnectionSettings(draft: draft, onBack: () {})
                    : ConnectionSurface(
                        title: state == 'loading' ? '正在同步资料' : '连接已断开',
                        description: '合成界面验收',
                        loading: state == 'loading',
                        children: const [],
                      ),
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 400));
        expect(t.takeException(), isNull);
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$output/${dark ? 'dark' : 'light'}-$state.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }
    }
    await t.pumpWidget(const SizedBox());
    draft.dispose();
    desktop.dispose();
    semantics.finishAfterUnmount();
  });
  testWidgets('real recycled batch previews content in the native window', (
    t,
  ) async {
    final semantics = NativeSemanticsLifetime(t);
    final desktop = MacPreviewDesktop();
    await desktop.initialize();
    final output = (await MacPreviewDesktop.channel.invokeMethod<String>(
      'createEvidenceDirectory',
    ))!;
    // ignore: avoid_print
    print('APPROVED_RECYCLE_EVIDENCE=$output');
    final repository = core.MemoryInformationRepository();
    final service = core.InformationService(repository: repository);
    final source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
    final directory = await service.owner.createDirectory('合成服务资料');
    final item = await service.owner.createInformation('合成 NAS 配置', '仅供自动验收', [
      const core.FieldInput('部署说明', '', 'NAS 保存文件，应用通过局域网访问。'),
    ], directoryId: directory.id);
    final selection = WorkspaceLibrarySelection(directoryIds: [directory.id]);
    final preview = await source.previewLibraryRecycle(selection);
    final receipt = await source.changeLibraryRecycle(
      WorkspaceLibraryRecycleCommand(
        operationId: 'native-recycle-preview',
        reviewToken: preview.token,
        selection: selection,
      ),
    );
    final boundary = GlobalKey();
    await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
      'width': 1000.0,
      'height': 900.0,
    });
    for (final dark in [false, true]) {
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: zhiyuTheme(dark ? Brightness.dark : Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showLibraryBatchRecycle(
                    context,
                    source,
                    batchId: receipt.batchId,
                  ),
                  child: const Text('查看合成回收批次'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('查看合成回收批次'));
      await t.pumpAndSettle();
      await t.tap(find.text('查看完整范围'));
      await t.pumpAndSettle();
      final button = find.byKey(
        ValueKey('batch-member-preview-information:${item.id}'),
      );
      await t.ensureVisible(button);
      await t.tap(button);
      await t.pumpAndSettle();
      expect(find.text('NAS 保存文件，应用通过局域网访问。'), findsWidgets);
      expect(
        find.byKey(const ValueKey('library-recycle-submit')),
        findsNothing,
      );
      expect(t.takeException(), isNull);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$output/${dark ? 'dark' : 'light'}-recycled-member.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      await t.tap(find.byKey(const ValueKey('batch-member-close')));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
    }
    expect(service.owner.libraryRecycleBatches, hasLength(1));
    await t.pumpWidget(const SizedBox());
    await source.dispose();
    await service.close();
    desktop.dispose();
    semantics.finishAfterUnmount();
  });
  testWidgets(
    'real submissions show their names and titles in the native workspace',
    (t) async {
      final semantics = NativeSemanticsLifetime(t);
      final desktop = MacPreviewDesktop();
      await desktop.initialize();
      final output = (await MacPreviewDesktop.channel.invokeMethod<String>(
        'createEvidenceDirectory',
      ))!;
      // ignore: avoid_print
      print('APPROVED_SUBMISSION_EVIDENCE=$output');
      final service = core.InformationService(
        repository: core.MemoryInformationRepository(),
      );
      final item = await service.owner.createInformation('合成 NAS', '', [
        const core.FieldInput('地址', '', 'synthetic.invalid'),
      ]);
      final session = service.agent.openSession('原生验收聊天');
      final fields = [core.FieldRef(item.id, item.fields.single.id)];
      final granted = service.agent.request(
        session,
        '检查 NAS 地址',
        fields,
        agentName: '原生验收 Agent',
        externalChatId: 'native-synthetic-chat',
      );
      service.owner.approve(granted.id, fields);
      service.agent.request(
        session,
        '核对 NAS 部署位置',
        fields,
        agentName: '原生验收 Agent',
        externalChatId: 'native-synthetic-chat',
      );
      await service.agent.submitImport(
        session,
        [
          core.ImportItemInput('合成应用', '', [
            const core.FieldInput('用途', '', '自动验收'),
          ]),
        ],
        title: '补齐 NAS 应用清单',
        purpose: '整理应用信息',
        agentName: '原生验收 Agent',
        externalChatId: 'native-synthetic-chat',
      );
      late OwnerWorkspaceSource source;
      final proposals = OwnerWorkspaceProposals(
        owner: service.owner,
        library: () => source,
        changed: () => source.notifyExternalChange(),
      );
      source = OwnerWorkspaceSource(
        owner: service.owner,
        proposals: proposals,
        refreshInterval: Duration.zero,
      );
      final boundary = GlobalKey();
      await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
        'width': 1440.0,
        'height': 900.0,
      });
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: WorkspaceApp(
            source: source,
            desktop: desktop,
            windowTitle: MacPreviewDesktop.windowTitle,
          ),
        ),
      );
      await t.pumpAndSettle();
      for (final page in ['approvals', 'proposals', 'history']) {
        await t.tap(find.byKey(ValueKey('workspace-nav-$page')));
        await t.pumpAndSettle();
        expect(find.textContaining('原生验收 Agent'), findsWidgets);
        expect(find.textContaining('native-synthetic-chat'), findsWidgets);
        expect(find.textContaining('未提供 Agent 名称'), findsNothing);
        if (page == 'proposals') expect(find.text('补齐 NAS 应用清单'), findsWidgets);
        expect(t.takeException(), isNull);
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$output/$page-source.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }
      await t.pumpWidget(const SizedBox());
      await source.dispose();
      await service.close();
      desktop.dispose();
      semantics.finishAfterUnmount();
    },
  );
  testWidgets(
    'real connection settings retain the native workspace',
    (t) async {
      final semantics = NativeSemanticsLifetime(t);
      await loadDesktopFonts();
      final fixture =
          jsonDecode(
                utf8.decode(
                  base64Decode(
                    const String.fromEnvironment(
                      'CHIYO_NATIVE_CONNECTION_FIXTURE',
                    ),
                  ),
                ),
              )
              as Map<String, dynamic>;
      final root = await Directory.systemTemp.createTemp(
        'chiyo-native-connection-',
      );
      final store = PrivateConnectionProfileStore(root.path);
      await store.save(ConnectionProfile.fromJson(fixture));
      final desktop = MacPreviewDesktop();
      await desktop.initialize();
      final output = (await MacPreviewDesktop.channel.invokeMethod<String>(
        'createEvidenceDirectory',
      ))!;
      // ignore: avoid_print
      print('NATIVE_CONNECTION_SETTINGS_EVIDENCE=$output');
      final harness = OnlineUiHarness(t);
      final boundary = GlobalKey();
      RemoteWorkspaceSource? live;
      try {
        await t.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: OnlineDesktopLauncher(
              profiles: store,
              desktopPlatform: NativeDesktopFixture(),
              deviceFilesDirectory: '${root.path}/files',
            ),
          ),
        );
        await harness.until(() => find.text('原生连接验收资料').evaluate().isNotEmpty);
        final source = t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source;
        live = source as RemoteWorkspaceSource;
        expect(find.byTooltip('AI 接入'), findsNothing);
        await harness.tap('workspace-nav-settings');
        expect(find.text('Agent 接入'), findsNothing);
        expect(find.text('旧版模板'), findsNothing);
        await harness.tap('settings-section-connection');
        final settings = t
            .widget<WorkspaceSettingsPage>(find.byType(WorkspaceSettingsPage))
            .controller;
        Finder field(String label) => find.byWidgetPredicate(
          (w) => w is DesktopTextField && w.decoration.labelText == label,
        );
        await harness.until(
          () => settings.value != null && !settings.loading && !settings.frozen,
        );
        for (final width in [1440.0, 1000.0]) {
          await MacPreviewDesktop.channel.invokeMethod<void>('setContentSize', {
            'width': width,
            'height': 900.0,
          });
          await harness.until(
            () => t.view.physicalSize.width / t.view.devicePixelRatio == width,
          );
          for (final dark in [false, true]) {
            await harness.resolve(
              () => settings.setTheme(
                dark ? WorkspaceTheme.dark : WorkspaceTheme.light,
              ),
            );
            await harness.until(() => !settings.loading && !settings.frozen);
            await t.pumpAndSettle();
            expect(settings.writeFailure, isNull);
            expect(
              settings.value!.theme,
              dark ? WorkspaceTheme.dark : WorkspaceTheme.light,
            );
            expect(
              Theme.of(t.element(field('服务器 IP 或域名'))).brightness,
              dark ? Brightness.dark : Brightness.light,
            );
            expect(find.text('已记住服务器证书'), findsOneWidget);
            expect(find.byTooltip('连接设置'), findsNothing);
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$output/connection-settings-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
            expect(t.takeException(), isNull);
          }
        }

        // The external synthetic fixture includes a real persisted request.
        // Exercise the same controls used by the shipped App, then read the
        // actual saved decision; no preview state or fake approval is involved.
        await harness.tap('workspace-nav-approvals');
        await harness.tap('approval-select-${fixture['requestId']}');
        await harness.until(
          () => find
              .byKey(const ValueKey('approval-field-ttl'))
              .evaluate()
              .isNotEmpty,
        );
        await t.tap(find.byKey(const ValueKey('approval-field-ttl')));
        await t.pumpAndSettle();
        for (final label in ['2 小时', '4 小时', '8 小时', '24 小时']) {
          expect(find.text(label), findsWidgets);
        }
        expect(find.text('15 分钟'), findsNothing);
        expect(find.text('30 分钟'), findsNothing);
        final menuRender =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final menuImage = await menuRender.toImage(pixelRatio: 1);
        final menuBytes = await menuImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await File(
          '$output/approval-duration-options.png',
        ).writeAsBytes(menuBytes!.buffer.asUint8List());
        menuImage.dispose();
        await t.tap(find.text('4 小时').last);
        await t.pumpAndSettle();
        await harness.tap('approval-approve');
        await harness.until(
          () => !t
              .widget<ApprovalsPage>(find.byType(ApprovalsPage))
              .controller
              .frozen,
        );
        final approved = await harness.resolve(
          () => source.approvals.read(fixture['requestId'] as String),
        );
        expect(approved.request.state, WorkspaceApprovalState.approved);
        expect(
          approved.fieldExpiresAt!.difference(approved.decidedAt!),
          const Duration(hours: 4),
        );
        await harness.tap('workspace-nav-settings');
        await harness.tap('settings-section-records');
        await harness.until(
          () =>
              t
                  .widget<DesktopSelect<int>>(
                    find.byKey(const ValueKey('settings-request-minutes')),
                  )
                  .onChanged !=
              null,
        );
        await t.tap(find.byKey(const ValueKey('settings-request-minutes')));
        await t.pumpAndSettle();
        for (final label in [
          '30 分钟',
          '1 小时',
          '2 小时',
          '4 小时',
          '8 小时',
          '24 小时',
        ]) {
          expect(find.text(label), findsWidgets);
        }
        expect(find.text('5 分钟'), findsNothing);
        expect(find.text('15 分钟'), findsNothing);
        await t.tap(find.text('2 小时').last);
        await t.pumpAndSettle();
        await harness.tap('settings-section-connection');
        await t.enterText(field('服务器 IP 或域名'), 'not a valid host');
        await harness.tap('connection-save');
        await harness.until(
          () =>
              find.text('请填写服务器 IP 或域名，不需要填写 https://。').evaluate().isNotEmpty,
        );
        expect(
          identical(
            t.widget<WorkspaceApp>(find.byType(WorkspaceApp)).source,
            source,
          ),
          isTrue,
        );
        await t.tap(find.text('返回信息库'));
        await harness.until(
          () => find.byType(ApprovalsPage).evaluate().isNotEmpty,
        );
        expect((await store.read())!.token, fixture['token']);
        await t.pumpWidget(const SizedBox());
      } finally {
        await t.pumpWidget(const SizedBox());
        await live?.dispose();
        desktop.dispose();
        await root.delete(recursive: true);
        semantics.finishAfterUnmount();
      }
    },
    skip: const String.fromEnvironment(
      'CHIYO_NATIVE_CONNECTION_FIXTURE',
    ).isEmpty,
  );
}
