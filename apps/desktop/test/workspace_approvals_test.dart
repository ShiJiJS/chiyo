import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/workspace_entries.dart';

WorkspaceApprovalChange decision(
  WorkspaceApprovalDetail d, {
  String? operation,
  WorkspaceApprovalAction action = WorkspaceApprovalAction.approve,
  Iterable<String>? selected,
  Map<String, int> files = const {},
  int fields = 30,
  int credential = 15,
}) => WorkspaceApprovalChange(
  operationId: operation ?? workspaceOperationId(),
  requestId: d.request.id,
  reviewToken: d.reviewToken,
  action: action,
  selected:
      selected ??
      d.scopes.where((x) => x.requested && x.available).map((x) => x.id),
  fileVersions: files,
  fieldMinutes: fields,
  credentialMinutes: credential,
);

void main() {
  Matcher failure(String code) =>
      isA<WorkspaceFailure>().having((e) => e.code, 'code', code);
  SampleWorkspaceSource source() =>
      SampleWorkspaceSource(readAsset: (p) => File(p).readAsBytes());
  const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
  const profile = WorkspaceRecordRef(
    WorkspaceRecordKind.information,
    'profile',
  );
  test(
    'one inbox supplies pending totals, query intersections, deterministic pagination and terminal readback',
    () async {
      final s = source();
      addTearDown(s.dispose);
      final q = await s.approvals.query(const WorkspaceApprovalQuery(limit: 2));
      expect(q.total, 5);
      expect(q.pending, 5);
      expect((await s.loadSummary()).pending, 5);
      final next = await s.approvals.query(
        const WorkspaceApprovalQuery(limit: 2, offset: 2),
        keepSelection: 'token',
      );
      expect(next.selection, 'token');
      expect(next.selectionIndex, 2);
      final d = await s.approvals.read('server');
      final command = decision(
        d,
        action: WorkspaceApprovalAction.deny,
        selected: const [],
      );
      final a = await s.approvals.change(command),
          b = await s.approvals.change(command);
      expect(identical(a, b), true);
      expect(a.commandDigest, command.digest);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.denied,
      );
      expect((await s.loadSummary()).pending, 4);
      expect(
        (await s.approvals.query(
          const WorkspaceApprovalQuery(
            filter: WorkspaceApprovalFilter.done,
            keyword: '代理',
          ),
        )).items.single.id,
        'server',
      );
      await expectLater(
        s.approvals.change(decision(d)),
        throwsA(failure('conflict')),
      );
    },
  );
  test(
    'mixed request approves only selected fields and never implicitly approves its credential',
    () async {
      final s = source();
      addTearDown(s.dispose);
      final d = await s.approvals.read('server'),
          fields = d.scopes
              .where((x) => x.kind == WorkspaceApprovalScopeKind.field)
              .toList();
      expect(fields.length, 3);
      await s.approvals.change(decision(d, selected: [fields.first.id]));
      final after = await s.approvals.read('server');
      expect(after.approved, {fields.first.id});
      expect(after.fileVersions, isEmpty);
      expect(
        after.scopes
            .where((x) => x.kind == WorkspaceApprovalScopeKind.credential)
            .single
            .available,
        false,
      );
      expect(await s.credentials.history(ssh), hasLength(1));
      expect(
        after.fieldExpiresAt!.difference(after.decidedAt!),
        const Duration(minutes: 30),
      );
      final created = await s.createRecord(
        WorkspaceCreate(
          operationId: 'unrelated-new-record',
          typeId: 'generic',
          name: '新增资料',
          values: const {'body': '未批准'},
        ),
      );
      expect(created, isA<WorkspaceSaved>());
      expect((await s.approvals.read('server')).approved, {fields.first.id});
    },
  );
  test(
    'dynamic credential request shares approval state/history and independent fixed lifetimes',
    () async {
      final s = source();
      addTearDown(s.dispose);
      final c = await s.credentials.read(ssh),
          receiver = (await s.credentials.receivers(ssh)).first,
          session = (await s.credentials.sessions()).first;
      final receipt = await s.credentials.requestUse(
        WorkspaceCredentialUseDraft(
          operationId: 'from-u03',
          ref: ssh,
          expectedRecordVersion: c.recordVersion,
          expectedMaterialVersion: c.materialVersion,
          useGeneration: c.useGeneration,
          purpose: '核对服务状态',
          receiverId: receiver.id,
          sessionId: session.id,
        ),
      );
      expect((await s.loadSummary()).pending, 6);
      final d = await s.approvals.read('credential:${receipt.requestId}');
      expect(d.credential!.receiver.arguments, receiver.arguments);
      await s.approvals.change(decision(d));
      expect(
        (await s.credentials.requests())
            .singleWhere((r) => r.id == receipt.requestId)
            .state,
        WorkspaceCredentialRequestState.approved,
      );
      final history = await s.credentials.history(ssh);
      expect(history, hasLength(2));
      expect(history.last.operations, isEmpty);
      expect(history.last.state, '有效');
      s.advanceApprovalClock(const Duration(minutes: 16));
      expect(
        (await s.credentials.requests())
            .singleWhere((r) => r.id == receipt.requestId)
            .state,
        WorkspaceCredentialRequestState.expired,
      );
      expect((await s.credentials.history(ssh)).last.state, '已到期');
      expect(
        (await s.approvals.read(d.request.id)).credentialExpiresAt,
        d.credentialExpiresAt ?? history.last.expiresAt,
      );
    },
  );
  test(
    'ordinary file pins its exact retained version and entry selection fixes individual leaf identities',
    () async {
      final reads = <String>[],
          s = SampleWorkspaceSource(
            readAsset: (p) {
              reads.add(p);
              return File(p).readAsBytes();
            },
          );
      addTearDown(s.dispose);
      final d = await s.approvals.read('resume'),
          file = d.scopes.singleWhere(
            (x) => x.kind == WorkspaceApprovalScopeKind.file,
          ),
          leaves = d.scopes.where((x) => x.section.contains('教育经历 1')).toList();
      expect(file.fileVersions, hasLength(2));
      expect(leaves, hasLength(3));
      final selected = [file.id, leaves.first.id];
      await s.approvals.change(
        decision(d, selected: selected, files: {file.id: 1}),
      );
      expect(reads.every((p) => p.endsWith('manifest.json')), true);
      final old = await s.readDetail(profile),
          entries = WorkspaceRepeatedEntry.read(old.values['education']);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'new-entry',
          expectedVersion: old.version,
          record: old.record,
          values: {
            'education': [
              ...entries.map((e) => e.toJson()),
              WorkspaceRepeatedEntry.empty().toJson(),
            ],
          },
        ),
      );
      final after = await s.approvals.read('resume');
      expect(after.approved, selected.toSet());
      expect(after.fileVersions[file.id], 1);
      expect(
        after.scopes
            .where((x) => x.section.contains('教育经历 3'))
            .every((x) => !after.approved.contains(x.id)),
        true,
      );
      expect(after.request.state, WorkspaceApprovalState.approved);
    },
  );
  test(
    'expiry/session/revoke and Mac fill unsupported states never mint use operations or alter records',
    () async {
      final s = source();
      addTearDown(s.dispose);
      final fill = await s.approvals.read('fill');
      expect(fill.canApprove, false);
      await expectLater(
        s.approvals.change(decision(fill)),
        throwsA(failure('unsupported')),
      );
      final org = await s.approvals.read('organize'),
          before = await s.readDetail(org.scopes.first.record);
      await expectLater(
        s.approvals.change(decision(org, fields: 60)),
        throwsA(failure('validation')),
      );
      await s.approvals.change(decision(org));
      expect((await s.readDetail(before.record.ref)).values, before.values);
      final approved = await s.approvals.read('organize');
      await s.approvals.change(
        decision(
          approved,
          action: WorkspaceApprovalAction.revoke,
          selected: const [],
        ),
      );
      expect(
        (await s.approvals.read('organize')).request.state,
        WorkspaceApprovalState.revoked,
      );
      s.endApprovalSession('session-maintenance');
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.sessionEnded,
      );
      s.reset();
      s.advanceApprovalClock(const Duration(hours: 1));
      expect((await s.loadSummary()).pending, 0);
      expect(
        (await s.approvals.read('server')).request.state,
        WorkspaceApprovalState.expired,
      );
    },
  );
  test(
    'conflict and lost reply preserve one decision; wrong operations and stale scopes cannot replay it',
    () async {
      final s = source();
      addTearDown(s.dispose);
      final d = await s.approvals.read('server');
      s.loseNextApprovalReply = true;
      final c = decision(d);
      await expectLater(
        s.approvals.change(c),
        throwsA(failure('unknown_outcome')),
      );
      final receipt = (await s.approvals.receipt(c.operationId))!;
      expect(receipt.commandDigest, c.digest);
      expect((await s.approvals.read('server')).approved, c.selected.toSet());
      expect(await s.approvals.change(c), same(receipt));
      await expectLater(
        s.approvals.change(
          decision(d, operation: c.operationId, selected: const []),
        ),
        throwsA(failure('operation_conflict')),
      );
      s.setScenario(SampleWorkspaceScenario.failure);
      await expectLater(
        s.approvals.receipt(c.operationId),
        throwsA(isA<WorkspaceFailure>()),
      );
      s.setScenario(SampleWorkspaceScenario.ready);
      expect(await s.approvals.receipt(c.operationId), same(receipt));
      s.reset();
      expect(await s.approvals.receipt(c.operationId), isNull);
      await expectLater(s.approvals.change(c), throwsA(failure('conflict')));
    },
  );
}
