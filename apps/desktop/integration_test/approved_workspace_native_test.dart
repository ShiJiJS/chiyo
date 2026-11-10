import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/connection_view.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/proposal_directory.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/library_batch_recycle_dialog.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
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
    final address = TextEditingController(
      text: 'https://nas.example.local:47126',
    );
    final token = TextEditingController(text: 'SYNTHETIC_TEST_TOKEN');
    final cert = TextEditingController();
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
                    ? ConnectionForm(
                        address: address,
                        token: token,
                        certificate: cert,
                        busy: false,
                        onConnect: () {},
                      )
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
    address.dispose();
    token.dispose();
    cert.dispose();
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
}
