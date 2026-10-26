import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
const token = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'blinkokey');
const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const aliyun = WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun');

void main() {
  late SampleWorkspaceSource source;
  setUp(() => source = SampleWorkspaceSource());
  tearDown(() => source.dispose());
  Matcher failure(String code) =>
      isA<WorkspaceFailure>().having((e) => e.code, 'code', code);
  WorkspaceCredentialWrite edit(
    WorkspaceCredentialDetail detail,
    String op, {
    String? candidate,
    String? name,
    String? note,
    List<WorkspaceRecordRef>? links,
  }) => WorkspaceCredentialWrite(
    operationId: op,
    ref: detail.record.ref,
    expectedRecordVersion: detail.recordVersion,
    expectedMaterialVersion: detail.materialVersion,
    name: name ?? detail.record.name,
    purpose: detail.record.description,
    privateNote: note ?? detail.privateNote,
    binding: detail.binding,
    directoryId: detail.record.directoryId,
    tagIds: detail.record.tags.map((t) => t.id),
    candidateId: candidate,
    linkedInformation: links,
  );
  Future<WorkspaceCredentialUseDraft> request(
    WorkspaceRecordRef ref,
    String op,
  ) async {
    final detail = await source.credentials.read(ref);
    final receiver = (await source.credentials.receivers(ref)).single;
    final session = (await source.credentials.sessions()).first;
    return WorkspaceCredentialUseDraft(
      operationId: op,
      ref: ref,
      expectedRecordVersion: detail.recordVersion,
      expectedMaterialVersion: detail.materialVersion,
      useGeneration: detail.useGeneration,
      purpose: '核对虚构服务状态',
      receiverId: receiver.id,
      sessionId: session.id,
    );
  }

  test(
    'dedicated metadata/mask stay separate from generic values, file bytes and metadata search',
    () async {
      final initial = await source.credentials.read(ssh);
      expect(initial.form, WorkspaceCredentialForm.file);
      expect(initial.filename, 'azure-jp.pem');
      expect(initial.linkedInformation, contains(azure));
      expect(initial.mask, '••••••••');
      await source.credentials.save(
        edit(initial, 'private-note', note: '不公开的合成备注'),
      );
      expect((await source.credentials.read(ssh)).privateNote, '不公开的合成备注');
      expect((await source.readDetail(ssh)).values, isEmpty);
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: '不公开的合成备注'),
        )).total,
        0,
      );
      await expectLater(
        source.credentials.read(azure),
        throwsA(failure('unsupported')),
      );
      await expectLater(
        source.loadFileHistory(ssh, 'file'),
        throwsA(failure('unsupported')),
      );
      final focus = await source.credentials.read(
        const WorkspaceRecordRef(
          WorkspaceRecordKind.credential,
          'vikunja-password',
        ),
      );
      expect(focus.canRequestUse, isFalse);
      expect(focus.unavailableReason, contains('Mac'));
      final stored = await source.credentials.read(
        const WorkspaceRecordRef(WorkspaceRecordKind.credential, 'tgsession'),
      );
      expect(stored.delivery, WorkspaceCredentialDelivery.storage);
      expect(stored.canRequestUse, isFalse);
      expect(await source.credentials.history(stored.record.ref), isEmpty);
    },
  );

  test(
    'create validates core metadata budgets, preserves failed state and coalesces concurrent retries',
    () async {
      final input = WorkspaceCredentialWrite(
        operationId: 'new-token',
        candidateId: 'string-env',
        name: '新的测试凭据',
        binding: 'SERVICE_TOKEN',
        privateNote: '合成内容',
      );
      source.nextSaveFailure = const WorkspaceFailure('offline', '保存失败');
      await expectLater(
        source.credentials.save(input),
        throwsA(failure('offline')),
      );
      expect((await source.loadSummary()).records, 31);
      expect(await source.credentials.receipt('new-token'), isNull);
      final created = await Future.wait([
        source.credentials.save(input),
        source.credentials.save(input),
      ]);
      expect(created.first, created.last);
      expect((await source.loadSummary()).records, 32);
      final detail = await source.credentials.read(created.first.ref);
      expect(detail.materialVersion, 1);
      expect(detail.recordVersion, 1);
      for (final input in [
        WorkspaceCredentialWrite(
          operationId: 'too-long-name',
          candidateId: 'string-env',
          name: List.filled(61, '字').join(),
        ),
        WorkspaceCredentialWrite(
          operationId: 'bad-binding',
          candidateId: 'string-env',
          name: '错误引用',
          binding: 'BAD;echo',
        ),
        WorkspaceCredentialWrite(
          operationId: 'bad-target',
          candidateId: 'string-env',
          name: '错误关联',
          linkedInformation: [ssh],
        ),
        WorkspaceCredentialWrite(
          operationId: 'bad-candidate',
          candidateId: '/private/key.pem',
          name: '错误材料',
        ),
      ]) {
        await expectLater(
          source.credentials.save(input),
          throwsA(failure('validation')),
        );
      }
      expect((await source.loadSummary()).records, 32);
      await expectLater(
        source.credentials.save(
          edit(detail, 'form-mismatch', candidate: 'ssh-file'),
        ),
        throwsA(failure('form_mismatch')),
      );
      expect(
        (await source.credentials.read(detail.record.ref)).recordVersion,
        1,
      );
    },
  );

  test(
    'material versions, revisions and use generations are distinct; disabled rotation does not enable or revive requests',
    () async {
      final initial = await source.credentials.read(token);
      final pending = await source.credentials.requestUse(
        await request(token, 'use-before'),
      );
      expect(pending.requestId, isNotNull);
      expect((await source.loadSummary()).pending, 6);
      final changed = await source.credentials.save(
        edit(initial, 'metadata', name: '改名后的Token'),
      );
      expect(changed.materialVersion, 1);
      final metadata = await source.credentials.read(token);
      expect(metadata.recordVersion, 2);
      expect(metadata.useGeneration, initial.useGeneration);
      expect(
        (await source.credentials.requests(ref: token)).single.state,
        WorkspaceCredentialRequestState.pending,
      );
      final oldHistory = (await source.credentials.history(token)).single;
      await source.credentials.setEnabled(
        WorkspaceCredentialToggle(
          operationId: 'disable',
          ref: token,
          expectedRecordVersion: metadata.recordVersion,
          expectedMaterialVersion: metadata.materialVersion,
          enabled: false,
        ),
      );
      final disabled = await source.credentials.read(token);
      expect(disabled.enabled, isFalse);
      expect(disabled.materialVersion, 1);
      expect(
        (await source.credentials.requests(ref: token)).single.state,
        WorkspaceCredentialRequestState.disabled,
      );
      expect((await source.loadSummary()).pending, 5);
      await source.credentials.save(
        edit(disabled, 'rotate-disabled', candidate: 'string-env'),
      );
      final rotated = await source.credentials.read(token);
      expect(rotated.enabled, isFalse);
      expect(rotated.materialVersion, 2);
      expect(rotated.recordVersion, 4);
      expect(rotated.useGeneration, disabled.useGeneration + 1);
      await source.credentials.setEnabled(
        WorkspaceCredentialToggle(
          operationId: 'enable',
          ref: token,
          expectedRecordVersion: rotated.recordVersion,
          expectedMaterialVersion: 2,
          enabled: true,
        ),
      );
      expect(
        (await source.credentials.requests(ref: token)).single.state,
        WorkspaceCredentialRequestState.disabled,
      );
      expect((await source.credentials.history(token)).single, oldHistory);
      expect(oldHistory.credentialName, initial.record.name);
      expect(oldHistory.operations, hasLength(2));
      await expectLater(
        source.credentials.save(edit(initial, 'stale')),
        throwsA(failure('conflict')),
      );
    },
  );

  test(
    'credential links have one fact across both directions, neighbor revisions and ordinary history restore',
    () async {
      final oldAzure = await source.readDetail(azure),
          oldAliyun = await source.readDetail(aliyun);
      final credential = await source.credentials.read(ssh);
      await source.credentials.save(
        edit(credential, 'move-link', links: [aliyun]),
      );
      final afterAzure = await source.readDetail(azure),
          afterAliyun = await source.readDetail(aliyun);
      expect(afterAzure.relations['credentials'], isNot(contains(ssh)));
      expect(afterAliyun.relations['credentials'], contains(ssh));
      expect(afterAzure.version, oldAzure.version + 1);
      expect(afterAliyun.version, oldAliyun.version + 1);
      expect((await source.credentials.read(ssh)).linkedInformation, [aliyun]);
      final restore = await source.previewRevision(
        azure,
        oldAzure.version,
        expectedVersion: afterAzure.version,
      );
      await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore-link',
          action: WorkspaceRecordAction.restoreRevision,
          ref: azure,
          expectedVersion: afterAzure.version,
          revisionVersion: oldAzure.version,
          expectedCatalogVersion: restore.catalogVersion,
        ),
      );
      expect((await source.credentials.read(ssh)).linkedInformation.toSet(), {
        azure,
        aliyun,
      });
      final currentAzure = await source.readDetail(azure),
          currentCredential = await source.credentials.read(ssh);
      final saved = await source.saveRecord(
        WorkspaceEdit(
          operationId: 'unlink-info',
          record: currentAzure.record,
          expectedVersion: currentAzure.version,
          values: {},
          relations: {'credentials': []},
        ),
      );
      expect(saved, isA<WorkspaceSaved>());
      expect((await source.credentials.read(ssh)).linkedInformation, [aliyun]);
      await expectLater(
        source.credentials.save(edit(currentCredential, 'stale-after-reverse')),
        throwsA(failure('conflict')),
      );
      final generic = await source.readDetail(ssh);
      final blocked =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'forged-credential-link',
                  record: generic.record,
                  expectedVersion: generic.version,
                  values: {},
                  relations: {
                    'related': [azure],
                  },
                ),
              )
              as WorkspaceRejected;
      expect(blocked.failure.code, 'unsupported');
    },
  );

  test(
    'pending use requests are snapshots, idempotent and never become an execution or grant',
    () async {
      final input = await request(ssh, 'request-ssh');
      final before = await source.credentials.read(ssh);
      final receipts = await Future.wait([
        source.credentials.requestUse(input),
        source.credentials.requestUse(input),
      ]);
      expect(receipts.first, receipts.last);
      expect(await source.credentials.requests(), hasLength(1));
      final pending = (await source.credentials.requests()).single;
      expect(pending.state, WorkspaceCredentialRequestState.pending);
      expect(pending.materialVersion, before.materialVersion);
      expect(pending.receiver.executable, '/usr/bin/ssh');
      expect(pending.receiver.arguments, contains('{{SSH_KEY_FILE}}'));
      expect(pending.session.agentClaim, contains('自述'));
      expect(pending.minutes, 15);
      final history = await source.credentials.history(ssh);
      expect(history.single.operations, hasLength(2));
      await source.credentials.save(
        edit(before, 'replace-after-request', candidate: 'ssh-file'),
      );
      expect(
        (await source.credentials.requests()).single.state,
        WorkspaceCredentialRequestState.superseded,
      );
      expect(pending.state, WorkspaceCredentialRequestState.pending);
      expect((await source.credentials.history(ssh)).single, history.single);
      source.setScenario(SampleWorkspaceScenario.failure);
      await expectLater(
        source.credentials.receipt(input.operationId),
        throwsA(isA<WorkspaceFailure>()),
      );
    },
  );

  test(
    'reset and a write from empty restore only intentional state, with no phantom pending requests',
    () async {
      source.setScenario(SampleWorkspaceScenario.empty);
      final created = await source.credentials.save(
        WorkspaceCredentialWrite(
          operationId: 'empty-new',
          candidateId: 'string-env',
          name: '空资料库中的凭据',
        ),
      );
      final summary = await source.loadSummary();
      expect(summary.records, 1);
      expect(summary.pending, 0);
      expect(summary.proposals, 0);
      await source.credentials.requestUse(
        await request(created.ref, 'empty-use'),
      );
      expect((await source.loadSummary()).pending, 1);
      source.reset();
      expect((await source.loadSummary()).records, 31);
      expect((await source.loadSummary()).pending, 5);
      expect(await source.credentials.requests(), isEmpty);
      await expectLater(
        source.credentials.read(created.ref),
        throwsA(failure('not_found')),
      );
      expect(
        (await source.credentials.read(ssh)).linkedInformation,
        contains(azure),
      );
    },
  );

  test(
    'typed owner links do not confuse colliding information and credential identifiers',
    () async {
      final data = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
      final rows = (data['records'] as List).cast<Map<String, dynamic>>();
      final info = rows.firstWhere((r) => r['id'] == 'azure'),
          credential = rows.firstWhere((r) => r['id'] == 'sshkey');
      credential['id'] = 'azure';
      credential['owner'] = 'azure';
      credential['relations'] = {};
      info['relations'] = {
        'credentials': [
          {'kind': 'credential', 'id': 'azure'},
        ],
      };
      data['records'] = [info, credential];
      data['trash'] = [];
      await source.replaceFixture(jsonEncode(data));
      final ref = const WorkspaceRecordRef(
        WorkspaceRecordKind.credential,
        'azure',
      );
      expect((await source.credentials.read(ref)).linkedInformation, [azure]);
      expect((await source.readDetail(azure)).relations['credentials'], [ref]);
      expect((await source.readDetail(ref)).values, isEmpty);
    },
  );
}
