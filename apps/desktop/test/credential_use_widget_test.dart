import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/prototype_ui.dart';
import 'package:info_desktop/prototype_dialog.dart';

Future<(InformationService, String, CredentialUseRequest)> fixture({
  MemoryInformationRepository? repository,
}) async {
  final service = InformationService(
    repository: repository ?? MemoryInformationRepository(),
    credentialExecutableInspector: (path, receiver) async =>
        ExecutableIdentity(path, 1, 1, 'sha256:synthetic'),
  );
  final item = await service.owner.createInformation('测试服务器', '', [
    const FieldInput('服务器地址', '', 'test.example.invalid'),
  ]);
  var c = await service.owner.createStringCredential(
    name: '文档站发布 Token',
    publicPurpose: '发布北辰文档站',
    secret: 'synthetic-token',
  );
  c = await service.owner.updateCredentialMetadata(
    c.id,
    c.revision,
    name: c.name,
    publicPurpose: c.publicPurpose,
    privateNote: '',
    suggestedBinding: 'GH_TOKEN',
    discoverable: true,
  );
  final session = service.agent.openSession('部署北辰文档站');
  final request = await service.agent.requestCredentialUse(
    session,
    CredentialUseInput.fromJson({
      'command': 'request-use',
      'purpose': '发布更新后的北辰文档站，需要使用 GitHub Token 完成本次发布。',
      'credentials': [
        {'alias': 'deploy_token', 'credentialId': c.id, 'version': 1},
      ],
      'launch': {
        'receiver': 'gh_token',
        'executable': Platform.resolvedExecutable,
        'argv': ['repo', 'view', 'northstar/docs'],
        'cwd': Directory.current.path,
        'env': {
          'GH_TOKEN': {'secret': 'deploy_token'},
        },
      },
      'readFields': [
        {'itemId': item.id, 'fieldId': item.fields.single.id},
      ],
    }),
  );
  return (service, session, request);
}

void main() {
  testWidgets(
    'handled credential request exposes its actual nonzero execution receipt without material or output',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (service, session, request) = (await tester.runAsync(fixture))!;
      addTearDown(service.close);
      await tester.runAsync(
        () => service.owner.decideCredentialUse(
          request.id,
          approveCredential: true,
        ),
      );
      final material = (await tester.runAsync(
        () => service.agent.consumeCredentialUse(session, request.id),
      ))!;
      final identity = CredentialProcessIdentity.capture(pid)!;
      addTearDown(identity.close);
      final started = DateTime.now().toUtc();
      await tester.runAsync(
        () => service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: material.executionId,
            executionCapability: material.executionCapability,
            state: 'running',
            pid: pid,
            processCreatedAt: identity.value,
            startedAt: started,
          ),
        ),
      );
      await tester.runAsync(
        () => service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: material.executionId,
            executionCapability: material.executionCapability,
            state: 'exited',
            pid: pid,
            processCreatedAt: identity.value,
            startedAt: started,
            finishedAt: DateTime.now().toUtc(),
            exitCode: 7,
          ),
        ),
      );
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      final link = find.text('查看执行记录 →');
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.text('执行记录'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PrototypeDialog),
          matching: find.text('无需文件清理'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('synthetic-token'), findsNothing);
      await tester.tap(find.text('返回审批'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'owner can omit a deleted requested field and still approve the credential',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (service, session, request) = (await tester.runAsync(fixture))!;
      addTearDown(service.close);
      final item = service.owner.information.single;
      await tester.runAsync(
        () => service.owner.deleteInformation(item.id, item.version),
      );
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      final fields = find.textContaining('另外申请读取连接字段');
      await tester.ensureVisible(fields);
      await tester.tap(fields);
      await tester.pumpAndSettle();
      final row = find
          .ancestor(of: find.text('已删除字段'), matching: find.byType(Row))
          .first;
      final check = find.descendant(
        of: row,
        matching: find.byType(PrototypeCheck),
      );
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(find.textContaining('另外申请读取连接字段 0 / 1'), findsOneWidget);
      final approve = find.byKey(const ValueKey('credential-use-approve'));
      await tester.ensureVisible(approve);
      await tester.tap(approve);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认批准'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      final status = service.agent.credentialUseStatus(session, request.id);
      expect(status['status'], 'partially_approved');
      expect((status['decision'] as Map)['fieldRead'], {'approved': false});
      expect((status['decision'] as Map)['credentialUse']['approved'], isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'successful decision retry clears the previous save failure notice',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _FailingRuntimeRepository();
      final (service, session, request) = (await tester.runAsync(
        () => fixture(repository: repo),
      ))!;
      addTearDown(service.close);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('credential-use-approve')));
      await tester.pumpAndSettle();
      repo.fail = true;
      await tester.tap(find.text('确认批准'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.textContaining('未能保存决定'), findsWidgets);
      expect(
        service.agent.credentialUseStatus(session, request.id)['status'],
        'pending',
      );
      repo.fail = false;
      await tester.tap(find.text('确认批准'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(
        service.agent.credentialUseStatus(session, request.id)['status'],
        'approved',
      );
      expect(find.textContaining('未能保存决定'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'disabled credential still permits an independent field-only decision',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (service, session, request) = (await tester.runAsync(fixture))!;
      addTearDown(service.close);
      final credential = service.owner.credential(request.credentialId);
      await tester.runAsync(
        () => service.owner.setCredentialEnabled(
          credential.id,
          credential.revision,
          false,
        ),
      );
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('credential-use-approve')));
      await tester.pumpAndSettle();
      expect(find.textContaining('本次仅批准所选连接字段'), findsOneWidget);
      await tester.tap(find.text('确认批准'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      final status = service.agent.credentialUseStatus(session, request.id);
      expect(status['status'], 'partially_approved');
      expect((status['decision'] as Map)['credentialUse'], {
        'approved': false,
        'state': 'not_approved',
      });
      final grant = service.agent.claim(session, request.id);
      expect(
        await tester.runAsync(
          () => service.agent.read(grant.token, request.fields.single),
        ),
        'test.example.invalid',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'owner can approve fields independently from credential use through the real inbox',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (service, session, request) = (await tester.runAsync(fixture))!;
      addTearDown(service.close);
      await tester.pumpWidget(InformationApp(service: service, port: 0));
      await tester.pumpAndSettle();
      expect(find.text('允许这次启动'), findsOneWidget);
      expect(find.text('文档站发布 Token'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('credential-use-allow')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('credential-use-approve')));
      await tester.pumpAndSettle();
      expect(find.text('批准凭据使用'), findsOneWidget);
      await tester.tap(find.text('确认批准'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.textContaining('未能保存决定'), findsNothing);
      final status = service.agent.credentialUseStatus(session, request.id);
      expect(status['status'], 'partially_approved');
      expect((status['decision'] as Map)['credentialUse'], {
        'approved': false,
        'state': 'not_approved',
      });
      final grant = service.agent.claim(session, request.id);
      final value = await tester.runAsync(
        () => service.agent.read(grant.token, request.fields.single),
      );
      expect(value, 'test.example.invalid');
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _FailingRuntimeRepository extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    if (fail) throw StateError('synthetic audit failure');
    await super.commitCredentialRuntime(
      requests,
      executions,
      fieldGrant: fieldGrant,
      fieldRequest: fieldRequest,
      validate: validate,
    );
  }
}
