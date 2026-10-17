import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class FailingRuntimeRepository extends MemoryInformationRepository {
  bool fail = false;
  bool failDecision = false;
  void Function()? afterConsumeCommit;
  @override
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  }) async {
    if (fail || failDecision && fieldGrant != null) {
      throw StateError('synthetic audit unavailable');
    }
    await super.commitCredentialRuntime(
      requests,
      executions,
      fieldGrant: fieldGrant,
      fieldRequest: fieldRequest,
      validate: validate,
    );
    if(executions.isNotEmpty&&afterConsumeCommit!=null){final hook=afterConsumeCommit;afterConsumeCommit=null;hook!();}
  }
}

Future<(InformationService, String, CredentialUseRequest)> tokenRequest({
  MemoryInformationRepository? repository,
}) async {
  final service = InformationService(
    repository: repository ?? MemoryInformationRepository(),
    credentialExecutableInspector: (path, receiver) async =>
        ExecutableIdentity(path, 10, 100, 'sha256:fixture'),
  );
  var c = await service.owner.createStringCredential(
    name: 'Synthetic',
    publicPurpose: '',
    secret: 'synthetic-token',
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
  final session = service.agent.openSession('Synthetic chat');
  final request = await service.agent.requestCredentialUse(
    session,
    CredentialUseInput.fromJson({
      'command': 'request-use',
      'purpose': 'Synthetic task',
      'credentials': [
        {'alias': 'token', 'credentialId': c.id, 'version': 1},
      ],
      'launch': {
        'receiver': 'gh_token',
        'executable': Platform.resolvedExecutable,
        'argv': ['api', 'user', '--method', 'GET'],
        'cwd': Directory.current.path,
        'env': {
          'GH_TOKEN': {'secret': 'token'},
        },
      },
    }),
  );
  return (service, session, request);
}

void main() {
  test('credential request is discoverable through the bounded owner inbox',()async {
    final (service,session,request)=await tokenRequest();
    addTearDown(service.close);
    final inbox=service.owner.queryInbox(filter:InboxFilter.pending,limit:8);
    expect(inbox.total,1);
    expect(inbox.entries.single.id,request.id);
    expect(inbox.entries.single.purpose,'Synthetic task');
    await service.owner.decideCredentialUse(request.id,approveCredential:true);
    expect(service.owner.queryInbox(filter:InboxFilter.pending).total,0);
    expect(service.owner.queryInbox(filter:InboxFilter.handled).entries.single.id,request.id);
    expect(service.agent.status(session,request.id)['status'],'approved');
  });
  test('execution report cannot invent the OS process creation identity',()async {
    final (service,session,request)=await tokenRequest();
    addTearDown(service.close);
    await service.owner.decideCredentialUse(request.id,approveCredential:true);
    final material=await service.agent.consumeCredentialUse(session,request.id);
    await expectLater(service.agent.reportCredentialExecution(CredentialExecutionReport(executionId:material.executionId,executionCapability:material.executionCapability,state:'running',pid:pid,processCreatedAt:'invented-process-identity',startedAt:DateTime.now().toUtc())),throwsA(isA<CredentialUseFailure>().having((e)=>e.code,'code','invalid_plan')));
    expect(service.owner.credentialExecutions.single.state,'preparing');
  });
  test('session ending after committed consumption records the failed preparation and never returns material',()async {
    final repo=FailingRuntimeRepository();
    final (service,session,request)=await tokenRequest(repository:repo);
    addTearDown(service.close);
    await service.owner.decideCredentialUse(request.id,approveCredential:true);
    repo.afterConsumeCommit=()=>service.agent.endSession(session);
    await expectLater(service.agent.consumeCredentialUse(session,request.id),throwsA(isA<CredentialUseFailure>().having((e)=>e.code,'code','grant_revoked').having((e)=>e.attemptConsumed,'attemptConsumed',true)));
    expect(service.owner.credentialUseRequests.single.attemptConsumed,isTrue);
    expect(service.owner.credentialExecutions.single.state,'prepare_failed');
    expect(service.owner.credentialExecutions.single.errorCode,'material_claim_failed');
  });
  test(
    'combined decision audit failure publishes neither independent permission nor half a decision',
    () async {
      final repo = FailingRuntimeRepository();
      final service = InformationService(
        repository: repo,
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 10, 100, 'sha256:fixture'),
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation(
        'Synthetic server',
        '',
        [const FieldInput('Host', '', 'example.invalid')],
      );
      var c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'synthetic-token',
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
      final session = service.agent.openSession('Synthetic combined decision');
      final field = FieldRef(item.id, item.fields.single.id);
      final request = await service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'command': 'request-use',
          'purpose': 'Synthetic combined task',
          'credentials': [
            {'alias': 'token', 'credentialId': c.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'user'],
            'cwd': Directory.current.path,
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
          'readFields': [field.toJson()],
        }),
      );
      repo.failDecision = true;
      await expectLater(
        service.owner.decideCredentialUse(
          request.id,
          approveCredential: true,
          fields: [field],
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'audit_unavailable',
          ),
        ),
      );
      expect(
        service.agent.credentialUseStatus(session, request.id)['status'],
        'pending',
      );
      expect(repo.grantHistory, isEmpty);
      expect(repo.requestHistory, isEmpty);
      expect(
        () => service.agent.claim(session, request.id),
        throwsA(isA<CredentialUseFailure>()),
      );
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'request_pending',
          ),
        ),
      );
      repo.failDecision = false;
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
        fields: [field],
      );
      final grant = service.agent.claim(session, request.id);
      expect(await service.agent.read(grant.token, field), 'example.invalid');
      expect(
        (await service.agent.consumeCredentialUse(
          session,
          request.id,
        )).credentialMaterial.stringValue,
        'synthetic-token',
      );
    },
  );
  test(
    'audit failure rolls back a start attempt before private material is delivered',
    () async {
      final repo = FailingRuntimeRepository();
      final (service, session, request) = await tokenRequest(repository: repo);
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      repo.fail = true;
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'audit_unavailable',
          ),
        ),
      );
      expect(service.owner.credentialExecutions, isEmpty);
      expect(
        service.owner.credentialUseRequests.single.attemptConsumed,
        isFalse,
      );
      repo.fail = false;
      final results = await Future.wait(
        List.generate(2, (_) async {
          try {
            return await service.agent.consumeCredentialUse(
              session,
              request.id,
            );
          } on CredentialUseFailure catch (e) {
            return e;
          }
        }),
      );
      expect(results.whereType<CredentialExecutionMaterial>().length, 1);
      expect(
        results.whereType<CredentialUseFailure>().single.code,
        'attempt_consumed',
      );
    },
  );

  test(
    'credential invalidation is latched while field approval remains independent',
    () async {
      final (service, session, request) = await tokenRequest();
      addTearDown(service.close);
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      var c = service.owner.credential(request.credentialId);
      c = await service.owner.setCredentialEnabled(c.id, c.revision, false);
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'credential_disabled',
          ),
        ),
      );
      await service.owner.setCredentialEnabled(c.id, c.revision, true);
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'credential_version_changed',
          ),
        ),
      );
      expect(
        service.owner.credentialGrantState(
          service.owner.credentialUseRequests.single,
        ),
        'version_invalidated',
      );
      expect(service.owner.credentialExecutions, isEmpty);
    },
  );
  test(
    'approved fixed Token plan is consumed once and keeps its field permission',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository([
          InformationItem('server', 'Server', '', 1, const [
            InformationField('host', 'Host', '', 'example.invalid', 1),
          ]),
        ]),
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 10, 100, 'sha256:fixture'),
      );
      addTearDown(service.close);
      var credential = await service.owner.createStringCredential(
        name: 'Synthetic GitHub',
        publicPurpose: 'Fictional token',
        secret: 'synthetic-token',
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      final session = service.agent.openSession('Synthetic chat');
      final request = await service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'command': 'request-use',
          'purpose': 'Read synthetic issue',
          'credentials': [
            {'alias': 'token', 'credentialId': credential.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'repos/example/project/issues', '--method', 'GET'],
            'cwd': Directory.current.path,
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
          'readFields': [
            {'itemId': 'server', 'fieldId': 'host'},
          ],
        }),
      );
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
        fields: [const FieldRef('server', 'host')],
      );
      final material = await service.agent.consumeCredentialUse(
        session,
        request.id,
      );
      expect(material.credentialMaterial.stringValue, 'synthetic-token');
      expect(
        material.approvedPlan.executable.path,
        Platform.resolvedExecutable,
      );
      final grant = service.agent.claim(session, request.id);
      expect(
        await service.agent.read(grant.token, const FieldRef('server', 'host')),
        'example.invalid',
      );
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'attempt_consumed',
          ),
        ),
      );
      expect(
        service.owner.credentialExecutions.single.id,
        material.executionId,
      );
      expect(
        service.agent.credentialUseStatus(session, request.id)['executionId'],
        material.executionId,
      );
    },
  );
}
