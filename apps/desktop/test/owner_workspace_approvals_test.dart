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
    service = core.InformationService(repository: repo, clock: () => now);
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
      expect(model.canDecide, isFalse);
      expect(detail.decisionUnavailableReason, isNotNull);
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
}
