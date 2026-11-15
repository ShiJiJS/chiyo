import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/grant_history_controller.dart';
import 'package:info_desktop/workspace/grant_history_page.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isNotEmpty) {
      await (FontLoader('AppSans')
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Medium.otf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  testWidgets(
    'structured metadata reaches real history; exact script stays separate and partial grant stays explicit',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late core.InformationService service;
      late OwnerWorkspaceSource owner;
      late GrantHistoryController model;
      final credentials = <core.ManagedCredential>[];
      await tester.runAsync(() async {
        service = core.InformationService(
          repository: core.MemoryInformationRepository(),
        );
        for (final name in ['测试服务令牌', '备用服务令牌']) {
          final c = await service.owner.createStringCredential(
            name: name,
            publicPurpose: '',
            secret: 'SYNTHETIC_NEVER_RENDER',
          );
          credentials.add(
            await service.owner.updateCredentialMetadata(
              c.id,
              c.revision,
              name: name,
              publicPurpose: '',
              privateNote: '',
              suggestedBinding: 'TOKEN',
              discoverable: true,
            ),
          );
        }
        final session = service.agent.openSession('合成历史检查');
        final plan =
            core.CredentialProgramPlan.fromJson({
              'executable': '/usr/bin/python3',
              'cwd': '/work/project',
              'argv': ['-c', 'print("SYNTHETIC_SCRIPT_BODY")'],
              'env': {
                'SERVICE_TOKEN': {
                  'credentialId': credentials[0].id,
                  'version': 1,
                },
                'BACKUP_TOKEN': {
                  'credentialId': credentials[1].id,
                  'version': 1,
                },
              },
            }, allowPortablePaths: true).resolved(
              core.ExecutableIdentity(
                '/usr/bin/python3',
                100,
                1,
                'sha256:${'a' * 64}',
              ),
              '/work/project',
            );
        final request = await service.agent.requestCredentialBatch(
          session,
          'A' * 22,
          core.CredentialBatchInput.forProgram(
            plan,
            title: '检查测试服务状态',
            purpose: '查询当前任务状态，汇总需要处理的异常。',
          ),
          operationId: 'structured-history',
        );
        await service.owner.decideCredentialBatch(
          request.id,
          operationId: 'structured-approve',
          revision: 1,
          approvedItems: ['b1'],
        );
        owner = OwnerWorkspaceSource(
          owner: service.owner,
          refreshInterval: Duration.zero,
        );
        model = GrantHistoryController(
          owner.grantHistory,
          owner.approvals,
          const Stream.empty(),
        );
        await model.open('request:${request.id}');
      });
      addTearDown(() async {
        model.dispose();
        await owner.dispose();
        await service.close();
      });
      expect(model.readFailure, isNull);
      expect(model.detail!.summary.title, '检查测试服务状态');
      expect(model.detail!.summary.purpose, '查询当前任务状态，汇总需要处理的异常。');
      expect(model.detail!.scopes.length, 1);
      final theme = zhiyuTheme(Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: evidence.isEmpty
              ? theme
              : theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: 'AppSans'),
                ),
          home: RepaintBoundary(
            key: const ValueKey('history-capture'),
            child: Scaffold(
              body: GrantHistoryPage(
                controller: model,
                onRecord: (_) {},
                onRequest: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('检查测试服务状态'), findsWidgets);
      expect(find.textContaining('SYNTHETIC_SCRIPT_BODY'), findsNothing);
      expect(find.textContaining('SYNTHETIC_NEVER_RENDER'), findsNothing);
      if (evidence.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('history-capture')),
        );
        await tester.runAsync(() async {
          await Directory(evidence).create(recursive: true);
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$evidence/structured-history.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final command = find.text('查看完整命令与脚本');
      await tester.ensureVisible(command);
      await tester.tap(command);
      await tester.pumpAndSettle();
      expect(find.textContaining('SYNTHETIC_SCRIPT_BODY'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
