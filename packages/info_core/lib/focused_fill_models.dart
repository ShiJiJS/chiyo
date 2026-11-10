part of 'info_core.dart';

/// The public application boundary. This is not a website-origin assertion or
/// a PID supplied by an agent. The native driver pins actual process/control
/// identities separately for each operation.
class FocusedFillApplication {
  const FocusedFillApplication._(this.executable, this.sha256);
  final String executable, sha256;
  factory FocusedFillApplication.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'executable', 'sha256'});
    final path = _useText(
      json['executable'],
      'fill.application.executable',
      max: 4096,
      empty: false,
    );
    final digest = _useText(
      json['sha256'],
      'fill.application.sha256',
      max: 64,
      empty: false,
    );
    final windows =
        RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path) &&
        path.toLowerCase().endsWith('.exe');
    final macos =
        path.startsWith('/') &&
        !path.startsWith('//') &&
        path.length > 1 &&
        !path.endsWith('/');
    if ((!windows && !macos) ||
        path.codeUnits.any((c) => c < 32 || c == 127) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const CredentialUseFailure(
        'invalid_plan',
        fieldPath: 'fill.application',
      );
    }
    return FocusedFillApplication._(path, digest);
  }
  bool get _windowsPath => !executable.startsWith('/');
  Map<String, Object?> toJson() => {'executable': executable, 'sha256': sha256};
  bool matches(FocusedFillApplication other) =>
      _windowsPath == other._windowsPath &&
      (_windowsPath
          ? executable.toLowerCase() == other.executable.toLowerCase()
          : executable == other.executable) &&
      sha256 == other.sha256;
}

class FocusedFillPlan {
  const FocusedFillPlan(this.application, this.targetHint);
  final FocusedFillApplication application;
  final String targetHint;
  factory FocusedFillPlan.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'application', 'targetHint'});
    if (json['application'] is! Map<String, dynamic>) {
      throw const CredentialUseFailure(
        'invalid_type',
        fieldPath: 'fill.application',
      );
    }
    return FocusedFillPlan(
      FocusedFillApplication.fromJson(
        json['application'] as Map<String, dynamic>,
      ),
      _useText(json['targetHint'], 'fill.targetHint', max: 2000),
    );
  }
  Map<String, Object?> toJson() => {
    'application': application.toJson(),
    'targetHint': targetHint,
  };
  String get planHash => _useFingerprint(toJson());
}

sealed class CredentialUseSpecification {
  const CredentialUseSpecification();
}

final class CredentialCommandSpecification extends CredentialUseSpecification {
  const CredentialCommandSpecification(this.plan);
  final CredentialLaunchPlan plan;
}

final class CredentialFocusedFillSpecification
    extends CredentialUseSpecification {
  const CredentialFocusedFillSpecification(this.plan);
  final FocusedFillPlan plan;
}

CredentialUseSpecification _credentialSpecification(
  int protocolVersion,
  CredentialLaunchPlan? command,
  FocusedFillPlan? fill,
  CredentialLaunchPlan? requested,
  Iterable<FieldRef> fields,
) {
  if ((command == null) == (fill == null) ||
      fill != null &&
          (protocolVersion != 2 || requested != null || fields.isNotEmpty)) {
    throw const CredentialUseFailure('invalid_plan');
  }
  return fill == null
      ? CredentialCommandSpecification(command!)
      : CredentialFocusedFillSpecification(fill);
}

bool _storedFocusedFill(Map<String, dynamic> json) {
  final kind = json['useKind'];
  if (kind != null && kind != 'command' && kind != 'focused_fill') {
    throw const CredentialUseFailure('unsupported_receiver');
  }
  final fill = kind == 'focused_fill';
  if (fill && (json.containsKey('plan') || !json.containsKey('fill')) ||
      !fill && json.containsKey('fill')) {
    throw const CredentialUseFailure('invalid_plan');
  }
  return fill;
}

class FocusedFillInput {
  const FocusedFillInput._(
    this.purpose,
    this.alias,
    this.credentialId,
    this.version,
    this.fill,
    this.agentName,
    this.externalChatId,
  );
  final String purpose, alias, credentialId;
  final String agentName, externalChatId;
  final int version;
  final FocusedFillPlan fill;
  factory FocusedFillInput.fromJson(Map<String, dynamic> json) {
    if (_useProtocol(json) != 2) {
      throw const CredentialUseFailure('unsupported_protocol');
    }
    _useShape(
      json,
      {'protocolVersion', 'command', 'purpose', 'credentials', 'fill'},
      {'readFields', 'agentName', 'externalChatId', 'submissionVersion'},
    );
    if (json['command'] != 'request-use' ||
        json.containsKey('readFields') &&
            (json['readFields'] is! List ||
                (json['readFields'] as List).isNotEmpty)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final credentials = json['credentials'];
    if (credentials is! List ||
        credentials.length != 1 ||
        credentials.single is! Map<String, dynamic> ||
        json['fill'] is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_type');
    }
    final credential = credentials.single as Map<String, dynamic>;
    _useShape(credential, {'alias', 'credentialId', 'version'});
    final version = credential['version'];
    if (version is! int || version < 1 || version > 2147483647) {
      throw const CredentialUseFailure('invalid_reference');
    }
    return FocusedFillInput._(
      _useText(json['purpose'], 'purpose', max: 2000, empty: false),
      _useAlias(credential['alias'], 'credentials[0].alias'),
      _useId(credential['credentialId'], 'credentials[0].credentialId'),
      version,
      FocusedFillPlan.fromJson(json['fill'] as Map<String, dynamic>),
      _useSourceText(json, 'agentName'),
      _useSourceText(json, 'externalChatId'),
    );
  }
}

class FocusedFillOperationInput {
  const FocusedFillOperationInput._(this.requestId, this.operationId);
  final String requestId, operationId;
  factory FocusedFillOperationInput.fromJson(Map<String, dynamic> json) {
    if (_useProtocol(json) != 2) {
      throw const CredentialUseFailure('unsupported_protocol');
    }
    _useShape(json, {'protocolVersion', 'command', 'requestId', 'operationId'});
    if (!{'fill-use', 'fill-status'}.contains(json['command'])) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return FocusedFillOperationInput._(
      _useId(json['requestId'], 'requestId'),
      _useId(json['operationId'], 'operationId'),
    );
  }
  String get fingerprint =>
      _useFingerprint({'requestId': requestId, 'useKind': 'focused_fill'});
}

enum FocusedFillState { checking, sent, refused, partial, unknown }

/// Deliberately has no secret, character count, command, exitCode, or cleanup.
class FocusedFillOperation {
  const FocusedFillOperation({
    required this.id,
    required this.requestId,
    required this.operationId,
    required this.fingerprint,
    required this.createdAt,
    required this.application,
    this.state = FocusedFillState.checking,
    this.inputReleased = false,
    this.errorCode,
    this.finishedAt,
    this.checkedAt,
    this.restoredAt,
    this.attentionAcknowledgedAt,
  });
  final String id, requestId, operationId, fingerprint;
  final FocusedFillApplication application;
  final FocusedFillState state;
  final bool inputReleased;
  final String? errorCode;
  final DateTime createdAt;
  final DateTime? finishedAt, checkedAt, restoredAt, attentionAcknowledgedAt;
  Map<String, Object?> toJson() => {
    'protocolVersion': 2,
    'status': state == FocusedFillState.checking ? 'accepted' : 'ok',
    'useKind': 'focused_fill',
    'operationClaimed': true,
    'fillId': id,
    'requestId': requestId,
    'operationId': operationId,
    'fillState': state.name,
    'application': application.toJson(),
    'createdAt': _useTimestamp(createdAt),
    if (errorCode != null) 'errorCode': errorCode,
    if (checkedAt != null) 'checkedAt': _useTimestamp(checkedAt),
    if (finishedAt != null) 'finishedAt': _useTimestamp(finishedAt),
    if (restoredAt != null) 'restoredAt': _useTimestamp(restoredAt),
    if (attentionAcknowledgedAt != null)
      'attentionAcknowledgedAt': _useTimestamp(attentionAcknowledgedAt),
  };
  Map<String, Object?> toStorageJson() => {
    ...toJson(),
    'fingerprint': fingerprint,
    'inputReleased': inputReleased,
  };
  factory FocusedFillOperation.fromStorageJson(Map<String, dynamic> json) {
    _useShape(
      json,
      {
        'protocolVersion',
        'status',
        'useKind',
        'operationClaimed',
        'fillId',
        'requestId',
        'operationId',
        'fillState',
        'application',
        'createdAt',
        'fingerprint',
        'inputReleased',
      },
      {
        'errorCode',
        'checkedAt',
        'finishedAt',
        'restoredAt',
        'attentionAcknowledgedAt',
      },
    );
    if (_useProtocol(json) != 2 ||
        json['useKind'] != 'focused_fill' ||
        json['operationClaimed'] != true ||
        json['inputReleased'] is! bool ||
        json['application'] is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_type');
    }
    final state = FocusedFillState.values
        .where((s) => s.name == json['fillState'])
        .firstOrNull;
    if (state == null ||
        !RegExp(
          r'^sha256:[0-9a-f]{64}$',
        ).hasMatch(json['fingerprint'] as String? ?? '')) {
      throw const CredentialUseFailure('invalid_plan');
    }
    DateTime? time(String key) =>
        json[key] == null ? null : DateTime.parse(json[key] as String).toUtc();
    final result = FocusedFillOperation(
      id: _useId(json['fillId'], 'fillId'),
      requestId: _useId(json['requestId'], 'requestId'),
      operationId: _useId(json['operationId'], 'operationId'),
      fingerprint: json['fingerprint'] as String,
      createdAt: time('createdAt')!,
      application: FocusedFillApplication.fromJson(
        json['application'] as Map<String, dynamic>,
      ),
      state: state,
      inputReleased: json['inputReleased'] as bool,
      errorCode: json['errorCode'] as String?,
      finishedAt: time('finishedAt'),
      checkedAt: time('checkedAt'),
      restoredAt: time('restoredAt'),
      attentionAcknowledgedAt: time('attentionAcknowledgedAt'),
    );
    if ((state == FocusedFillState.checking) != (result.finishedAt == null) ||
        {FocusedFillState.sent, FocusedFillState.partial}.contains(state) &&
            !result.inputReleased ||
        result.errorCode != null &&
            !focusedFillErrorCodes.contains(result.errorCode)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (json['status'] !=
            (state == FocusedFillState.checking ? 'accepted' : 'ok') ||
        result.attentionAcknowledgedAt != null &&
            !{
              FocusedFillState.partial,
              FocusedFillState.unknown,
            }.contains(state)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return result;
  }
  FocusedFillOperation changed(Map<String, Object?> values) {
    final json = <String, dynamic>{...toStorageJson(), ...values};
    json['status'] = json['fillState'] == 'checking' ? 'accepted' : 'ok';
    return FocusedFillOperation.fromStorageJson(json);
  }
}

const focusedFillErrorCodes = {
  'desktop_locked',
  'session_unavailable',
  'unsupported_desktop',
  'unsupported_target',
  'focus_changed',
  'modifier_active',
  'application_changed',
  'access_denied',
  'audit_unavailable',
  'busy',
  'grant_expired',
  'grant_revoked',
  'credential_expired',
  'credential_disabled',
  'credential_deleted',
  'credential_version_changed',
  'material_prepare_failed',
  'unsupported_secret',
  'fill_unknown',
  'service_unavailable',
  'input_rejected',
  'input_partial',
  'target_unavailable',
};

/// Atomic typed fill audit. Implementations must preserve existing command
/// records when committing fill records and vice versa. Old schema repositories
/// do not implement this capability and cannot accept a focused-fill request.
abstract interface class FocusedFillRuntimeRepository
    implements CredentialRuntimeRepository {
  List<FocusedFillOperation> get focusedFillOperations;
  Future<void> commitFocusedFillRuntime(
    List<CredentialUseRequest> requests,
    List<FocusedFillOperation> operations, {
    void Function()? validate,
    List<CredentialExecution>? executions,
  });
}

typedef FocusedFillApplicationInspector =
    Future<FocusedFillApplication> Function(FocusedFillApplication application);
Future<FocusedFillApplication> inspectFocusedFillApplication(
  FocusedFillApplication requested,
) async {
  try {
    // Portable history can describe either platform. A local inspector cannot
    // interpret a foreign path using its own drive/root or filesystem rules.
    if (requested._windowsPath ? !Platform.isWindows : !Platform.isMacOS) {
      throw const CredentialUseFailure('unsupported_desktop');
    }
    final file = File(await File(requested.executable).resolveSymbolicLinks());
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file) {
      throw const CredentialUseFailure('application_changed');
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final after = await file.stat();
    if (digest != requested.sha256 ||
        before.size != after.size ||
        before.modified != after.modified) {
      throw const CredentialUseFailure('application_changed');
    }
    return FocusedFillApplication.fromJson({
      'executable': file.path,
      'sha256': digest,
    });
  } on CredentialUseFailure {
    rethrow;
  } on Object {
    throw const CredentialUseFailure('application_changed');
  }
}

/// Native complexity is hidden here. prepare reads technical properties only;
/// input is permitted solely through sendBatch after a durable service audit.
abstract interface class FocusedFillDriver {
  Future<PreparedFocusedFill> prepare(FocusedFillApplication application);
}

abstract interface class FocusedFillDiscoveryDriver
    implements FocusedFillDriver {
  Future<FocusedFillTarget> inspectTarget();
}

class FocusedFillTargetQuery {
  const FocusedFillTargetQuery._();
  factory FocusedFillTargetQuery.fromJson(Map<String, dynamic> json) {
    if (_useProtocol(json) != 2) {
      throw const CredentialUseFailure('unsupported_protocol');
    }
    _useShape(json, {'protocolVersion', 'command'});
    if (json['command'] != 'focus-target') {
      throw const CredentialUseFailure('invalid_plan');
    }
    return const FocusedFillTargetQuery._();
  }
}

/// Readiness is a point-in-time observation, never an input reservation, grant
/// or a website-origin assertion. Native/control/process identities stay local.
class FocusedFillTarget {
  const FocusedFillTarget.ready(FocusedFillApplication this.application)
    : errorCode = null;
  const FocusedFillTarget.refused(this.errorCode) : application = null;
  final FocusedFillApplication? application;
  final String? errorCode;
  Map<String, Object?> toJson() => {
    'protocolVersion': 2,
    'status': 'ok',
    'targetState': application == null ? 'refused' : 'ready',
    if (application != null) 'application': application!.toJson(),
    if (application == null)
      'errorCode': focusedFillErrorCodes.contains(errorCode)
          ? errorCode
          : 'unsupported_target',
  };
  factory FocusedFillTarget.fromJson(Map<String, dynamic> json) {
    _useShape(
      json,
      {'protocolVersion', 'status', 'targetState'},
      {'application', 'errorCode'},
    );
    if (_useProtocol(json) != 2 || json['status'] != 'ok') {
      throw const CredentialUseFailure('invalid_type');
    }
    if (json['targetState'] == 'ready' &&
        json['application'] is Map<String, dynamic> &&
        !json.containsKey('errorCode')) {
      return FocusedFillTarget.ready(
        FocusedFillApplication.fromJson(
          json['application'] as Map<String, dynamic>,
        ),
      );
    }
    if (json['targetState'] == 'refused' &&
        !json.containsKey('application') &&
        focusedFillErrorCodes.contains(json['errorCode'])) {
      return FocusedFillTarget.refused(json['errorCode'] as String);
    }
    throw const CredentialUseFailure('invalid_type');
  }
}

abstract interface class PreparedFocusedFill {
  FocusedFillApplication get application;
  Future<FocusedFillBatchResult> sendBatch(List<int> utf16CodeUnits);

  /// Idempotent cancellation/disposal; must release any desktop reservation.
  Future<void> close();
}

class FocusedFillBatchResult {
  const FocusedFillBatchResult(this.state, [this.errorCode]);
  final FocusedFillState state;
  final String? errorCode;
}
