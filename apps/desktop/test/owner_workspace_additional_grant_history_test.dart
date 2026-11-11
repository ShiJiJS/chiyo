import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_workspace_proposals.dart';
import 'package:info_desktop/workspace/grant_history_controller.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? bytes;
  @override
  Future<List<int>?> read() async => bytes;
  @override
  Future<void> create(List<int> key) async {
    bytes = List.of(key);
  }
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late DateTime now;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      root.path,
      keys,
      clock: () => now,
    );
    service = core.InformationService(
      repository: repo,
      clock: () => now,
      credentialExecutableInspector: (path, receiver) async =>
          core.ExecutableIdentity(path, 10, 100, 'sha256:${'b' * 64}'),
    );
    source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
      proposals: OwnerWorkspaceProposals(
        owner: service.owner,
        library: () => source,
        changed: () {},
      ),
    );
  }

  Future<void> close() async {
    await source.dispose();
    await service.close();
    await repo.close();
  }

  setUp(() async {
    now = DateTime.utc(2026, 11, 2);
    root = await Directory.systemTemp.createTemp('additional-history-');
    keys = _Keys();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });

  Future<void> approve(String id) async {
    final m = ApprovalsController(source.approvals, const Stream.empty());
    try {
      await m.open(id);
      m.lifetime(240);
      m.lifetime(120, credential: true);
      await m.decide(WorkspaceApprovalAction.approve);
      expect(m.writeFailure, isNull);
    } finally {
      m.dispose();
    }
  }

  Future<(String, core.CredentialUseRequest)> request(
    List<core.FieldRef> fields,
  ) async {
    var c = await service.owner.createStringCredential(
      name: '合成凭据',
      publicPurpose: 'history lookup',
      secret: 'PRIVATE-MATERIAL',
    );
    c = await service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: 'history lookup',
      privateNote: 'PRIVATE-NOTE',
      suggestedBinding: 'GH_TOKEN',
      discoverable: true,
    );
    final session = service.agent.openSession('history chat');
    final r = await service.agent.requestCredentialUse(
      session,
      core.CredentialUseInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'credential history',
        'credentials': [
          {'alias': 'token', 'credentialId': c.id, 'version': c.version},
        ],
        'readFields': [for (final f in fields) f.toJson()],
        'launch': {
          'receiver': 'gh_token',
          'executable': Platform.resolvedExecutable,
          'argv': ['repo', '--help'],
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
    'SQLCipher mixed credential history resolves exact inbox link once, exposes retained operation and revokes both ranges',
    () async {
      final item = await service.owner.createInformation('合成资料', '', [
        const core.FieldInput('字段', '', 'PRIVATE-FIELD'),
      ]);
      final field = core.FieldRef(item.id, item.fields.single.id);
      final (session, r) = await request([field]);
      expect(
        (await source.grantHistory.query(const WorkspaceGrantQuery())).total,
        0,
      );
      await approve(r.id);
      expect(
        (await service.owner.informationHistory()).history.grants,
        isEmpty,
      );
      expect(
        (await service.owner.informationHistory(
          includeCredentialFields: true,
        )).history.grants,
        hasLength(1),
      );
      // A retained execution fixture exercises the history projection only; the
      // actual CLI/worker process was independently accepted in the installed App.
      await repo.commitCredentialRuntime(
        [
          repo.credentialUseRequests.single.changed({
            'executionId': 'retained-execution',
            'attemptedAt': now.toIso8601String(),
          }),
        ],
        [
          core.CredentialExecution(
            id: 'retained-execution',
            requestId: r.id,
            protocolVersion: 2,
            operationId: 'history-operation',
            operationFingerprint: 'sha256:${'a' * 64}',
            operationPlan: r.plan,
            createdAt: now,
            state: 'exited',
            processStarted: true,
            exitCode: 0,
            startedAt: now,
            finishedAt: now,
            cleanupState: 'not_needed',
          ),
        ],
      );
      final model = GrantHistoryController(
        source.grantHistory,
        source.approvals,
        const Stream.empty(),
      );
      try {
        await model.open('request:${r.id}');
        expect(model.readFailure, isNull);
        expect(
          model.results!.total,
          1,
        ); // The ordinary half must not duplicate it.
        expect(model.detail!.summary.kind, WorkspaceApprovalKind.credential);
        expect(model.detail!.scopes, hasLength(2));
        expect(model.detail!.summary.operationCount, 1);
        expect(model.linkedDecision, isTrue);
        expect(
          model.decision.detail!.executions.single.resultLabel,
          contains('退出码 0'),
        );
        expect(
          model.detail!.events.any(
            (e) =>
                e.id == 'execution:retained-execution' &&
                e.description.contains('history-operation') &&
                e.result.contains('退出码 0'),
          ),
          isTrue,
        );
        expect(model.canRevoke, isTrue);
        expect(
          (await source.grantHistory.query(
            const WorkspaceGrantQuery(kind: WorkspaceApprovalKind.information),
          )).total,
          0,
        );
        expect(
          (await source.grantHistory.query(
            const WorkspaceGrantQuery(
              kind: WorkspaceApprovalKind.credential,
              keyword: '合成凭据',
            ),
          )).total,
          1,
        );
        for (final secret in [
          'PRIVATE-MATERIAL',
          'PRIVATE-NOTE',
          'PRIVATE-FIELD',
        ]) {
          expect(
            (await source.grantHistory.query(
              WorkspaceGrantQuery(keyword: secret),
            )).total,
            0,
          );
          expect(
            jsonEncode(
              model.detail!.events
                  .map((e) => [e.description, e.result])
                  .toList(),
            ),
            isNot(contains(secret)),
          );
        }
        final credentialTarget = model.detail!.targets.singleWhere(
          (t) => t.record.kind == WorkspaceRecordKind.credential,
        );
        expect(credentialTarget.snapshotAvailable, isFalse);
        await expectLater(
          source.grantHistory.snapshot(
            model.selection!,
            credentialTarget.record,
          ),
          throwsA(isA<WorkspaceFailure>()),
        );
        final token = service.agent.claim(session, r.id).token;
        expect(await service.agent.read(token, field), 'PRIVATE-FIELD');
        now = now.add(const Duration(minutes: 121));
        await model.load();
        expect(
          model.detail!.summary.state,
          WorkspaceGrantState.partial,
          reason:
              'fieldExpiry=${service.owner.credentialUseRequests.single.fieldExpiresAt}; fieldState=${service.owner.credentialFieldGrantState(service.owner.credentialUseRequests.single)}; history=${model.detail!.scopes.map((s) => [s.kind.name, s.active, s.expiresAt]).toList()}',
        );
        expect(
          model.detail!.scopes.where((s) => s.active).single.kind,
          WorkspaceApprovalScopeKind.field,
        );
        expect(model.canRevoke, isTrue);
        await model.revoke();
        expect(model.decisionFailure, isNull);
        expect(model.detail!.summary.state, WorkspaceGrantState.revoked);
        expect(model.detail!.scopes.every((s) => !s.active), isTrue);
        await expectLater(
          service.agent.read(token, field),
          throwsA(isA<core.AccessFailure>()),
        );
      } finally {
        model.dispose();
      }
      await close();
      await open();
      final old = await source.grantHistory.read('request:${r.id}');
      expect(old.summary.state, WorkspaceGrantState.revoked);
      expect(
        old.events.any((e) => e.description.contains('history-operation')),
        isTrue,
      );
      expect(
        (await source.grantHistory.query(
          const WorkspaceGrantQuery(filter: WorkspaceGrantFilter.active),
        )).total,
        0,
      );
    },
  );

  test(
    'SQLCipher organization history links approved scopes, exact pre-change snapshot and the applied result, retaining facts after reopen',
    () async {
      final item = await service.owner.createInformation('整理对象', '', [
        const core.FieldInput('内容', '', 'PRIVATE-BODY'),
      ]);
      final session = service.agent.openSession('organization chat');
      final task = await service.agent.requestOrganization(
        session,
        'organize history',
        [item.id],
        agentName: 'Agent',
      );
      await approve(task.id);
      final model = GrantHistoryController(
        source.grantHistory,
        source.approvals,
        const Stream.empty(),
      );
      try {
        await model.open('request:${task.id}');
        expect(model.readFailure, isNull);
        expect(model.detail!.summary.kind, WorkspaceApprovalKind.organization);
        expect(model.detail!.summary.state, WorkspaceGrantState.active);
        expect(model.canRevoke, isTrue);
        await service.agent.submitOrganization(session, task.id, [
          core.OrganizationChange(
            itemId: item.id,
            baseVersion: item.version,
            directoryName: '合成目录',
            tagNames: ['合成标签'],
          ),
        ]);
        await model.load();
        expect(model.detail!.summary.state, WorkspaceGrantState.completed);
        expect(model.detail!.summary.operationCount, 1);
        expect(model.detail!.scopes.single.active, isFalse);
        expect(model.canRevoke, isFalse);
        final event = model.detail!.events.singleWhere(
          (e) => e.proposalId != null,
        );
        expect(event.proposalId, task.id);
        expect(
          (await source.proposals.read(
            event.proposalId!,
          )).organization!.outcome,
          WorkspaceOrganizationOutcome.applied,
        );
        final target = model.detail!.targets.single;
        expect(target.version, item.version);
        expect(target.snapshotAvailable, isTrue);
        expect(
          (await source.grantHistory.snapshot(
            model.selection!,
            target.record,
          )).detail.version,
          item.version,
        );
        expect(
          jsonEncode(
            model.detail!.events.map((e) => [e.description, e.result]).toList(),
          ),
          isNot(contains('PRIVATE-BODY')),
        );
        expect(
          (await source.grantHistory.query(
            const WorkspaceGrantQuery(
              kind: WorkspaceApprovalKind.organization,
              filter: WorkspaceGrantFilter.ended,
            ),
          )).total,
          1,
        );
        expect(
          (await source.grantHistory.query(
            const WorkspaceGrantQuery(keyword: 'PRIVATE-BODY'),
          )).total,
          0,
        );
      } finally {
        model.dispose();
      }
      await close();
      await open();
      final retained = await source.grantHistory.read('request:${task.id}');
      expect(retained.summary.state, WorkspaceGrantState.completed);
      expect(
        retained.events.singleWhere((e) => e.proposalId != null).proposalId,
        task.id,
      );
      expect(
        (await source.grantHistory.query(
          const WorkspaceGrantQuery(filter: WorkspaceGrantFilter.active),
        )).total,
        0,
      );
    },
  );
  test(
    'credential denials and ended sessions remain separate exact paged history entries after reopen',
    () async {
      final (session, active) = await request([]);
      await approve(active.id);
      service.agent.endSession(session);
      final (_, denied) = await request([]);
      final m = ApprovalsController(source.approvals, const Stream.empty());
      try {
        await m.open(denied.id);
        await m.decide(WorkspaceApprovalAction.deny);
        expect(m.writeFailure, isNull);
      } finally {
        m.dispose();
      }
      expect(
        (await source.grantHistory.read('request:${active.id}')).summary.state,
        WorkspaceGrantState.sessionEnded,
      );
      final denial = await source.grantHistory.read('request:${denied.id}');
      expect(denial.summary.state, WorkspaceGrantState.denied);
      expect(denial.scopes, isEmpty);
      final page = await source.grantHistory.query(
        const WorkspaceGrantQuery(
          kind: WorkspaceApprovalKind.credential,
          limit: 1,
        ),
        keepSelection: 'request:${denied.id}',
      );
      expect(page.total, 2);
      expect(page.selection, 'request:${denied.id}');
      expect(page.selectionIndex, isNotNull);
      await close();
      await open();
      expect(
        (await source.grantHistory.query(
          const WorkspaceGrantQuery(
            kind: WorkspaceApprovalKind.credential,
            filter: WorkspaceGrantFilter.ended,
          ),
        )).total,
        2,
      );
      expect(
        (await source.grantHistory.read('request:${denied.id}')).summary.state,
        WorkspaceGrantState.denied,
      );
      expect(
        (await source.grantHistory.read(
          'request:${active.id}',
        )).scopes.every((s) => !s.active),
        isTrue,
      );
    },
  );
}
