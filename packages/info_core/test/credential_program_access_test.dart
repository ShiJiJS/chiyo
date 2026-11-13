import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class Fixture {
  DateTime now = DateTime.utc(2026, 11, 14);
  late MemoryInformationRepository repo;
  late InformationService service;
  late String session;
  late CredentialUseBatch request;
  late ManagedCredential password, token, file;
  static const device = 'AAAAAAAAAAAAAAAAAAAAAA';
  final identity = ExecutableIdentity(
    '/device/business-tool',
    100,
    1,
    'sha256:${'a' * 64}',
  );
  Future<ManagedCredential> discover(ManagedCredential c) =>
      service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'password',
        discoverable: true,
      );
  Future<void> open() async {
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo, clock: () => now);
    password = await discover(
      await service.owner.createStringCredential(
        name: 'Synthetic DB',
        publicPurpose: '',
        secret: 'TEST_PRIVATE_DB',
      ),
    );
    token = await discover(
      await service.owner.createStringCredential(
        name: 'Synthetic Token',
        publicPurpose: '',
        secret: 'TEST_PRIVATE_TOKEN',
      ),
    );
    file = await discover(
      await service.owner.createFileCredential(
        name: 'Synthetic Key',
        publicPurpose: '',
        fileName: 'client.key',
        bytes: utf8.encode('TEST_PRIVATE_FILE'),
      ),
    );
    session = service.agent.openSession('Synthetic program access');
    request = await service.agent.requestCredentialBatch(
      session,
      device,
      CredentialBatchInput.forProgram(
        plan().resolved(identity, '/device/work'),
        purpose: 'Use synthetic service',
      ),
      operationId: 'submit-program',
    );
  }

  CredentialProgramPlan plan({
    bool onlyPassword = false,
    bool onlyToken = false,
  }) => CredentialProgramPlan.fromJson({
    'executable': identity.path,
    'cwd': '/device/work',
    'argv': onlyPassword || onlyToken
        ? <Object?>[]
        : [
            'sync',
            {
              'file': {'credentialId': file.id},
            },
          ],
    'env': {
      if (!onlyToken) 'DB_PASSWORD': {'credentialId': password.id},
      if (!onlyPassword) 'SERVICE_TOKEN': {'credentialId': token.id},
    },
    if (!onlyPassword && !onlyToken) 'stdin': {'credentialId': password.id},
  }, allowPortablePaths: true);
  DeviceCredentialLaunch prepared(CredentialProgramPlan plan) =>
      DeviceCredentialLaunch.fromPrivateJson({
        'version': 1,
        'planHash': plan.planHash,
        'executable': identity.toJson(),
        'cwd': plan.cwd,
      });
  Future<void> approve([
    List<String> items = const ['b1', 'b2', 'b3', 'b4'],
  ]) async {
    request = await service.owner.decideCredentialBatch(
      request.id,
      operationId: 'approve-program',
      revision: 1,
      approvedItems: items,
    );
  }

  String job(String operation) =>
      'macos:AgentInfoRuntime-${operation.replaceAll('-', 'A').padRight(32, 'A').substring(0, 32)}';
  Future<CredentialProgramClaim> begin(
    String operation, {
    CredentialProgramPlan? launch,
    String? device,
    String? session,
    String? jobName,
  }) {
    final p = launch ?? plan();
    return service.agent.beginCredentialProgramOperation(
      session ?? this.session,
      device ?? Fixture.device,
      request.id,
      p,
      prepared(p),
      jobName ?? job(operation),
      operationId: operation,
    );
  }
}

Matcher failure(String code) =>
    isA<CredentialUseFailure>().having((e) => e.code, 'code', code);

void main() {
  late Fixture f;
  setUp(() async {
    f = Fixture();
    await f.open();
  });
  tearDown(() => f.service.close());

  test(
    'all required approvals precede material delivery; an independent approved subset may launch alone',
    () async {
      await f.approve(['b2']);
      await expectLater(
        f.begin('requires-all'),
        throwsA(failure('scope_not_approved')),
      );
      expect(f.repo.credentialProgramOperations, isEmpty);
      final claim = await f.begin(
        'only-db',
        launch: f.plan(onlyPassword: true),
      );
      expect(claim.operation.itemIds, ['b2']);
      expect(claim.material!.materials.keys, ['b2']);
      expect(claim.material!.materials['b2']!.stringValue, 'TEST_PRIVATE_DB');
      expect(
        f.repo.credentialProgramOperations.single.progress.state,
        'preparing',
      );
      final parsed = CredentialProgramMaterial.fromPrivateJson(
        Map<String, dynamic>.from(claim.material!.toPrivateJson()),
      );
      expect(parsed.itemIds, ['b2']);
      expect(parsed.materials['b2']!.stringValue, 'TEST_PRIVATE_DB');
      expect(
        jsonEncode(claim.toPublicJson()),
        isNot(contains('TEST_PRIVATE_DB')),
      );
      expect(
        jsonEncode(claim.toPublicJson()),
        isNot(contains('executionCapability')),
      );
      expect(claim.material.toString(), isNot(contains('TEST_PRIVATE_DB')));
    },
  );

  test(
    'one multi receiver claim contains exact original bytes, duplicate IDs issue no more material and changed plans conflict',
    () async {
      await f.approve();
      final first = await f.begin('start-many');
      final material = first.material!;
      expect(material.itemIds, ['b1', 'b2', 'b3', 'b4']);
      expect(material.materials['b1']!.form, CredentialForm.file);
      expect(material.materials['b1']!.bytes, utf8.encode('TEST_PRIVATE_FILE'));
      expect(material.materials['b2']!.bytes, material.materials['b4']!.bytes);
      expect((await f.begin('start-many')).material, null);
      await expectLater(
        f.begin('start-many', launch: f.plan(onlyPassword: true)),
        throwsA(failure('operation_conflict')),
      );
      await expectLater(
        f.begin('second-job', jobName: f.job('start-many')),
        throwsA(failure('invalid_plan')),
      );
      final bad =
          jsonDecode(jsonEncode(material.toPrivateJson()))
              as Map<String, dynamic>;
      ((bad['materials'] as Map)['b2'] as Map)['credentialId'] = f.token.id;
      expect(
        () => CredentialProgramMaterial.fromPrivateJson(bad),
        throwsA(failure('invalid_reference')),
      );
      final changed =
          jsonDecode(jsonEncode(material.toPrivateJson()))
              as Map<String, dynamic>;
      ((changed['materials'] as Map)['b2'] as Map)['bytesBase64'] =
          base64Encode(List.filled(65537, 65));
      expect(
        () => CredentialProgramMaterial.fromPrivateJson(changed),
        throwsA(failure('invalid_reference')),
      );
      expect(f.repo.credentialProgramOperations, hasLength(1));
    },
  );

  test(
    'original chat and device own the claim and it cannot move a material to another receiver',
    () async {
      await f.approve();
      final stranger = f.service.agent.openSession('Same visible name');
      await expectLater(
        f.begin('wrong-chat', session: stranger),
        throwsA(failure('session_mismatch')),
      );
      await expectLater(
        f.begin('wrong-device', device: 'B' * 22),
        throwsA(failure('session_mismatch')),
      );
      final bad = CredentialProgramPlan.fromJson({
        'executable': f.identity.path,
        'cwd': '/device/work',
        'argv': <Object?>[],
        'env': {
          'OTHER_PASSWORD': {'credentialId': f.password.id},
        },
      }, allowPortablePaths: true);
      await expectLater(
        f.begin('different-receiver', launch: bad),
        throwsA(failure('scope_not_approved')),
      );
      final claim = await f.begin('original');
      expect(
        () => f.service.agent.credentialProgramOperationStatus(
          stranger,
          Fixture.device,
          'original',
        ),
        throwsA(failure('invalid_reference')),
      );
      expect(
        () => f.service.agent.authorizeCredentialProgramStart(
          'B' * 22,
          claim.operation.id,
          claim.material!.executionCapability,
        ),
        throwsA(failure('session_mismatch')),
      );
      expect(
        f.service.agent.showOwnOperation(f.session, 'original')['kind'],
        'credential-program',
      );
      expect(f.service.agent.queryOwnOperations(stranger)['records'], isEmpty);
    },
  );

  test(
    'credential changes or revocation after claim block the start without reissuing material',
    () async {
      await f.approve();
      final a = await f.begin('token-only', launch: f.plan(onlyToken: true));
      final b = await f.begin('db-only', launch: f.plan(onlyPassword: true));
      await f.service.owner.revokeCredentialBatch(
        f.request.id,
        operationId: 'revoke-db',
        revision: f.request.revision,
        itemIds: ['b2'],
      );
      expect(
        () => f.service.agent.authorizeCredentialProgramStart(
          Fixture.device,
          b.operation.id,
          b.material!.executionCapability,
        ),
        throwsA(failure('scope_not_approved')),
      );
      expect(
        () => f.service.agent.authorizeCredentialProgramStart(
          Fixture.device,
          a.operation.id,
          a.material!.executionCapability,
        ),
        returnsNormally,
      );
      expect(
        (await f.begin('db-only', launch: f.plan(onlyPassword: true))).material,
        null,
      );
      await f.service.owner.setCredentialEnabled(
        f.token.id,
        f.token.revision,
        false,
      );
      expect(
        () => f.service.agent.authorizeCredentialProgramStart(
          Fixture.device,
          a.operation.id,
          a.material!.executionCapability,
        ),
        throwsA(failure('credential_disabled')),
      );
    },
  );

  test(
    'fixed material registry and worker registration precede start; a running process is not limited to 30 seconds',
    () async {
      await f.approve();
      final claim = await f.begin('long-program'),
          cap = claim.material!.executionCapability,
          id = claim.operation.id;
      await expectLater(
        f.service.agent.registerCredentialProgramWorker(
          Fixture.device,
          id,
          cap,
          123,
          'worker-creation',
        ),
        throwsA(failure('invalid_plan')),
      );
      await expectLater(
        f.service.agent.registerCredentialProgramMaterials(
          Fixture.device,
          id,
          cap,
          CredentialMaterialLease('/device/private', 'folder-id', {
            'wrong.bin': 'file-id',
          }),
        ),
        throwsA(failure('invalid_reference')),
      );
      final lease = CredentialMaterialLease('/device/private', 'folder-id', {
        'credential-b1.bin': 'file-id',
      });
      await f.service.agent.registerCredentialProgramMaterials(
        Fixture.device,
        id,
        cap,
        lease,
      );
      await f.service.agent.registerCredentialProgramMaterials(
        Fixture.device,
        id,
        cap,
        lease,
      );
      await f.service.agent.registerCredentialProgramWorker(
        Fixture.device,
        id,
        cap,
        123,
        'worker-creation',
      );
      await f.service.agent.registerCredentialProgramWorker(
        Fixture.device,
        id,
        cap,
        123,
        'worker-creation',
      );
      final running = CredentialExecutionReport(
        executionId: id,
        executionCapability: cap,
        state: 'running',
        pid: 456,
        processCreatedAt: 'target-creation',
        startedAt: f.now,
        jobName: f.job('long-program'),
      );
      await f.service.agent.reportCredentialProgramExecution(
        Fixture.device,
        running,
      );
      f.now = f.now.add(const Duration(hours: 3));
      expect(
        f.service.agent.credentialProgramOperationStatus(
          f.session,
          Fixture.device,
          'long-program',
        )['executionState'],
        'running',
      );
      await expectLater(
        f.service.agent.acknowledgeCredentialProgramCleanup(
          Fixture.device,
          id,
          cap,
          treeEnded: true,
        ),
        throwsA(failure('cleanup_busy')),
      );
      final ended = CredentialExecutionReport(
        executionId: id,
        executionCapability: cap,
        state: 'exited',
        pid: 456,
        processCreatedAt: 'target-creation',
        startedAt: running.startedAt,
        finishedAt: f.now,
        exitCode: 0,
        jobName: f.job('long-program'),
      );
      await f.service.agent.reportCredentialProgramExecution(
        Fixture.device,
        ended,
      );
      final first = await f.service.agent.acknowledgeCredentialProgramCleanup(
        Fixture.device,
        id,
        cap,
        treeEnded: true,
      );
      final repeat = await f.service.agent.acknowledgeCredentialProgramCleanup(
        Fixture.device,
        id,
        cap,
        treeEnded: true,
      );
      expect(first.progress.cleanupState, 'complete');
      expect(first.revision, repeat.revision);
      expect((await f.begin('long-program')).material, null);
      expect(f.repo.credentialProgramOperations, hasLength(1));
    },
  );

  test(
    'a late unstarted claim becomes unknown and never grants a second material response',
    () async {
      await f.approve();
      final claim = await f.begin('late-start');
      f.now = f.now.add(const Duration(seconds: 31));
      expect(
        () => f.service.agent.authorizeCredentialProgramStart(
          Fixture.device,
          claim.operation.id,
          claim.material!.executionCapability,
        ),
        throwsA(failure('execution_unknown')),
      );
      expect(
        f.service.agent.credentialProgramOperationStatus(
          f.session,
          Fixture.device,
          'late-start',
        )['executionState'],
        'unknown',
      );
      expect((await f.begin('late-start')).material, null);
      expect(f.repo.credentialProgramOperations, hasLength(1));
    },
  );
}
