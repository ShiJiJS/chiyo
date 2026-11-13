import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late MemoryInformationRepository repo;
  late InformationService service;
  late CredentialUseBatch request;
  late CredentialProgramOperation initial;
  final at = DateTime.utc(2026, 11, 14);
  const job = 'macos:AgentInfoRuntime-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  setUp(() async {
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo, clock: () => at);
    var c = await service.owner.createStringCredential(
      name: 'Synthetic service',
      publicPurpose: '',
      secret: 'NEVER-OPERATION-OUTPUT',
    );
    c = await service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: '',
      privateNote: '',
      suggestedBinding: 'TOKEN',
      discoverable: true,
    );
    final plan =
        CredentialProgramPlan.fromJson({
          'executable': '/device/tool',
          'cwd': '/device/work',
          'argv': ['query'],
          'env': {
            'TOKEN': {'credentialId': c.id, 'version': 1},
          },
        }, allowPortablePaths: true).resolved(
          ExecutableIdentity('/device/tool', 100, 1, 'sha256:${'a' * 64}'),
          '/device/work',
        );
    final session = service.agent.openSession('Synthetic operation metadata');
    request = await service.agent.requestCredentialBatch(
      session,
      'A' * 22,
      CredentialBatchInput.forProgram(plan, purpose: 'Synthetic query'),
      operationId: 'submit',
    );
    request = await service.owner.decideCredentialBatch(
      request.id,
      operationId: 'approve',
      revision: 1,
      approvedItems: ['b1'],
    );
    initial = CredentialProgramOperation(
      sessionBinding: request.sessionBinding,
      deviceId: request.deviceId,
      plan: plan,
      itemIds: ['b1'],
      progress: CredentialExecution(
        id: 'synthetic-execution',
        requestId: request.id,
        protocolVersion: 2,
        operationId: 'program-use',
        operationFingerprint: plan.planHash,
        createdAt: at,
        jobName: job,
      ),
    );
  });
  tearDown(() => service.close());
  Future<void> save(
    CredentialProgramOperation op,
    int revision, {
    int? requestRevision,
  }) => repo.commitCredentialProgramOperation(
    op,
    expectedRevision: revision,
    requestRevision: requestRevision ?? request.revision,
    validate: () {},
  );

  test(
    'program metadata advances one original process beyond the short fill deadline and exact reports are queries',
    () async {
      await save(initial, 0);
      final runningReport = CredentialExecutionReport(
        executionId: initial.id,
        executionCapability: 'private-report-only',
        state: 'running',
        pid: 12,
        processCreatedAt: 'synthetic-pid-identity',
        startedAt: at,
        jobName: job,
      );
      final running = initial.withReport(runningReport);
      await save(running, 1);
      expect(identical(running.withReport(runningReport), running), true);
      final ended = running.withReport(
        CredentialExecutionReport(
          executionId: initial.id,
          executionCapability: 'private-report-only',
          state: 'exited',
          pid: 12,
          processCreatedAt: 'synthetic-pid-identity',
          startedAt: at,
          finishedAt: at.add(const Duration(hours: 3)),
          exitCode: 0,
          jobName: job,
        ),
      );
      await save(ended, 2);
      expect(repo.credentialProgramOperations.single.id, initial.id);
      expect(repo.credentialProgramOperations.single.progress.state, 'exited');
      expect(repo.credentialProgramOperations.single.progress.exitCode, 0);
      final output = jsonEncode(ended.toPublicJson());
      for (final hidden in [
        'sessionBinding',
        'deviceId',
        'materialLease',
        'pid',
        'jobName',
        'private-report-only',
        'NEVER-OPERATION-OUTPUT',
      ]) {
        expect(output, isNot(contains(hidden)));
      }
      expect(ended.toPublicJson()['protocolVersion'], 3);
      expect(ended.toPublicJson()['operationId'], 'program-use');
      await expectLater(save(initial, 0), throwsA(isA<CredentialUseFailure>()));
      expect(repo.credentialProgramOperations, hasLength(1));
    },
  );

  test(
    'CAS, receiver identity and immutable execution facts prevent stale or substituted writes',
    () async {
      await expectLater(
        save(initial, 0, requestRevision: 1),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(repo.credentialProgramOperations, isEmpty);
      await save(initial, 0);
      final forged = initial.withProgress(
        initial.progress.changed({
          'operationFingerprint': 'sha256:${'b' * 64}',
        }),
      );
      await expectLater(save(forged, 1), throwsA(isA<CredentialUseFailure>()));
      final wrongTarget = CredentialProgramOperation(
        sessionBinding: initial.sessionBinding,
        deviceId: initial.deviceId,
        progress: initial.progress,
        plan: initial.plan,
        itemIds: ['b2'],
      );
      await expectLater(
        save(wrongTarget, 0),
        throwsA(isA<CredentialUseFailure>()),
      );
      final leaked =
          jsonDecode(jsonEncode(initial.toStorageJson()))
              as Map<String, dynamic>;
      (leaked['progress'] as Map)['materialBase64'] = 'forbidden';
      expect(
        () => CredentialProgramOperation.fromStorageJson(leaked),
        throwsA(isA<CredentialUseFailure>()),
      );
      final malformed =
          jsonDecode(jsonEncode(initial.toStorageJson()))
              as Map<String, dynamic>;
      (malformed['progress'] as Map)['pid'] = 12;
      expect(
        () => CredentialProgramOperation.fromStorageJson(malformed),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(repo.credentialProgramOperations.single.revision, 1);
    },
  );

  test(
    'archiving drops device cleanup identities and cannot restore authority or accept another report',
    () async {
      final running = initial.withReport(
        CredentialExecutionReport(
          executionId: initial.id,
          executionCapability: 'private-report-only',
          state: 'running',
          pid: 12,
          processCreatedAt: 'synthetic-pid-identity',
          startedAt: at,
          jobName: job,
        ),
      );
      final archived = CredentialProgramOperation.fromStorageJson(
        Map<String, dynamic>.from(running.toArchiveJson()),
      );
      expect(archived.archived, true);
      expect(archived.progress.state, 'unknown');
      expect(archived.progress.processStarted, true);
      expect(archived.progress.pid, null);
      expect(archived.progress.jobName, null);
      expect(archived.toPublicJson()['fromBackup'], true);
      expect(
        () => archived.withReport(
          CredentialExecutionReport(
            executionId: initial.id,
            executionCapability: 'anything',
            state: 'exited',
            exitCode: 0,
            finishedAt: at,
          ),
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      await expectLater(
        save(archived, 0),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(repo.credentialProgramOperations, isEmpty);
    },
  );
}
