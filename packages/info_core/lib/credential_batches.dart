part of 'info_core.dart';

DateTime _batchTime(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
  value.millisecondsSinceEpoch,
  isUtc: true,
);

/// A real destination, not a caller-defined credential alias. Browser and
/// native application scopes remain different even when both show passwords.
class CredentialBatchDestination {
  const CredentialBatchDestination._(
    this.via,
    this.browser,
    this.application, [
    this.program,
    this.native,
  ]);
  final String via;
  final BrowserFormTarget? browser;
  final FocusedFillApplication? application;
  final CredentialProgramDestination? program;
  final NativeFillTarget? native;
  factory CredentialBatchDestination.fromJson(Map<String, dynamic> json) {
    final via = json['via'];
    if (via == 'native') {
      _useShape(json, {'via', 'target'});
      if (json['target'] is! Map<String, dynamic>) {
        throw const CredentialUseFailure('invalid_type');
      }
      return CredentialBatchDestination._(
        'native',
        null,
        null,
        null,
        NativeFillTarget.fromJson(json['target'] as Map<String, dynamic>),
      );
    }
    if (via == 'program') {
      _useShape(json, {'via', 'program'});
      if (json['program'] is! Map<String, dynamic>) {
        throw const CredentialUseFailure('invalid_type');
      }
      return CredentialBatchDestination._(
        'program',
        null,
        null,
        CredentialProgramDestination.fromJson(
          json['program'] as Map<String, dynamic>,
        ),
      );
    }
    if (via == 'ego' || via == 'chrome') {
      _useShape(json, {'via', 'target'});
      if (json['target'] is! Map<String, dynamic>) {
        throw const CredentialUseFailure('invalid_type');
      }
      final target = BrowserFormTarget.fromJson(
        json['target'] as Map<String, dynamic>,
      );
      if (target.provider != via) {
        throw const CredentialUseFailure('invalid_plan');
      }
      return CredentialBatchDestination._(via as String, target, null);
    }
    if (via == 'focus') {
      _useShape(json, {'via', 'application'});
      if (json['application'] is! Map<String, dynamic>) {
        throw const CredentialUseFailure('invalid_type');
      }
      return CredentialBatchDestination._(
        'focus',
        null,
        FocusedFillApplication.fromJson(
          json['application'] as Map<String, dynamic>,
        ),
      );
    }
    throw const CredentialUseFailure('unsupported_receiver');
  }
  Map<String, Object?> toJson() => {
    'via': via,
    if (browser != null) 'target': browser!.toJson(),
    if (native != null) 'target': native!.toJson(),
    if (application != null) 'application': application!.toJson(),
    if (program != null) 'program': program!.toJson(),
  };
  String get fingerprint => _useFingerprint(toJson());
  bool matches(CredentialBatchDestination other) =>
      via == other.via &&
      (application != null
          ? other.application != null &&
                application!.matches(other.application!)
          : fingerprint == other.fingerprint);
}

class CredentialBatchCandidate {
  const CredentialBatchCandidate(
    this.credentialId,
    this.version,
    this.destination,
  );
  final String credentialId;
  final int? version;
  final CredentialBatchDestination destination;
  factory CredentialBatchCandidate.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'credentialId', 'destination'}, {'version'});
    if (json.containsKey('version') &&
            (json['version'] is! int || (json['version'] as int) < 1) ||
        json['destination'] is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_type');
    }
    return CredentialBatchCandidate(
      _useId(json['credentialId'], 'credentialId'),
      json['version'] as int?,
      CredentialBatchDestination.fromJson(
        json['destination'] as Map<String, dynamic>,
      ),
    );
  }
  Map<String, Object?> toJson() => {
    'credentialId': credentialId,
    if (version != null) 'version': version,
    'destination': destination.toJson(),
  };
}

class CredentialBatchInput {
  CredentialBatchInput._(
    this.purpose,
    this.agentName,
    this.externalChatId,
    Iterable<CredentialBatchCandidate> items, [
    this.programPlan,
  ]) : items = List.unmodifiable(items);
  final String purpose, agentName, externalChatId;
  final List<CredentialBatchCandidate> items;
  final CredentialProgramPlan? programPlan;
  factory CredentialBatchInput.fromJson(
    Map<String, dynamic> json, {
    bool allowProgram = false,
  }) {
    _useShape(
      json,
      {'protocolVersion', 'purpose', 'items'},
      {
        'agentName',
        'externalChatId',
        'submissionVersion',
        if (allowProgram) 'programPlan',
      },
    );
    if (json['protocolVersion'] != 3) {
      throw const CredentialUseFailure('unsupported_protocol');
    }
    if (json['items'] is! List ||
        (json['items'] as List).isEmpty ||
        (json['items'] as List).length > 20 ||
        (json['items'] as List).any((v) => v is! Map<String, dynamic>)) {
      throw const CredentialUseFailure('limit_exceeded');
    }
    final purpose = _useText(
      json['purpose'],
      'purpose',
      max: 2000,
      empty: false,
    );
    final agent = _useSourceText(json, 'agentName'),
        chat = _useSourceText(json, 'externalChatId');
    if (purpose.trim().isEmpty ||
        !validSubmissionMetadata(
          agentName: agent,
          externalChatId: chat,
          purpose: purpose,
        ) ||
        submissionMetadataErrors(json).isNotEmpty) {
      throw const CredentialUseFailure('invalid_submission_metadata');
    }
    final items = (json['items'] as List)
        .map(
          (v) => CredentialBatchCandidate.fromJson(v as Map<String, dynamic>),
        )
        .toList();
    final program = json.containsKey('programPlan')
        ? CredentialProgramPlan.fromPreparedJson(
            Map<String, dynamic>.from(json['programPlan'] as Map),
          )
        : null;
    if ((program == null && items.any((i) => i.destination.program != null)) ||
        program != null &&
            _useFingerprint(items.map((i) => i.toJson()).toList()) !=
                _useFingerprint(
                  _programCandidates(program).map((i) => i.toJson()).toList(),
                )) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (items.map((i) => _useFingerprint(i.toJson())).toSet().length !=
            items.length ||
        utf8.encode(jsonEncode(json)).length > 262144) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return CredentialBatchInput._(purpose, agent, chat, items, program);
  }
  factory CredentialBatchInput.forProgram(
    CredentialProgramPlan plan, {
    required String purpose,
    String agentName = '',
    String externalChatId = '',
  }) => CredentialBatchInput.fromJson({
    'protocolVersion': 3,
    'purpose': purpose,
    'agentName': agentName,
    'externalChatId': externalChatId,
    'programPlan': plan.toJson(),
    'items': _programCandidates(plan).map((i) => i.toJson()).toList(),
  }, allowProgram: true);
  Map<String, Object?> toJson() => {
    'protocolVersion': 3,
    'purpose': purpose,
    'agentName': agentName,
    'externalChatId': externalChatId,
    'items': items.map((i) => i.toJson()).toList(),
    if (programPlan != null) 'programPlan': programPlan!.toJson(),
  };
  String get fingerprint => _useFingerprint(toJson());
}

enum CredentialBatchItemDecision { pending, approved, denied, revoked }

class CredentialBatchItem {
  const CredentialBatchItem({
    required this.id,
    required this.credentialId,
    required this.credentialName,
    required this.version,
    required this.useGeneration,
    required this.destination,
    this.decision = CredentialBatchItemDecision.pending,
    this.expiresAt,
  });
  final String id, credentialId, credentialName;
  final int version, useGeneration;
  final CredentialBatchDestination destination;
  final CredentialBatchItemDecision decision;
  final DateTime? expiresAt;
  CredentialBatchItem decided(
    CredentialBatchItemDecision next,
    DateTime? expiry,
  ) => CredentialBatchItem(
    id: id,
    credentialId: credentialId,
    credentialName: credentialName,
    version: version,
    useGeneration: useGeneration,
    destination: destination,
    decision: next,
    expiresAt: expiry,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'credentialId': credentialId,
    'credentialName': credentialName,
    'version': version,
    'useGeneration': useGeneration,
    'destination': destination.toJson(),
    'decision': decision.name,
    'expiresAt': _useTimestamp(expiresAt),
  };
  factory CredentialBatchItem.fromJson(Map<String, dynamic> json) {
    _useShape(json, {
      'id',
      'credentialId',
      'credentialName',
      'version',
      'useGeneration',
      'destination',
      'decision',
      'expiresAt',
    });
    final decision = CredentialBatchItemDecision.values
        .where((v) => v.name == json['decision'])
        .firstOrNull;
    if (json['version'] is! int ||
        (json['version'] as int) < 1 ||
        json['useGeneration'] is! int ||
        (json['useGeneration'] as int) < 1 ||
        json['destination'] is! Map<String, dynamic> ||
        decision == null) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final expiresAt = _batchDate(json['expiresAt'], optional: true);
    if ((decision == CredentialBatchItemDecision.approved ||
            decision == CredentialBatchItemDecision.revoked) !=
        (expiresAt != null)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return CredentialBatchItem(
      id: _useId(json['id'], 'itemId'),
      credentialId: _useId(json['credentialId'], 'credentialId'),
      credentialName: _useText(
        json['credentialName'],
        'credentialName',
        max: 200,
        empty: false,
      ),
      version: json['version'] as int,
      useGeneration: json['useGeneration'] as int,
      destination: CredentialBatchDestination.fromJson(
        json['destination'] as Map<String, dynamic>,
      ),
      decision: decision,
      expiresAt: expiresAt,
    );
  }
}

DateTime? _batchDate(Object? value, {bool optional = false}) {
  if (value == null && optional) return null;
  if (value is! String) throw const CredentialUseFailure('invalid_plan');
  final date = DateTime.tryParse(value);
  if (date == null || !date.isUtc || date.year < 1970 || date.year > 9999) {
    throw const CredentialUseFailure('invalid_plan');
  }
  return date;
}

String _batchOperationId(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value)) {
    throw const CredentialUseFailure('invalid_operation_id');
  }
  return value;
}

class CredentialBatchDecisionReceipt {
  const CredentialBatchDecisionReceipt(
    this.operationId,
    this.fingerprint,
    this.at, {
    this.ownerReceipt,
  });
  final String operationId, fingerprint;
  final DateTime at;
  final InformationApprovalReceipt? ownerReceipt;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'fingerprint': fingerprint,
    'at': _useTimestamp(at),
    if (ownerReceipt != null) 'ownerReceipt': ownerReceipt!.toJson(),
  };
  factory CredentialBatchDecisionReceipt.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'operationId', 'fingerprint', 'at'}, {'ownerReceipt'});
    if (!RegExp(
      r'^sha256:[0-9a-f]{64}$',
    ).hasMatch(json['fingerprint'] as String? ?? '')) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final receipt = json['ownerReceipt'] == null
        ? null
        : InformationApprovalReceipt.fromJson(
            Map<String, dynamic>.from(json['ownerReceipt'] as Map),
          );
    if (receipt != null &&
        (receipt.operationId != json['operationId'] ||
            receipt.recordedAt != _batchDate(json['at']))) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return CredentialBatchDecisionReceipt(
      _batchOperationId(json['operationId']),
      json['fingerprint'] as String,
      _batchDate(json['at'])!,
      ownerReceipt: receipt,
    );
  }
}

/// Durable request metadata only. Private session/device proofs are not part
/// of this portable record; a restored record cannot recreate an authority.
class CredentialUseBatch {
  CredentialUseBatch({
    required this.id,
    required this.sessionBinding,
    required this.deviceId,
    required this.operationId,
    required this.submissionDigest,
    required this.chatLabel,
    required this.agentName,
    required this.externalChatId,
    required this.purpose,
    required this.createdAt,
    required this.requestExpiresAt,
    required Iterable<CredentialBatchItem> items,
    this.programPlan,
    this.revision = 1,
    this.archived = false,
    Iterable<CredentialBatchDecisionReceipt> decisions = const [],
  }) : items = List.unmodifiable(items),
       decisions = List.unmodifiable(decisions);
  final String id, sessionBinding, deviceId, operationId, submissionDigest;
  final String chatLabel, agentName, externalChatId, purpose;
  final DateTime createdAt, requestExpiresAt;
  final List<CredentialBatchItem> items;
  final CredentialProgramPlan? programPlan;
  final List<CredentialBatchDecisionReceipt> decisions;
  final int revision;
  final bool archived;
  String get immutableFingerprint {
    final value = toJson()
      ..remove('revision')
      ..remove('decisions')
      ..remove('archived');
    value['items'] = [
      for (final item in items)
        item.toJson()
          ..remove('decision')
          ..remove('expiresAt'),
    ];
    return _useFingerprint(value);
  }

  Map<String, Object?> toJson() => {
    'protocolVersion': 3,
    'id': id,
    'sessionBinding': sessionBinding,
    'deviceId': deviceId,
    'operationId': operationId,
    'submissionDigest': submissionDigest,
    'chatLabel': chatLabel,
    'agentName': agentName,
    'externalChatId': externalChatId,
    'purpose': purpose,
    'createdAt': _useTimestamp(createdAt),
    'requestExpiresAt': _useTimestamp(requestExpiresAt),
    'revision': revision,
    'archived': archived,
    'items': items.map((i) => i.toJson()).toList(),
    'decisions': decisions.map((d) => d.toJson()).toList(),
    if (programPlan != null) 'programPlan': programPlan!.toJson(),
  };
  factory CredentialUseBatch.fromJson(Map<String, dynamic> json) {
    _useShape(
      json,
      {
        'protocolVersion',
        'id',
        'sessionBinding',
        'deviceId',
        'operationId',
        'submissionDigest',
        'chatLabel',
        'agentName',
        'externalChatId',
        'purpose',
        'createdAt',
        'requestExpiresAt',
        'revision',
        'archived',
        'items',
        'decisions',
      },
      {'programPlan'},
    );
    if (json['protocolVersion'] != 3 ||
        json['revision'] is! int ||
        (json['revision'] as int) < 1 ||
        json['archived'] is! bool ||
        json['items'] is! List ||
        (json['items'] as List).isEmpty ||
        (json['items'] as List).length > 20 ||
        json['decisions'] is! List ||
        (json['decisions'] as List).length > 21 ||
        !RegExp(
          r'^[A-Za-z0-9_-]{22}$',
        ).hasMatch(json['deviceId'] as String? ?? '') ||
        !RegExp(
          r'^sha256:[0-9a-f]{64}$',
        ).hasMatch(json['submissionDigest'] as String? ?? '')) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final items = (json['items'] as List)
        .map(
          (v) =>
              CredentialBatchItem.fromJson(Map<String, dynamic>.from(v as Map)),
        )
        .toList();
    final decisions = (json['decisions'] as List)
        .map(
          (v) => CredentialBatchDecisionReceipt.fromJson(
            Map<String, dynamic>.from(v as Map),
          ),
        )
        .toList();
    final program = json.containsKey('programPlan')
        ? CredentialProgramPlan.fromPreparedJson(
            Map<String, dynamic>.from(json['programPlan'] as Map),
          )
        : null;
    if (program == null
        ? items.any((i) => i.destination.program != null)
        : program.bindings.any((b) => b.reference.version == null) ||
              _useFingerprint(
                    items
                        .map(
                          (i) => CredentialBatchCandidate(
                            i.credentialId,
                            i.version,
                            i.destination,
                          ).toJson(),
                        )
                        .toList(),
                  ) !=
                  _useFingerprint(
                    _programCandidates(program).map((i) => i.toJson()).toList(),
                  )) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final created = _batchDate(json['createdAt'])!,
        expiry = _batchDate(json['requestExpiresAt'])!;
    if (items.map((i) => i.id).toSet().length != items.length ||
        decisions.map((d) => d.operationId).toSet().length !=
            decisions.length ||
        (decisions.isEmpty &&
            items.any(
              (i) => i.decision != CredentialBatchItemDecision.pending,
            )) ||
        (decisions.isNotEmpty &&
            items.any(
              (i) => i.decision == CredentialBatchItemDecision.pending,
            )) ||
        !expiry.isAfter(created) ||
        json['revision'] != decisions.length + 1 ||
        decisions.any((d) => d.at.isBefore(created))) {
      throw const CredentialUseFailure('invalid_plan');
    }
    for (final (index, d) in decisions.indexed) {
      if (d.ownerReceipt != null &&
          (d.ownerReceipt!.requestId != json['id'] ||
              d.ownerReceipt!.revision != index + 2)) {
        throw const CredentialUseFailure('invalid_plan');
      }
    }
    return CredentialUseBatch(
      id: _useId(json['id'], 'requestId'),
      sessionBinding: _useId(json['sessionBinding'], 'sessionBinding'),
      deviceId: json['deviceId'] as String,
      operationId: _batchOperationId(json['operationId']),
      submissionDigest: json['submissionDigest'] as String,
      chatLabel: _useText(
        json['chatLabel'],
        'chatLabel',
        max: 200,
        empty: false,
      ),
      agentName: _useText(json['agentName'], 'agentName', max: 200),
      externalChatId: _useText(
        json['externalChatId'],
        'externalChatId',
        max: 200,
      ),
      purpose: _useText(json['purpose'], 'purpose', max: 2000, empty: false),
      createdAt: created,
      requestExpiresAt: expiry,
      items: items,
      programPlan: program,
      revision: json['revision'] as int,
      archived: json['archived'] as bool,
      decisions: decisions,
    );
  }
  CredentialUseBatch withDecision(
    List<CredentialBatchItem> next,
    CredentialBatchDecisionReceipt receipt,
  ) => CredentialUseBatch(
    id: id,
    sessionBinding: sessionBinding,
    deviceId: deviceId,
    operationId: operationId,
    submissionDigest: submissionDigest,
    chatLabel: chatLabel,
    agentName: agentName,
    externalChatId: externalChatId,
    purpose: purpose,
    createdAt: createdAt,
    requestExpiresAt: requestExpiresAt,
    items: next,
    programPlan: programPlan,
    revision: revision + 1,
    archived: archived,
    decisions: [...decisions, receipt],
  );
}

enum CredentialBatchOperationState {
  checking,
  dispatched,
  filled,
  refused,
  partial,
  failed,
  unknown,
}

class CredentialBatchOperation {
  CredentialBatchOperation({
    required this.operationId,
    required this.requestId,
    required this.sessionBinding,
    required this.fingerprint,
    required this.createdAt,
    required Iterable<String> itemIds,
    this.state = CredentialBatchOperationState.checking,
    this.materialClaimed = false,
    this.revision = 1,
    this.finishedAt,
    Map<String, String> itemResults = const {},
    this.errorCode,
    this.attentionOperationId,
    this.attentionAcknowledgedAt,
  }) : itemIds = List.unmodifiable(itemIds),
       itemResults = Map.unmodifiable(itemResults);
  final String operationId, requestId, sessionBinding, fingerprint;
  final List<String> itemIds;
  final CredentialBatchOperationState state;
  final bool materialClaimed;
  final int revision;
  final Map<String, String> itemResults;
  final String? errorCode;
  final String? attentionOperationId;
  final DateTime? attentionAcknowledgedAt;
  final DateTime createdAt;
  final DateTime? finishedAt;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'requestId': requestId,
    'sessionBinding': sessionBinding,
    'fingerprint': fingerprint,
    'itemIds': itemIds,
    'state': state.name,
    'materialClaimed': materialClaimed,
    'revision': revision,
    'createdAt': _useTimestamp(createdAt),
    'finishedAt': _useTimestamp(finishedAt),
    'itemResults': itemResults,
    'errorCode': errorCode,
    'attentionOperationId': attentionOperationId,
    'attentionAcknowledgedAt': _useTimestamp(attentionAcknowledgedAt),
  };
  Map<String, Object?> toPublicJson() => {
    'status': 'ok',
    'operationId': operationId,
    'requestId': requestId,
    'itemIds': itemIds,
    'executionState': state.name,
    'createdAt': _useTimestamp(createdAt),
    'finishedAt': _useTimestamp(finishedAt),
    'itemResults': itemResults,
    'errorCode': errorCode,
    'attentionAcknowledgedAt': _useTimestamp(attentionAcknowledgedAt),
  };
  factory CredentialBatchOperation.fromJson(Map<String, dynamic> json) {
    _useShape(json, {
      'operationId',
      'requestId',
      'sessionBinding',
      'fingerprint',
      'itemIds',
      'state',
      'materialClaimed',
      'revision',
      'createdAt',
      'finishedAt',
      'itemResults',
      'errorCode',
      'attentionOperationId',
      'attentionAcknowledgedAt',
    });
    final state = CredentialBatchOperationState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    if (state == null ||
        json['materialClaimed'] is! bool ||
        json['revision'] is! int ||
        (json['revision'] as int) < 1 ||
        json['itemIds'] is! List ||
        (json['itemIds'] as List).isEmpty ||
        (json['itemIds'] as List).length > 20 ||
        json['itemResults'] is! Map<String, dynamic> ||
        !RegExp(
          r'^sha256:[0-9a-f]{64}$',
        ).hasMatch(json['fingerprint'] as String? ?? '')) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final ids = (json['itemIds'] as List)
        .map((v) => _useId(v, 'itemId'))
        .toList();
    final results = Map<String, dynamic>.from(json['itemResults'] as Map);
    final finished = _batchDate(json['finishedAt'], optional: true),
        created = _batchDate(json['createdAt'])!;
    final acknowledged = _batchDate(
      json['attentionAcknowledgedAt'],
      optional: true,
    );
    if (ids.toSet().length != ids.length ||
        results.keys.any((k) => !ids.contains(k)) ||
        results.values.any(
          (v) => !{
            'filled',
            'sent',
            'refused',
            'failed',
            'unknown',
            'not_attempted',
          }.contains(v),
        ) ||
        (state == CredentialBatchOperationState.checking ||
                state == CredentialBatchOperationState.dispatched) &&
            finished != null ||
        !{
              CredentialBatchOperationState.checking,
              CredentialBatchOperationState.dispatched,
              CredentialBatchOperationState.unknown,
            }.contains(state) &&
            finished == null ||
        finished != null && finished.isBefore(created) ||
        state == CredentialBatchOperationState.dispatched &&
            json['materialClaimed'] != true ||
        {
              CredentialBatchOperationState.filled,
              CredentialBatchOperationState.partial,
            }.contains(state) &&
            json['materialClaimed'] != true ||
        state == CredentialBatchOperationState.filled &&
            (results.length != ids.length ||
                results.values.any((v) => v != 'filled' && v != 'sent')) ||
        json['errorCode'] != null &&
            !credentialBatchErrorCodes.contains(json['errorCode']) ||
        (json['attentionOperationId'] == null) != (acknowledged == null) ||
        acknowledged != null &&
            (acknowledged.isBefore(created) ||
                !{
                  CredentialBatchOperationState.unknown,
                  CredentialBatchOperationState.partial,
                }.contains(state))) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return CredentialBatchOperation(
      operationId: _batchOperationId(json['operationId']),
      requestId: _useId(json['requestId'], 'requestId'),
      sessionBinding: _useId(json['sessionBinding'], 'sessionBinding'),
      fingerprint: json['fingerprint'] as String,
      createdAt: created,
      finishedAt: finished,
      itemIds: ids,
      state: state,
      materialClaimed: json['materialClaimed'] as bool,
      revision: json['revision'] as int,
      itemResults: results.cast<String, String>(),
      errorCode: json['errorCode'] as String?,
      attentionOperationId: json['attentionOperationId'] == null
          ? null
          : _batchOperationId(json['attentionOperationId']),
      attentionAcknowledgedAt: acknowledged,
    );
  }
  CredentialBatchOperation changed({
    CredentialBatchOperationState? state,
    bool? materialClaimed,
    DateTime? finishedAt,
    Map<String, String>? itemResults,
    String? errorCode,
    String? attentionOperationId,
    DateTime? attentionAcknowledgedAt,
  }) => CredentialBatchOperation(
    operationId: operationId,
    requestId: requestId,
    sessionBinding: sessionBinding,
    fingerprint: fingerprint,
    createdAt: createdAt,
    itemIds: itemIds,
    state: state ?? this.state,
    materialClaimed: materialClaimed ?? this.materialClaimed,
    revision: revision + 1,
    finishedAt: finishedAt ?? this.finishedAt,
    itemResults: itemResults ?? this.itemResults,
    errorCode: errorCode ?? this.errorCode,
    attentionOperationId: attentionOperationId ?? this.attentionOperationId,
    attentionAcknowledgedAt:
        attentionAcknowledgedAt ?? this.attentionAcknowledgedAt,
  );
}

const credentialBatchErrorCodes = {
  'target_unavailable',
  'access_denied',
  'session_unavailable',
  'input_rejected',
  'unsupported_secret',
  'destination_changed',
  'browser_unavailable',
  'browser_operation_failed',
  'ambiguous_form',
  'ambiguous_field',
  'not_password_field',
  'unavailable_target',
  'form_changed',
  'unsupported_password_value',
  'value_not_retained',
  'permission_required',
  'unsupported_target',
  'focus_changed',
  'fill_unknown',
  'grant_revoked',
  'grant_expired',
  'credential_version_changed',
  'credential_disabled',
  'credential_deleted',
  'session_required',
  'audit_unavailable',
  'service_unavailable',
  'material_prepare_failed',
  'execution_unknown',
  'fill_needs_attention',
};

/// One atomic request/operation write. Implementations must compare the stored
/// revision and enforce operation uniqueness within the private chat binding.
abstract interface class CredentialBatchRepository {
  List<CredentialUseBatch> get credentialBatches;
  List<CredentialBatchOperation> get credentialBatchOperations;

  /// Atomically compare the complete retention unit and remove children before
  /// their request. Recheck [validate] within the write before publication.
  Future<void> pruneCredentialBatchHistory(
    CredentialBatchHistoryPrune plan, {
    required void Function() validate,
  });
  Future<void> commitCredentialBatch(
    CredentialUseBatch request, {
    required int expectedRevision,
    required void Function() validate,
    CredentialBatchOperation? operation,
    int? expectedOperationRevision,
  });
}

/// Shared storage invariants. The actual revision check and publication must
/// still occur in the repository's transaction, not merely in this validation.
void validateCredentialBatchCommit(
  CredentialUseBatch next,
  CredentialUseBatch? previous,
  int expectedRevision, {
  CredentialBatchOperation? operation,
  CredentialBatchOperation? previousOperation,
  int? expectedOperationRevision,
}) {
  CredentialUseBatch.fromJson(Map<String, dynamic>.from(next.toJson()));
  if (next.programPlan != null && operation != null) {
    throw const CredentialUseFailure('unsupported_receiver');
  }
  if ((previous?.revision ?? 0) != expectedRevision) {
    throw const CredentialUseFailure('operation_conflict');
  }
  if (previous == null) {
    if (next.revision != 1 || next.decisions.isNotEmpty || next.archived) {
      throw const CredentialUseFailure('invalid_plan');
    }
  } else if (previous.immutableFingerprint != next.immutableFingerprint ||
      previous.archived != next.archived ||
      next.revision < previous.revision ||
      next.revision > previous.revision + 1 ||
      next.revision == previous.revision &&
          _useFingerprint(next.toJson()) !=
              _useFingerprint(previous.toJson()) ||
      next.revision == previous.revision + 1 &&
          _useFingerprint(
                next.decisions
                    .take(previous.decisions.length)
                    .map((d) => d.toJson())
                    .toList(),
              ) !=
              _useFingerprint(
                previous.decisions.map((d) => d.toJson()).toList(),
              )) {
    throw const CredentialUseFailure('operation_conflict');
  }
  if (operation == null) {
    if (expectedOperationRevision != null) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return;
  }
  CredentialBatchOperation.fromJson(
    Map<String, dynamic>.from(operation.toJson()),
  );
  if (operation.requestId != next.id ||
      operation.sessionBinding != next.sessionBinding ||
      operation.itemIds.any((id) => !next.items.any((i) => i.id == id)) ||
      (previousOperation?.revision ?? 0) != expectedOperationRevision) {
    throw const CredentialUseFailure('operation_conflict');
  }
  if (previousOperation == null) {
    if (operation.revision != 1 ||
        operation.state != CredentialBatchOperationState.checking ||
        operation.materialClaimed ||
        operation.itemResults.isNotEmpty) {
      throw const CredentialUseFailure('invalid_plan');
    }
  } else {
    final allowed = switch (previousOperation.state) {
      CredentialBatchOperationState.checking => {
        CredentialBatchOperationState.checking,
        CredentialBatchOperationState.dispatched,
        CredentialBatchOperationState.refused,
        CredentialBatchOperationState.failed,
        CredentialBatchOperationState.unknown,
      },
      CredentialBatchOperationState.dispatched => {
        CredentialBatchOperationState.dispatched,
        CredentialBatchOperationState.filled,
        CredentialBatchOperationState.partial,
        CredentialBatchOperationState.failed,
        CredentialBatchOperationState.unknown,
      },
      CredentialBatchOperationState.unknown ||
      CredentialBatchOperationState.partial =>
        previousOperation.attentionAcknowledgedAt == null &&
                operation.attentionAcknowledgedAt != null
            ? {previousOperation.state}
            : <CredentialBatchOperationState>{},
      _ => <CredentialBatchOperationState>{},
    };
    if (operation.revision != previousOperation.revision + 1 ||
        operation.fingerprint != previousOperation.fingerprint ||
        operation.requestId != previousOperation.requestId ||
        operation.sessionBinding != previousOperation.sessionBinding ||
        operation.createdAt != previousOperation.createdAt ||
        _useFingerprint(operation.itemIds) !=
            _useFingerprint(previousOperation.itemIds) ||
        previousOperation.materialClaimed && !operation.materialClaimed ||
        !allowed.contains(operation.state)) {
      throw const CredentialUseFailure('operation_conflict');
    }
    if ({
          CredentialBatchOperationState.unknown,
          CredentialBatchOperationState.partial,
        }.contains(previousOperation.state) &&
        (operation.finishedAt != previousOperation.finishedAt ||
            operation.errorCode != previousOperation.errorCode ||
            _useFingerprint(operation.itemResults) !=
                _useFingerprint(previousOperation.itemResults) ||
            operation.materialClaimed != previousOperation.materialClaimed)) {
      throw const CredentialUseFailure('operation_conflict');
    }
  }
}

final class _CredentialBatchProof {
  _CredentialBatchProof(
    this.operationId,
    this.sessionBinding,
    this.deviceId,
    this.proof,
    this.deadline,
  );
  final String operationId, sessionBinding, deviceId, proof;
  final DateTime deadline;
}

/// Private App result. Deliberately has no JSON serializer for material.
class CredentialBatchMaterials {
  CredentialBatchMaterials(Map<String, List<int>> bytes)
    : bytes = Map.unmodifiable(
        bytes.map((key, value) => MapEntry(key, List<int>.unmodifiable(value))),
      );
  final Map<String, List<int>> bytes;
}

class CredentialBatchOperationClaim {
  const CredentialBatchOperationClaim(this.operation, {this.privateProof});
  final CredentialBatchOperation operation;
  final String? privateProof;
  Map<String, Object?> toPublicJson() => operation.toPublicJson();
}
