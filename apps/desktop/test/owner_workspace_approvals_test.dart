import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late AgentServer server;
  late HttpClient http;
  late DateTime now;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(
      repository: repo,
      clock: () => now,
      credentialExecutableInspector: (path, receiver) async =>
          core.ExecutableIdentity(path, 10, 100, 'sha256:fixture'),
    );
    source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
    server = await AgentServer.start(service.agent, port: 0);
    http = HttpClient();
  }

  Future<void> close() async {
    http.close(force: true);
    await server.close();
    await source.dispose();
    await service.close();
    await repo.close();
  }

  Future<Map<String, dynamic>> call(
    String path,
    Map<String, Object?> body,
  ) async {
    final request = await http.post('127.0.0.1', server.port, path);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    return jsonDecode(await utf8.decoder.bind(await request.close()).join())
        as Map<String, dynamic>;
  }

  setUp(() async {
    now = DateTime.utc(2026, 10, 30);
    root = await Directory.systemTemp.createTemp('owner-approval-');
    keys = _Keys();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  test(
    'HTTP request is the same real inbox record; no content or private capability enters detail',
    () async {
      final item = await service.owner.createInformation('合成资料', '公开说明', [
        const core.FieldInput('地址', '连接地址', 'SECRET-BODY-MARKER'),
      ]);
      final session =
          (await call('/session', {'chatLabel': '合成聊天'}))['sessionSecret']
              as String;
      final intent = <String, Object?>{
        'protocolVersion': 2,
        'sessionSecret': session,
        'operationId': 'inspect-1',
        'purpose': '合成资料验收',
        'fields': [
          {'itemId': item.id, 'fieldId': item.fields.single.id},
        ],
      };
      final response = await call('/request', intent);
      expect(await call('/request', intent), response);
      final model = ApprovalsController(source.approvals, const Stream.empty());
      addTearDown(model.dispose);
      await model.load();
      expect(model.results!.total, 1);
      expect(model.results!.pending, 1);
      final detail = model.detail!;
      expect(detail.request.id, response['requestId']);
      expect(
        detail.request.requestExpiresAt,
        DateTime.parse(response['requestExpiresAt'] as String),
      );
      expect(detail.request.sessionId, isNot(session));
      expect(detail.request.sessionId, isNotEmpty);
      expect(detail.scopes.single.fieldId, item.fields.single.id);
      expect(detail.scopes.single.label, '地址');
      expect(detail.scopes.single.recordName, '合成资料');
      expect(model.canDecide, isTrue);
      expect(detail.decisionUnavailableReason, isNull);
      expect((await source.loadSummary()).pending, 1);
      expect(
        (await source.approvals.query(
          const WorkspaceApprovalQuery(keyword: 'SECRET-BODY-MARKER'),
        )).total,
        0,
      );
      expect(
        (await call('/claim', {
          'sessionSecret': session,
          'requestId': response['requestId'],
        }))['status'],
        'pending',
      );
    },
  );

  test(
    'HTTP AI request, controller partial approval, read and revoke use the same durable decision',
    () async {
      final item = await service.owner.createInformation('真实审批合成资料', '', [
        const core.FieldInput('允许字段', '', 'ALLOWED'),
        const core.FieldInput('未选字段', '', 'NOT-ALLOWED'),
      ]);
      final session =
          (await call('/session', {'chatLabel': '真实协议合成聊天'}))['sessionSecret']
              as String;
      final request = await call('/request', {
        'sessionSecret': session,
        'purpose': 'partial read',
        'fields': [
          for (final f in item.fields) {'itemId': item.id, 'fieldId': f.id},
        ],
      });
      final model = ApprovalsController(source.approvals, const Stream.empty());
      addTearDown(model.dispose);
      await model.load();
      model.toggle(model.detail!.scopes.last.id);
      model.lifetime(5);
      await model.decide(WorkspaceApprovalAction.approve);
      expect(model.writeFailure, isNull);
      expect(model.detail!.request.state, WorkspaceApprovalState.approved);
      expect(model.detail!.approved, hasLength(1));
      final claimed = await call('/claim', {
        'sessionSecret': session,
        'requestId': request['requestId'],
      });
      expect(claimed['status'], 'ok');
      expect(
        DateTime.parse(claimed['expiresAt'] as String),
        now.add(const Duration(minutes: 5)),
      );
      final read = {
        'token': claimed['token'],
        'itemId': item.id,
        'fieldId': item.fields.first.id,
      };
      expect((await call('/read', read))['value'], 'ALLOWED');
      expect(
        (await call('/read', {
          ...read,
          'fieldId': item.fields.last.id,
        }))['status'],
        'unauthorized',
      );
      await model.decide(WorkspaceApprovalAction.revoke);
      expect(model.writeFailure, isNull);
      expect(model.detail!.request.state, WorkspaceApprovalState.revoked);
      expect((await call('/read', read))['status'], 'unauthorized');
      expect((await service.owner.history()).grants.single.active, isFalse);
    },
  );

  test(
    'stale review conflicts; denial and original receipt survive reopen without replay',
    () async {
      final item = await service.owner.createInformation('合成冲突', '', [
        const core.FieldInput('字段', '', 'ONE'),
      ]);
      final session = service.agent.openSession('synthetic');
      final ref = core.FieldRef(item.id, item.fields.single.id);
      final id = service.agent.request(session, 'review', [ref]).id;
      final before = await source.approvals.read(id);
      WorkspaceApprovalChange change(String token) => WorkspaceApprovalChange(
        operationId: 'deny-real',
        requestId: id,
        reviewToken: token,
        action: WorkspaceApprovalAction.deny,
      );
      await service.owner.correctValue(ref, 'TWO');
      await expectLater(
        source.approvals.change(change(before.reviewToken)),
        throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      expect(await source.approvals.receipt('deny-real'), isNull);
      final command = change((await source.approvals.read(id)).reviewToken);
      await source.approvals.change(command);
      expect(service.agent.status(session, id)['status'], 'denied');
      final receipt = await source.approvals.receipt('deny-real');
      expect(receipt!.commandDigest, command.digest);
      await close();
      await open();
      expect(
        (await source.approvals.change(command)).commandDigest,
        receipt.commandDigest,
      );
      expect(service.owner.sessions, isEmpty);
      expect(
        (await source.approvals.receipt('deny-real'))!.action,
        WorkspaceApprovalAction.deny,
      );
      expect(
        (await source.approvals.read(id)).request.state,
        WorkspaceApprovalState.denied,
      );
    },
  );

  test(
    'terminal transitions refresh even with unchanged pending count, retaining original selection',
    () async {
      final item = await service.owner.createInformation('合成状态', '', [
        const core.FieldInput('字段', '', 'private'),
      ]);
      final ref = core.FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('synthetic');
      final first = service.agent.request(session, 'first', [ref]);
      final second = service.agent.request(session, 'second', [ref]);
      service.owner.approve(first.id, [ref]);
      service.owner.deny(second.id);
      source.refreshFromOwner();
      await Future<void>.delayed(Duration.zero);
      final events = <WorkspaceRecordRef?>[];
      final sub = source.changes.listen(events.add);
      addTearDown(sub.cancel);
      final prior = await source.approvals.query(
        const WorkspaceApprovalQuery(
          filter: WorkspaceApprovalFilter.all,
          limit: 1,
        ),
        keepSelection: first.id,
      );
      expect(prior.pending, 0);
      expect(prior.selection, first.id);
      service.owner.revoke(first.id);
      source.refreshFromOwner();
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(
        (await source.approvals.read(first.id)).request.state,
        WorkspaceApprovalState.revoked,
      );
      final third = service.agent.request(session, 'third', [ref]);
      now = now.add(const Duration(hours: 1));
      expect(
        (await source.approvals.read(third.id)).request.state,
        WorkspaceApprovalState.expired,
      );
      expect(
        (await source.approvals.query(const WorkspaceApprovalQuery())).pending,
        0,
      );
      expect(
        (await source.approvals.query(
          const WorkspaceApprovalQuery(
            filter: WorkspaceApprovalFilter.done,
            keyword: 'first',
          ),
        )).items.single.id,
        first.id,
      );
    },
  );

  test(
    'SQLCipher reopen shows closed history without resurrecting requests or accepting old source',
    () async {
      final item = await service.owner.createInformation('合成重开', '', [
        const core.FieldInput('字段', '', 'private'),
      ]);
      final session = service.agent.openSession('synthetic');
      final ref = core.FieldRef(item.id, item.fields.single.id);
      final pending = service.agent.request(session, 'pending', [ref]);
      final approved = service.agent.request(session, 'approved', [ref]);
      service.owner.approve(approved.id, [ref]);
      final original = await source.approvals.read(approved.id);
      final old = source.approvals;
      await close();
      await open();
      final results = await source.approvals.query(
        const WorkspaceApprovalQuery(filter: WorkspaceApprovalFilter.all),
      );
      expect(results.total, 2);
      expect(results.pending, 0);
      for (final id in [pending.id, approved.id]) {
        expect(
          (await source.approvals.read(id)).request.state,
          WorkspaceApprovalState.sessionEnded,
        );
      }
      final detail = await source.approvals.read(approved.id);
      expect(detail.request.sessionId, original.request.sessionId);
      expect(detail.approved, original.approved);
      expect(detail.scopes.single.available, isFalse);
      expect(service.owner.informationRequests, isEmpty);
      expect(
        (await call('/request/status', {
          'sessionSecret': session,
          'operationId': 'anything',
        }))['status'],
        'unauthorized',
      );
      await expectLater(
        old.read(approved.id),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'library_changed',
          ),
        ),
      );
    },
  );
  Future<(String, core.CredentialUseRequest)> credentialRequest({
    List<core.FieldRef> fields = const [],
  }) async {
    var c = await service.owner.createStringCredential(
      name: '合成凭据',
      publicPurpose: '',
      secret: 'SYNTHETIC-ONLY',
    );
    c = await service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: '',
      privateNote: '',
      suggestedBinding: 'GH_TOKEN',
      discoverable: true,
    );
    final session = service.agent.openSession('合成凭据聊天');
    final r = await service.agent.requestCredentialUse(
      session,
      core.CredentialUseInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': '合成审批链路',
        'credentials': [
          {'alias': 'token', 'credentialId': c.id, 'version': c.version},
        ],
        'readFields': [for (final f in fields) f.toJson()],
        'launch': {
          'receiver': 'gh_token',
          'executable': Platform.resolvedExecutable,
          'argv': ['api', 'user', '--method', 'GET'],
          'cwd': root.path,
          'env': {
            'GH_TOKEN': {'secret': 'token'},
          },
        },
      }),
    );
    return (session, r);
  }

  test(
    'real credential request partial approval, exact durable receipt and revoked grant',
    () async {
      final item = await service.owner.createInformation('合成资料', '', [
        const core.FieldInput('地址', '', '合成正文'),
      ]);
      final (session, r) = await credentialRequest(
        fields: [core.FieldRef(item.id, item.fields.single.id)],
      );
      final detail = await source.approvals.read(r.id);
      expect(detail.request.kind, WorkspaceApprovalKind.credential);
      expect(detail.credential!.session.id, isNot(session));
      expect(detail.scopes.length, 2);
      expect(
        (await source.approvals.query(
          const WorkspaceApprovalQuery(),
        )).items.where((i) => i.id == r.id).length,
        1,
      );
      final field = detail.scopes.singleWhere(
        (s) => s.kind == WorkspaceApprovalScopeKind.field,
      );
      final c = WorkspaceApprovalChange(
        operationId: workspaceOperationId(),
        requestId: r.id,
        reviewToken: detail.reviewToken,
        action: WorkspaceApprovalAction.approve,
        selected: [field.id],
        fieldMinutes: 60,
      );
      final receipt = await source.approvals.change(c);
      expect(receipt.revision, 1);
      expect(
        (await source.credentials.requests()).single.state,
        WorkspaceCredentialRequestState.partiallyApproved,
      );
      expect(
        service.owner.credentialUseRequests.single.credentialApproved,
        false,
      );
      expect((await source.approvals.change(c)).revision, 1);
      final history = await source.credentials.history(
        WorkspaceRecordRef(WorkspaceRecordKind.credential, r.credentialId),
      );
      expect(history.single.operations.single.description, '用户审批');
      final bearer = service.agent.claim(session, r.id).token;
      expect(
        await service.agent.read(
          bearer,
          core.FieldRef(item.id, item.fields.single.id),
        ),
        '合成正文',
      );
      final mixed = await source.approvals.read(r.id);
      final revoke = WorkspaceApprovalChange(
        operationId: workspaceOperationId(),
        requestId: r.id,
        reviewToken: mixed.reviewToken,
        action: WorkspaceApprovalAction.revoke,
      );
      expect((await source.approvals.change(revoke)).revision, 2);
      await expectLater(
        service.agent.read(
          bearer,
          core.FieldRef(item.id, item.fields.single.id),
        ),
        throwsA(isA<core.AccessFailure>()),
      );
      expect(
        service.owner.credentialFieldGrantState(
          service.owner.credentialUseRequests.single,
        ),
        'revoked',
      );

      await close();
      await open();
      expect(
        (await source.approvals.receipt(c.operationId))!.commandDigest,
        c.digest,
      );
      expect((await source.approvals.change(c)).revision, 1);
      expect(
        (await source.credentials.requests()).single.state,
        isNot(WorkspaceCredentialRequestState.approved),
      );
    },
  );
  test(
    'credential approve and revoke are real and stale scope cannot be approved',
    () async {
      final (_, r) = await credentialRequest();
      final detail = await source.approvals.read(r.id);
      final approved = await source.approvals.change(
        WorkspaceApprovalChange(
          operationId: workspaceOperationId(),
          requestId: r.id,
          reviewToken: detail.reviewToken,
          action: WorkspaceApprovalAction.approve,
          selected: [detail.scopes.single.id],
        ),
      );
      expect(approved.revision, 1);
      expect(
        service.owner.credentialGrantState(
          service.owner.credentialUseRequests.single,
        ),
        'available',
      );
      final current = await source.approvals.read(r.id);
      final revoke = WorkspaceApprovalChange(
        operationId: workspaceOperationId(),
        requestId: r.id,
        reviewToken: current.reviewToken,
        action: WorkspaceApprovalAction.revoke,
      );
      expect((await source.approvals.change(revoke)).revision, 2);
      expect(
        service.owner.credentialGrantState(
          service.owner.credentialUseRequests.single,
        ),
        'revoked',
      );
      expect((await source.approvals.receipt(revoke.operationId))!.revision, 2);
    },
  );
  test(
    'organization approval binds selected real records and durable original receipt',
    () async {
      final a = await service.owner.createInformation('合成整理资料', '', [
        const core.FieldInput('字段', '', '内容'),
      ]);
      final b = await service.owner.createInformation('未选资料', '', [
        const core.FieldInput('字段', '', '内容'),
      ]);
      final session = service.agent.openSession('合成整理聊天');
      final task = await service.agent.requestOrganization(session, '整理分类', [
        a.id,
        b.id,
      ]);
      final detail = await source.approvals.read(task.id);
      expect(detail.request.kind, WorkspaceApprovalKind.organization);
      final c = WorkspaceApprovalChange(
        operationId: workspaceOperationId(),
        requestId: task.id,
        reviewToken: detail.reviewToken,
        action: WorkspaceApprovalAction.approve,
        selected: [a.id],
        fieldMinutes: 15,
      );
      final receipt = await source.approvals.change(c);
      expect(receipt.revision, 1);
      final saved = service.owner.organizationTasks.single;
      expect(saved.autoApply, true);
      expect(saved.itemVersions.keys, [a.id]);
      expect(
        service.owner.organizationState(saved),
        core.OrganizationTaskState.active,
      );
      final current = await source.approvals.read(task.id);
      await source.approvals.change(
        WorkspaceApprovalChange(
          operationId: workspaceOperationId(),
          requestId: task.id,
          reviewToken: current.reviewToken,
          action: WorkspaceApprovalAction.revoke,
        ),
      );
      expect(
        service.owner.organizationState(service.owner.organizationTasks.single),
        core.OrganizationTaskState.cancelled,
      );
      await close();
      await open();
      expect((await source.approvals.change(c)).commandDigest, c.digest);
      expect(
        service.owner.organizationTasks.single.state,
        core.OrganizationTaskState.cancelled,
      );
    },
  );
}
