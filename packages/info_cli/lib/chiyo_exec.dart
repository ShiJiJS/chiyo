part of 'chiyo_cli.dart';

extension _ChiyoExec on ChiyoCli {
  Future<CredentialProgramPlan> _fixedProgramVersions(
    AgentClient client,
    CredentialProgramPlan plan,
    CredentialProgramPlan? previous,
  ) async {
    final versions = <String, int>{
      if (previous != null)
        for (final binding in previous.bindings)
          binding.reference.credentialId: binding.reference.version!,
    };
    for (final binding in plan.bindings) {
      final reference = binding.reference;
      if (reference.version == null &&
          !versions.containsKey(reference.credentialId)) {
        versions[reference.credentialId] = await _credentialVersion(
          client,
          reference.credentialId,
        );
      }
    }
    return plan.withVersions(versions);
  }

  Future<Map<String, dynamic>> _requestProgram(
    ChiyoInvocation invocation,
    AgentClient client,
  ) async {
    final business = invocation.options['input'] == null
        ? null
        : await _businessInput(invocation, 100 * 1024);
    final requested = ChiyoProgramRequest.fromInvocation(
      invocation,
      businessInput: business,
    );
    final id = invocation.options['operation'] as String?;
    final previous = id == null ? null : await _intents.read(id);
    final oldPlan = previous?.kind == 'exec-request'
        ? CredentialProgramPlan.fromJson(
            previous!.payload['launch'] as Map<String, dynamic>,
          )
        : null;
    final plan = await _fixedProgramVersions(client, requested.launch, oldPlan);
    // Freeze the public executable snapshot before submitting. Recovery uses
    // this original snapshot, rather than silently requesting a changed tool.
    final prepared = oldPlan != null && plan.planHash == oldPlan.planHash
        ? DeviceCredentialLaunch.fromPrivateJson(
            previous!.payload['prepared'] as Map<String, dynamic>,
          )
        : await DeviceCredentialLaunch.prepareProgram(plan);
    final intent = await _intents.remember('exec-request', {
      'command': 'program-request',
      ...requested.presentation.toProtocolJson(),
      'launch': plan.toJson(),
      'prepared': prepared.toPrivateJson(),
      'agentName': _activeContext.agentName,
      'externalChatId': _activeContext.chatId,
      'submissionVersion': 1,
    }, operationId: id);
    return _continueProgram(client, intent);
  }

  Future<Map<String, dynamic>> _runProgram(
    ChiyoInvocation invocation,
    AgentClient client,
  ) async {
    final id = invocation.options['operation'] as String?;
    final previous = id == null ? null : await _intents.read(id);
    final Map<String, dynamic>? launch;
    if (invocation.options['input'] != null) {
      final business = await _businessInput(invocation, 100 * 1024);
      if (business.length != 1 || business['launch'] is! Map<String, dynamic>) {
        throw const ChiyoUsageFailure('执行文件只填写 launch；申请编号使用 --request。');
      }
      var plan = CredentialProgramPlan.fromJson(
        business['launch'] as Map<String, dynamic>,
      );
      final request = await client.execute({
        'command': 'requests-show',
        'id': _required(invocation, 'request'),
      });
      if (request['programPlan'] is! Map<String, dynamic>) return request;
      final approved = CredentialProgramPlan.fromPreparedJson(
        request['programPlan'] as Map<String, dynamic>,
      );
      plan = plan.withVersions({
        for (final binding in approved.bindings)
          binding.reference.credentialId: binding.reference.version!,
      });
      final prepared = await DeviceCredentialLaunch.prepareProgram(plan);
      prepared.resolveProgram(plan).requireApprovedScope(approved);
      launch = Map<String, dynamic>.from(prepared.resolveProgram(plan).toJson())
        ..remove('executableIdentity');
    } else {
      launch = null;
    }
    final intent = await _intents.remember('exec-run', {
      'requestId': _required(invocation, 'request'),
      'launch': ?launch,
    }, operationId: id);
    return _continueProgram(client, intent, recover: previous != null);
  }

  Future<Map<String, dynamic>> _continueProgram(
    AgentClient client,
    ChiyoIntent intent, {
    bool recover = false,
  }) async {
    final run = intent.kind == 'exec-run';
    final response = await client.execute(
      run && recover
          ? {'command': 'program-status', 'operationId': intent.operationId}
          : {
              ...intent.payload,
              'command': run ? 'program-run' : 'program-request',
              'operationId': intent.operationId,
            },
    );
    if (run && recover && response['status'] == 'not_found' ||
        response['status'] == 'service_unavailable' ||
        response['errorCode'] == 'material_claim_failed') {
      return {
        'status': run ? 'operation_unknown' : 'request_unknown',
        'operationId': intent.operationId,
        if (run) 'requestId': intent.payload['requestId'],
      };
    }
    return {...response, 'operationId': intent.operationId};
  }
}
