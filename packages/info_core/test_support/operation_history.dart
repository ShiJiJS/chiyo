import 'package:info_core/info_core.dart' as core;

/// Valid persisted synthetic metadata, not thousands of launched programs.
/// Both Memory and SQLCipher repositories run their normal commit validators.
class OperationHistoryFixture {
  OperationHistoryFixture(this.service, this.repository, this.at);
  final core.InformationService service;
  final Object repository;
  final DateTime at;
  late String session;
  late core.CredentialBatchInput input;
  late core.CredentialUseBatch request;
  late core.CredentialProgramPlan plan;
  core.CredentialProgramPlan get businessPlan =>
      core.CredentialProgramPlan.fromJson({
        for (final e in plan.toJson().entries)
          if (e.key != 'executableIdentity') e.key: e.value,
      }, allowPortablePaths: true);
  Future<void> open({
    required bool program,
    int count = 0,
    bool programFile = false,
  }) async {
    var credential = await service.owner.createStringCredential(
      name: '合成测试凭据',
      publicPurpose: '',
      secret: 'NEVER-PAGE-THIS-MATERIAL',
    );
    credential = await service.owner.updateCredentialMetadata(
      credential.id,
      credential.revision,
      name: credential.name,
      publicPurpose: '',
      privateNote: '',
      suggestedBinding: 'TOKEN',
      discoverable: true,
    );
    input = program
        ? core.CredentialBatchInput.forProgram(
            plan =
                core.CredentialProgramPlan.fromJson({
                  'executable': '/synthetic/business-tool',
                  'cwd': '/synthetic/work',
                  'argv': ['query'],
                  'env': {
                    'TOKEN': programFile
                        ? {
                            'file': {
                              'credentialId': credential.id,
                              'version': 1,
                            },
                          }
                        : {'credentialId': credential.id, 'version': 1},
                  },
                }, allowPortablePaths: true).resolved(
                  core.ExecutableIdentity(
                    '/synthetic/business-tool',
                    100,
                    1,
                    'sha256:${'a' * 64}',
                  ),
                  '/synthetic/work',
                ),
            purpose: '合成程序历史',
          )
        : core.CredentialBatchInput.fromJson({
            'protocolVersion': 3,
            'purpose': '合成填写历史',
            'items': [
              {
                'credentialId': credential.id,
                'version': 1,
                'destination': {
                  'via': 'ego',
                  'target': {
                    'provider': 'ego',
                    'space': 7,
                    'pageId': 'p1',
                    'instanceId': 'synthetic',
                    'url': 'https://synthetic.test/login',
                    'form': '#login',
                    'field': '#password',
                    'structureDigest': 'a' * 64,
                  },
                },
              },
            ],
          });
    request = await service.agent.requestCredentialBatch(
      session = service.agent.openSession('合成记录分页'),
      'A' * 22,
      input,
      operationId: 'synthetic-history-submit-${program ? 'program' : 'fill'}',
    );
    request = await service.owner.decideCredentialBatch(
      request.id,
      operationId: 'synthetic-history-approve-${program ? 'program' : 'fill'}',
      revision: 1,
      approvedItems: ['b1'],
    );
    for (var i = 0; i < count; i++) {
      await append('op-${i.toString().padLeft(6, '0')}');
    }
  }

  Future<void> append(String id, {bool finish = true}) async {
    if (request.programPlan != null) {
      final initial = core.CredentialProgramOperation(
        sessionBinding: request.sessionBinding,
        deviceId: request.deviceId,
        plan: plan,
        itemIds: ['b1'],
        progress: core.CredentialExecution(
          id: 'execution-$id',
          requestId: request.id,
          protocolVersion: 2,
          operationId: id,
          operationFingerprint: plan.planHash,
          createdAt: at,
          jobName: 'macos:AgentInfoRuntime-${'A' * 32}',
        ),
      );
      final repo = repository as core.CredentialProgramRepository;
      await repo.commitCredentialProgramOperation(
        initial,
        expectedRevision: 0,
        requestRevision: request.revision,
        validate: () {},
      );
      if (!finish) {
        return;
      }
      await repo.commitCredentialProgramOperation(
        initial.withReport(
          core.CredentialExecutionReport(
            executionId: initial.id,
            executionCapability: 'synthetic-fixture-report',
            state: 'prepare_failed',
            errorCode: 'material_prepare_failed',
            finishedAt: at,
            jobName: initial.progress.jobName,
          ),
        ),
        expectedRevision: 1,
        requestRevision: request.revision,
        validate: () {},
      );
    } else {
      final initial = core.CredentialBatchOperation(
        operationId: id,
        requestId: request.id,
        sessionBinding: request.sessionBinding,
        fingerprint: 'sha256:${'a' * 64}',
        createdAt: at,
        itemIds: ['b1'],
      );
      final repo = repository as core.CredentialBatchRepository;
      await repo.commitCredentialBatch(
        request,
        expectedRevision: request.revision,
        operation: initial,
        expectedOperationRevision: 0,
        validate: () {},
      );
      if (!finish) {
        return;
      }
      await repo.commitCredentialBatch(
        request,
        expectedRevision: request.revision,
        operation: initial.changed(
          state: core.CredentialBatchOperationState.refused,
          finishedAt: at,
          itemResults: {'b1': 'refused'},
          errorCode: 'destination_changed',
        ),
        expectedOperationRevision: 1,
        validate: () {},
      );
    }
  }
}
