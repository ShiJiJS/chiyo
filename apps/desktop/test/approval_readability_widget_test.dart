import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/approval_presentation.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/batch_operations.dart';
import 'package:info_desktop/workspace/program_operations.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_workspace/workspace_source.dart';

final _at = DateTime.utc(2026, 11, 15, 6, 20);
final _script =
    'import os\n${List.generate(100, (i) => 'print("SCRIPT-LINE-$i")').join('\n')}';
WorkspaceCredentialProgramPlan _plan() =>
    WorkspaceCredentialProgramPlan.fromJson(
      core.CredentialProgramPlan.fromJson({
            'executable': '/usr/bin/python3',
            'cwd': '/workspace/northstar',
            'argv': [
              '-c',
              _script,
              '--key',
              {
                'file': {'credentialId': 'key', 'version': 3},
              },
            ],
            'env': {
              'CODE_HOST_TOKEN': {'credentialId': 'token', 'version': 2},
            },
            'stdin': {'credentialId': 'password', 'version': 1},
          }, allowPortablePaths: true)
          .resolved(
            core.ExecutableIdentity(
              '/usr/bin/python3',
              100,
              1,
              'sha256:${'a' * 64}',
            ),
            '/workspace/northstar',
          )
          .toJson()
          .cast<String, dynamic>(),
    );

WorkspaceApprovalDetail _detail({
  bool ssh = false,
  bool approved = false,
  WorkspaceCredentialUseRequest? legacy,
  List<WorkspaceCredentialProgramOperation> programs = const [],
  List<WorkspaceCredentialBatchOperation> batches = const [],
}) {
  final plan = _plan();
  final scopes = ssh
      ? [
          WorkspaceApprovalScope(
            id: 'b1',
            record: const WorkspaceRecordRef(
              WorkspaceRecordKind.credential,
              'key',
            ),
            label: '第3版 · SSH · deploy@stage.example.org:22',
            section: '测试服务器 SSH 私钥',
            recordName: '测试服务器 SSH 私钥',
            kind: WorkspaceApprovalScopeKind.credential,
            recordVersion: 3,
            requested: true,
          ),
        ]
      : [
          for (final (i, binding) in plan.receivingPositions.indexed)
            WorkspaceApprovalScope(
              id: 'b${i + 1}',
              record: WorkspaceRecordRef(
                WorkspaceRecordKind.credential,
                binding.credentialId,
              ),
              label: '第${binding.version}版 · ${binding.destination}',
              section: _names[binding.credentialId]!,
              recordName: _names[binding.credentialId]!,
              kind: WorkspaceApprovalScopeKind.credential,
              recordVersion: binding.version,
              requested: true,
            ),
        ];
  return WorkspaceApprovalDetail(
    request: WorkspaceApprovalSummary(
      id: 'request',
      title: ssh ? '连接测试服务器，检查服务状态' : '查询项目最近一次构建状态',
      kind: WorkspaceApprovalKind.credential,
      agentClaim: 'Codex',
      sessionId: 'chat',
      chatClaim: '检查项目构建',
      purpose: '核对任务状态并汇总失败原因。',
      submittedAt: _at,
      requestExpiresAt: _at.add(const Duration(hours: 1)),
      state: approved
          ? WorkspaceApprovalState.approved
          : WorkspaceApprovalState.pending,
    ),
    reviewToken: 'review',
    scopes: scopes,
    approved: approved ? scopes.map((s) => s.id) : [],
    credential: legacy,
    credentialBatch: legacy == null,
    sshSession: ssh,
    sshTarget: ssh
        ? core.SshSessionTarget(
            host: 'stage.example.org',
            port: 22,
            user: 'deploy',
            authentication: 'publickey',
            credentialUse: 'login',
            validity: 'session',
          )
        : null,
    programPlan: ssh || legacy != null ? null : plan,
    batchSupportsSessionValidity: ssh,
    batchSessionBound: ssh && approved,
    credentialExpiresAt: approved && !ssh
        ? _at.add(const Duration(hours: 1))
        : null,
    decidedAt: approved ? _at : null,
    programOperations: programs,
    batchOperations: batches,
  );
}

const _names = {'token': '代码平台访问令牌', 'key': '服务 SSH 密钥', 'password': '服务密码'};

class _Source
    implements
        WorkspaceApprovalSource,
        WorkspaceCredentialProgramActions,
        WorkspaceCredentialBatchActions {
  _Source(this.value);
  WorkspaceApprovalDetail value;
  Completer<WorkspaceCredentialProgramOperation>? pending;
  WorkspaceFailure? failure;
  int reads = 0;
  @override
  Future<WorkspaceApprovalResults> query(
    WorkspaceApprovalQuery query, {
    String? keepSelection,
  }) async => WorkspaceApprovalResults(
    items: [value.request],
    total: 1,
    pending: value.request.state == WorkspaceApprovalState.pending ? 1 : 0,
    offset: 0,
    selection: 'request',
    selectionIndex: 0,
  );
  @override
  Future<WorkspaceApprovalDetail> read(String id) async => value;
  @override
  Future<WorkspaceCredentialProgramOperation> programOperation(
    String requestId,
    String operationId,
  ) async {
    reads++;
    if (failure case final error?) throw error;
    return pending == null ? value.programOperations.single : pending!.future;
  }

  @override
  Future<WorkspaceCredentialBatchOperation> batchOperation(
    String requestId,
    String operationId,
  ) async {
    reads++;
    return value.batchOperations.firstWhere(
      (o) => o.operationId == operationId,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

WorkspaceCredentialProgramOperation _operation() =>
    WorkspaceCredentialProgramOperation(
      requestId: 'request',
      operationId: 'program',
      revision: 1,
      plan: _plan(),
      itemIds: ['b1', 'b2', 'b3'],
      state: 'running',
      createdAt: _at,
      observedAt: _at,
      startedAt: _at,
      processStarted: true,
      cleanup: 'pending',
    );

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    await loadDesktopFonts();
    // Flutter's test renderer does not consistently select a complete CJK
    // face from the system PingFang TTC. Use the bundled product font for
    // evidence so missing fallback glyphs cannot look like missing copy.
    await (FontLoader('AppSans')
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Medium.otf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
  });
  Future<void> capture(WidgetTester tester, String name) async {
    if (evidence.isEmpty) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<ApprovalsController> show(
    WidgetTester tester,
    _Source source, {
    Widget Function(ApprovalsController)? child,
    bool dark = false,
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = ApprovalsController(source, const Stream.empty());
    addTearDown(model.dispose);
    await tester.runAsync(() => model.open('request'));
    final theme = zhiyuTheme(dark ? Brightness.dark : Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: evidence.isEmpty
            ? theme
            : theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'AppSans'),
              ),
        home: RepaintBoundary(
          key: const ValueKey('capture'),
          child: MediaQuery(
            data: MediaQueryData(
              size: const Size(1440, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: ListenableBuilder(
                listenable: model,
                builder: (_, _) => child == null
                    ? ApprovalsPage(controller: model, onRecord: (_) {})
                    : SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(30),
                          child: child(model),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return model;
  }

  testWidgets(
    'program request keeps long script behind exact details and names every receiving position',
    (tester) async {
      final model = await show(tester, _Source(_detail()));
      expect(find.textContaining('SCRIPT-LINE-99'), findsNothing);
      expect(find.textContaining('环境变量 CODE_HOST_TOKEN。'), findsOneWidget);
      expect(find.textContaining('在程序启动时提供输入（stdin）。'), findsOneWidget);
      expect(find.textContaining('参数 4（临时凭据文件路径）'), findsWidgets);
      expect(find.textContaining('Agent 可以换用其他脚本、参数和工作目录'), findsOneWidget);
      expect(find.text('Agent 说明：核对任务状态并汇总失败原因。'), findsOneWidget);
      final choose = find.byKey(const ValueKey('approval-choose-credentials'));
      expect(choose.hitTestable(), findsOneWidget);
      expect(find.text('可在申请范围取消勾选，只批准部分凭据。'), findsOneWidget);
      await capture(tester, 'program-request');
      await tester.tap(choose);
      await tester.pumpAndSettle();
      final firstScope = find.byKey(const ValueKey('approval-scope-b1'));
      expect(firstScope.hitTestable(), findsOneWidget);
      await tester.tap(firstScope);
      await tester.pumpAndSettle();
      expect(model.draft!.selected, {'b2', 'b3'});
      await tester.ensureVisible(find.text('查看完整命令与脚本'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看完整命令与脚本'));
      await tester.pumpAndSettle();
      final exact = find.descendant(
        of: find.byType(ApprovalExactDetails),
        matching: find.byType(SingleChildScrollView),
      );
      expect(tester.getSize(exact).height, lessThanOrEqualTo(280));
      expect(find.textContaining('SCRIPT-LINE-99'), findsOneWidget);
      expect(find.textContaining('代码平台访问令牌（第2版）'), findsOneWidget);
      await tester.ensureVisible(exact);
      await tester.pumpAndSettle();
      await capture(tester, 'program-expanded');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy single credential has compact exact details and preserves named environment binding',
    (tester) async {
      final legacy = WorkspaceCredentialUseRequest(
        id: 'legacy',
        ref: const WorkspaceRecordRef(WorkspaceRecordKind.credential, 'token'),
        credentialName: '代码平台访问令牌',
        materialVersion: 2,
        useGeneration: 1,
        delivery: WorkspaceCredentialDelivery.environment,
        receiver: WorkspaceCredentialReceiver(
          id: 'program_env',
          label: 'Python',
          executable: '/usr/bin/python3',
          workingDirectory: '/workspace/northstar',
          arguments: ['-c', _script],
          binding: 'CODE_HOST_TOKEN',
        ),
        session: const WorkspaceCredentialSession('chat', '检查项目构建', 'Codex'),
        purpose: '检查任务',
        minutes: 30,
        submittedAt: _at,
      );
      await show(
        tester,
        _Source(_detail(legacy: legacy)),
        dark: true,
        scale: 2,
      );
      expect(find.textContaining('SCRIPT-LINE-99'), findsNothing);
      expect(find.text('CODE_HOST_TOKEN → 子进程环境变量'), findsOneWidget);
      await tester.ensureVisible(find.text('查看完整命令与脚本'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看完整命令与脚本'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SCRIPT-LINE-99'), findsOneWidget);
      await capture(tester, 'legacy-dark-large-text');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh shows busy and per-operation no-change or changed feedback without replaying',
    (tester) async {
      final operation = _operation(),
          source = _Source(_detail(approved: true, programs: [_operation()]));
      final model = await show(
        tester,
        source,
        child: (m) => ProgramOperations(controller: m),
      );
      final expiry = model.detail!.credentialExpiresAt;
      source.pending = Completer();
      await tester.tap(find.text('刷新状态'));
      await tester.pump();
      expect(find.text('正在刷新…'), findsOneWidget);
      expect(
        tester
            .widget<DesktopButton>(
              find.ancestor(
                of: find.text('正在刷新…'),
                matching: find.byType(DesktopButton),
              ),
            )
            .onPressed,
        isNull,
      );
      source.pending!.complete(operation);
      await tester.pumpAndSettle();
      expect(find.text('已刷新，状态暂无变化。'), findsOneWidget);
      source.pending = null;
      source.value = _detail(
        approved: true,
        programs: [
          WorkspaceCredentialProgramOperation.fromJson({
            ...operation.toJson(),
            'revision': 2,
            'executionState': 'exited',
            'finishedAt': _at.add(const Duration(minutes: 1)).toIso8601String(),
            'observedAt': _at.add(const Duration(minutes: 1)).toIso8601String(),
            'cleanupState': 'complete',
            'exitCode': 0,
          }),
        ],
      );
      await tester.tap(find.text('刷新状态'));
      await tester.pumpAndSettle();
      expect(find.text('已刷新，已显示最新状态。'), findsOneWidget);
      expect(find.textContaining('不等于已经确认 Agent 说明的任务完成'), findsOneWidget);
      expect(model.detail!.credentialExpiresAt, expiry);
      expect(model.detail!.programOperations, hasLength(1));
      expect(source.reads, 2);
      await capture(tester, 'program-history');
      source.failure = const WorkspaceFailure('offline', '读取失败，原状态已保留。');
      await tester.tap(find.text('刷新状态'));
      await tester.pumpAndSettle();
      expect(find.text('读取失败，原状态已保留。'), findsOneWidget);
      expect(find.text('已刷新，已显示最新状态。'), findsNothing);
      expect(model.detail!.programOperations.single.state, 'exited');
      expect(model.detail!.credentialExpiresAt, expiry);
      expect(source.reads, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SSH request and sent command history state the actual target and never claim execution success',
    (tester) async {
      final operation = WorkspaceCredentialBatchOperation(
        requestId: 'request',
        operationId: 'ssh-run',
        revision: 1,
        itemIds: ['b1'],
        state: 'filled',
        createdAt: _at,
        observedAt: _at,
        finishedAt: _at,
        itemResults: {'b1': 'sent'},
        sshContext: core.SshSessionOperationContext(
          kind: 'run',
          sessionId: 'ssh-session',
          runId: 'remote-run',
          digest: 'sha256:${'a' * 64}',
          byteLength: 100,
        ),
      );
      await show(tester, _Source(_detail(ssh: true)));
      expect(find.textContaining('登录账号 deploy · 端口 22'), findsOneWidget);
      expect(find.textContaining('不限于 Agent 说明的任务'), findsOneWidget);
      await capture(tester, 'ssh-request');
      await tester.pumpWidget(const SizedBox.shrink());
      final source = _Source(
        _detail(ssh: true, approved: true, batches: [operation]),
      );
      await show(tester, source, child: (m) => BatchOperations(controller: m));
      expect(find.text('发送远程命令'), findsOneWidget);
      expect(find.text('命令已发送'), findsOneWidget);
      expect(find.text('本次沿用登录许可，没有再次领取私钥或密码。'), findsOneWidget);
      expect(find.textContaining('尚无命令完成结果'), findsOneWidget);
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('连接：deploy@stage.example.org:22'),
        findsOneWidget,
      );
      expect(find.textContaining('不保存命令正文或输出'), findsOneWidget);
      await tester.tap(find.text('刷新状态'));
      await tester.pumpAndSettle();
      expect(find.text('已刷新，状态暂无变化。'), findsOneWidget);
      expect(source.reads, 1);
      await capture(tester, 'ssh-history');
      await tester.pumpWidget(const SizedBox.shrink());
      final unknown = WorkspaceCredentialBatchOperation.fromJson({
        ...operation.toJson(),
        'executionState': 'unknown',
        'finishedAt': null,
        'itemResults': <String, String>{},
        'errorCode': 'execution_unknown',
      });
      await show(
        tester,
        _Source(_detail(ssh: true, approved: true, batches: [unknown])),
        child: (m) => BatchOperations(controller: m),
      );
      expect(find.textContaining('请让 Agent 查询原连接或命令，不要重新发送'), findsOneWidget);
      expect(find.byKey(const ValueKey('batch-checked-ssh-run')), findsNothing);
      expect(
        find.byKey(const ValueKey('batch-acknowledge-ssh-run')),
        findsNothing,
      );
      expect(find.textContaining('解除后续使用限制'), findsNothing);
      await capture(tester, 'ssh-unknown');
      expect(tester.takeException(), isNull);
    },
  );
}
