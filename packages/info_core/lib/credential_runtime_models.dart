part of 'info_core.dart';

String? _useTimestamp(DateTime? value) => value == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(
        value.millisecondsSinceEpoch,
        isUtc: true,
      ).toIso8601String();

class CredentialUseFailure implements Exception {
  const CredentialUseFailure(
    this.code, {
    this.fieldPath,
    this.attemptConsumed = false,
    this.executionId,
  });
  final String code;
  final String? fieldPath, executionId;
  final bool attemptConsumed;
  Map<String, Object?> toJson({int protocolVersion = 1}) => {
    'protocolVersion': protocolVersion,
    'status': switch (code) {
      'session_required' ||
      'session_mismatch' ||
      'scope_not_approved' => 'unauthorized',
      'request_denied' => 'denied',
      'grant_expired' || 'credential_expired' => 'expired',
      'grant_revoked' ||
      'credential_disabled' ||
      'credential_deleted' => 'revoked',
      'request_pending' ||
      'request_terminal' ||
      'attempt_consumed' ||
      'credential_version_changed' ||
      'executable_changed' ||
      'plan_changed' ||
      'operation_conflict' ||
      'fill_needs_attention' ||
      'fill_unknown' ||
      'execution_unknown' ||
      'cleanup_busy' ||
      'cleanup_failed' ||
      'cleanup_identity_mismatch' => 'conflict',
      'audit_unavailable' ||
      'service_unavailable' ||
      'execution_capacity' => 'service_unavailable',
      'busy' => 'service_unavailable',
      _ => 'invalid_request',
    },
    'errorCode': code,
    'retryable':
        !attemptConsumed &&
        {
          'audit_unavailable',
          'service_unavailable',
          'execution_capacity',
          'cleanup_busy',
          'busy',
        }.contains(code),
    if (protocolVersion == 1)
      'attemptConsumed': attemptConsumed
    else
      'operationClaimed': attemptConsumed,
    if (fieldPath != null) 'fieldPath': fieldPath,
    if (executionId != null) 'executionId': executionId,
  };
  @override
  String toString() => 'CredentialUseFailure($code)';
}

void _useShape(
  Map<String, dynamic> j,
  Set<String> required, [
  Set<String> optional = const {},
]) {
  if (j.keys.any((k) => !required.contains(k) && !optional.contains(k))) {
    throw const CredentialUseFailure('unknown_field');
  }
  if (!j.keys.toSet().containsAll(required)) {
    throw const CredentialUseFailure('invalid_type');
  }
}

String _useText(
  Object? value,
  String path, {
  int max = 8192,
  bool empty = true,
}) {
  if (value is! String) {
    throw CredentialUseFailure('invalid_type', fieldPath: path);
  }
  if (value.contains('\u0000') ||
      value.length > max ||
      !empty && value.isEmpty) {
    throw CredentialUseFailure('invalid_plan', fieldPath: path);
  }
  return value;
}

String _useId(Object? value, String path) {
  final text = _useText(value, path, max: 128, empty: false);
  if (!RegExp(r'^[!-~]+$').hasMatch(text)) {
    throw CredentialUseFailure('invalid_reference', fieldPath: path);
  }
  return text;
}

String _useAlias(Object? value, String path) {
  final text = _useText(value, path, max: 64, empty: false);
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(text)) {
    throw CredentialUseFailure('invalid_reference', fieldPath: path);
  }
  return text;
}

enum LaunchValueKind { literal, file, secret, internalMaterial }

class LaunchValue {
  const LaunchValue(this.kind, this.value);
  final LaunchValueKind kind;
  final String value;
  factory LaunchValue.parse(
    Object? raw,
    String path, {
    required bool environment,
    bool allowInternal = false,
  }) {
    if (raw is String) {
      return LaunchValue(LaunchValueKind.literal, _useText(raw, path));
    }
    if (raw is! Map<String, dynamic> || raw.length != 1) {
      throw CredentialUseFailure('invalid_type', fieldPath: path);
    }
    final kind = raw.keys.single;
    if (allowInternal && kind == 'internalMaterial') {
      return LaunchValue(
        LaunchValueKind.internalMaterial,
        _useAlias(raw.values.single, path),
      );
    }
    if (kind != 'file' && (kind != 'secret' || !environment)) {
      throw CredentialUseFailure('invalid_reference', fieldPath: path);
    }
    return LaunchValue(
      kind == 'file' ? LaunchValueKind.file : LaunchValueKind.secret,
      _useAlias(raw.values.single, path),
    );
  }
  Object toJson() =>
      kind == LaunchValueKind.literal ? value : {kind.name: value};
}

int _useProtocol(Map<String, dynamic> json) {
  if (!json.containsKey('protocolVersion')) return 1;
  final raw = json['protocolVersion'];
  if (raw is int && (raw == 1 || raw == 2)) return raw;
  throw const CredentialUseFailure('unsupported_protocol');
}

String _useFingerprint(Object? value) {
  Object? ordered(Object? v) => v is Map
      ? {
          for (final key in (v.keys.cast<String>().toList()..sort()))
            key: ordered(v[key]),
        }
      : v is List
      ? v.map(ordered).toList()
      : v;
  return 'sha256:${sha256.convert(utf8.encode(jsonEncode(ordered(value))))}';
}

/// Non-secret caller plan. No grant or execution material is carried here.
class CredentialOperationInput {
  CredentialOperationInput._(this.requestId, this.operationId, this.launch);
  final String requestId, operationId;
  final CredentialLaunchPlan launch;
  Map<String, Object?> toJson() => {
    'protocolVersion': 2,
    'command': 'run-use',
    'requestId': requestId,
    'operationId': operationId,
    'launch': launch.toJson(),
  };
  factory CredentialOperationInput.fromJson(Map<String, dynamic> json) {
    if (_useProtocol(json) != 2) {
      throw const CredentialUseFailure('unsupported_protocol');
    }
    _useShape(json, {
      'protocolVersion',
      'command',
      'requestId',
      'operationId',
      'launch',
    });
    if (json['command'] != 'run-use') {
      throw const CredentialUseFailure('invalid_plan');
    }
    final launch = json['launch'];
    if (launch is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_type', fieldPath: 'launch');
    }
    return CredentialOperationInput._(
      _useId(json['requestId'], 'requestId'),
      _useId(json['operationId'], 'operationId'),
      CredentialLaunchPlan.parse(launch),
    );
  }
  String get fingerprint =>
      _useFingerprint({'requestId': requestId, 'launch': launch.toJson()});
}

class CredentialUseInput {
  CredentialUseInput._(
    this.purpose,
    this.alias,
    this.credentialId,
    this.version,
    this.launch,
    this.readFields,
    this.protocolVersion,
  );
  final String purpose, alias, credentialId;
  final int version;
  final int protocolVersion;
  final CredentialLaunchPlan launch;
  final List<FieldRef> readFields;
  factory CredentialUseInput.fromJson(Map<String, dynamic> j) {
    final protocolVersion = _useProtocol(j);
    _useShape(
      j,
      {'command', 'purpose', 'credentials', 'launch'},
      {'readFields', 'protocolVersion'},
    );
    if (j['command'] != 'request-use') {
      throw const CredentialUseFailure('invalid_plan');
    }
    final purpose = _useText(j['purpose'], 'purpose', max: 2000, empty: false);
    if (purpose.trim().isEmpty) {
      throw const CredentialUseFailure('invalid_plan', fieldPath: 'purpose');
    }
    final credentials = j['credentials'];
    if (credentials is! List ||
        credentials.length != 1 ||
        credentials.single is! Map<String, dynamic>) {
      throw const CredentialUseFailure(
        'invalid_type',
        fieldPath: 'credentials',
      );
    }
    final c = credentials.single as Map<String, dynamic>;
    _useShape(c, {'alias', 'credentialId', 'version'});
    final version = c['version'];
    if (version is! int || version < 1 || version > 2147483647) {
      throw const CredentialUseFailure(
        'invalid_type',
        fieldPath: 'credentials[0].version',
      );
    }
    final launch = j['launch'];
    if (launch is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_type', fieldPath: 'launch');
    }
    final rawFields = j.containsKey('readFields') ? j['readFields'] : const [];
    if (rawFields is! List) {
      throw const CredentialUseFailure('invalid_type', fieldPath: 'readFields');
    }
    if (rawFields.length > 200) {
      throw const CredentialUseFailure(
        'limit_exceeded',
        fieldPath: 'readFields',
      );
    }
    final fields = <FieldRef>[];
    for (final raw in rawFields) {
      if (raw is! Map<String, dynamic>) {
        throw const CredentialUseFailure(
          'invalid_type',
          fieldPath: 'readFields',
        );
      }
      _useShape(raw, {'itemId', 'fieldId'});
      fields.add(
        FieldRef(
          _useId(raw['itemId'], 'readFields.itemId'),
          _useId(raw['fieldId'], 'readFields.fieldId'),
        ),
      );
    }
    if (fields.toSet().length != fields.length) {
      throw const CredentialUseFailure(
        'invalid_reference',
        fieldPath: 'readFields',
      );
    }
    return CredentialUseInput._(
      purpose,
      _useAlias(c['alias'], 'credentials[0].alias'),
      _useId(c['credentialId'], 'credentials[0].credentialId'),
      version,
      CredentialLaunchPlan.parse(launch),
      List.unmodifiable(fields),
      protocolVersion,
    );
  }
}

typedef CredentialExecutableInspector =
    Future<ExecutableIdentity> Function(String path, String receiver);

class ExecutableIdentity {
  const ExecutableIdentity(
    this.path,
    this.byteLength,
    this.modifiedMicros,
    this.sha256,
  );
  final String path, sha256;
  final int byteLength, modifiedMicros;
  Map<String, Object?> toJson() => {
    'path': path,
    'byteLength': byteLength,
    'modifiedMicros': modifiedMicros,
    'sha256': sha256,
  };
  factory ExecutableIdentity.fromJson(Map<String, dynamic> j) =>
      ExecutableIdentity(
        j['path'] as String,
        j['byteLength'] as int,
        j['modifiedMicros'] as int,
        j['sha256'] as String,
      );
}

Future<ExecutableIdentity> inspectCredentialExecutable(
  String path,
  String receiver,
) async {
  Directory? probe;
  try {
    final file = File(path);
    final canonical = await file.resolveSymbolicLinks();
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw const CredentialUseFailure(
        'invalid_plan',
        fieldPath: 'launch.executable',
      );
    }
    final name = canonical.split(RegExp(r'[/\\]')).last.toLowerCase();
    final names = switch (receiver) {
      'gh_token' => {'gh', 'gh.exe'},
      'aws_shared_credentials' => {'aws', 'aws.exe'},
      'ssh_identity' => {'ssh', 'ssh.exe'},
      _ => <String>{},
    };
    if (!names.contains(name)) {
      throw const CredentialUseFailure('unsupported_tool_version');
    }
    probe = await Directory.systemTemp.createTemp('info-tool-probe-');
    final environment = <String, String>{
      'HOME': probe.path,
      'USERPROFILE': probe.path,
      'APPDATA': probe.path,
      'LOCALAPPDATA': probe.path,
      'XDG_CONFIG_HOME': probe.path,
      'XDG_STATE_HOME': probe.path,
      'GH_CONFIG_DIR': probe.path,
      if (Platform.isWindows) 'ProgramData': probe.path,
      if (Platform.isWindows)
        'WINDIR': Platform.environment['SystemRoot'] ?? '',
      if (Platform.isWindows)
        'SystemRoot': Platform.environment['SystemRoot'] ?? '',
      if (Platform.isWindows) 'TEMP': probe.path,
      if (Platform.isWindows) 'TMP': probe.path,
      if (!Platform.isWindows) 'PATH': '/usr/bin:/bin',
      if (!Platform.isWindows) 'LANG': 'C.UTF-8',
      if (!Platform.isWindows) 'TMPDIR': probe.path,
    };
    final result = await Process.run(
      canonical,
      [receiver == 'ssh_identity' ? '-V' : '--version'],
      workingDirectory: probe.path,
      // An empty environment block is rejected by CreateProcess on this
      // Windows runtime (error 87). Retain only the system loader location,
      // never the invoking process's authentication/configuration variables.
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    ).timeout(const Duration(seconds: 5));
    final version = switch (receiver) {
      'gh_token' => r'^gh version 2\.102\.0(?:\s|$)',
      'aws_shared_credentials' => r'^aws-cli/2\.38\.1(?:\s|$)',
      _ => r'^OpenSSH_for_Windows_9\.5p2(?:,|\s|$)',
    };
    if (result.exitCode != 0 ||
        !RegExp(version).hasMatch(
          (receiver == 'ssh_identity' ? result.stderr : result.stdout)
              as String,
        )) {
      throw const CredentialUseFailure('unsupported_tool_version');
    }
    return ExecutableIdentity(
      canonical,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
      'sha256:${sha256.convert(await file.readAsBytes())}',
    );
  } on CredentialUseFailure {
    rethrow;
  } on Object {
    throw const CredentialUseFailure(
      'invalid_plan',
      fieldPath: 'launch.executable',
    );
  } finally {
    if (probe != null) {
      try {
        final actual = await probe.resolveSymbolicLinks();
        final parent = await Directory.systemTemp.resolveSymbolicLinks();
        final comparable = Platform.isWindows ? actual.toLowerCase() : actual;
        final expected = Platform.isWindows
            ? probe.path.toLowerCase()
            : probe.path;
        final prefix =
            '${Platform.isWindows ? parent.toLowerCase() : parent}${Platform.pathSeparator}';
        if (comparable == expected && comparable.startsWith(prefix)) {
          await probe.delete(recursive: true);
        }
      } on FileSystemException {
        // A failed private cache cleanup does not reveal submitted values.
      }
    }
  }
}

class CredentialLaunchPlan {
  CredentialLaunchPlan._(
    this.receiver,
    this.path,
    this.argv,
    this.cwd,
    this.env, {
    this.identity,
    this.sshTrustSnapshotId,
    Map<String, String> internalMaterialHashes = const {},
  }) : internalMaterialHashes = Map.unmodifiable(internalMaterialHashes);
  final String receiver, path, cwd;
  final List<LaunchValue> argv;
  final Map<String, LaunchValue> env;
  final ExecutableIdentity? identity;
  final String? sshTrustSnapshotId;
  final Map<String, String> internalMaterialHashes;
  ExecutableIdentity get executable => identity!;
  factory CredentialLaunchPlan.parse(
    Map<String, dynamic> j, {
    bool allowInternal = false,
    bool allowPortablePaths = false,
  }) {
    _useShape(j, {'receiver', 'executable', 'argv', 'cwd', 'env'});
    final receiver = _useText(
      j['receiver'],
      'launch.receiver',
      max: 64,
      empty: false,
    );
    if (!{
      'gh_token',
      'ssh_identity',
      'aws_shared_credentials',
    }.contains(receiver)) {
      throw const CredentialUseFailure('unsupported_receiver');
    }
    final path = _useText(
      j['executable'],
      'launch.executable',
      max: 4096,
      empty: false,
    );
    final cwd = _useText(j['cwd'], 'launch.cwd', max: 4096, empty: false);
    bool absolute(String p) => allowPortablePaths
        ? p.startsWith('/') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(p)
        : Platform.isWindows
        ? RegExp(r'^[A-Za-z]:[/\\]').hasMatch(p)
        : p.startsWith('/');
    if (!absolute(path) || !absolute(cwd)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final a = j['argv'], e = j['env'];
    if (a is! List || e is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_type');
    }
    if (a.length > 128 || e.length > 32) {
      throw const CredentialUseFailure('limit_exceeded');
    }
    if (e.keys.map((k) => k.toLowerCase()).toSet().length != e.length) {
      throw const CredentialUseFailure('invalid_env');
    }
    return CredentialLaunchPlan._(
      receiver,
      path,
      List.unmodifiable([
        for (var i = 0; i < a.length; i++)
          LaunchValue.parse(
            a[i],
            'launch.argv[$i]',
            environment: false,
            allowInternal: allowInternal,
          ),
      ]),
      cwd,
      Map.unmodifiable({
        for (final entry in e.entries)
          _useAlias(entry.key, 'launch.env'): LaunchValue.parse(
            entry.value,
            'launch.env.${entry.key}',
            environment: true,
            allowInternal: allowInternal,
          ),
      }),
    );
  }
  CredentialLaunchPlan resolved(ExecutableIdentity identity, String cwd) =>
      CredentialLaunchPlan._(
        receiver,
        identity.path,
        argv,
        cwd,
        env,
        identity: identity,
        sshTrustSnapshotId: sshTrustSnapshotId,
        internalMaterialHashes: internalMaterialHashes,
      );
  CredentialLaunchPlan withDelivery({
    List<LaunchValue>? argv,
    Map<String, LaunchValue>? env,
  }) => CredentialLaunchPlan._(
    receiver,
    path,
    List.unmodifiable(argv ?? this.argv),
    cwd,
    Map.unmodifiable(env ?? this.env),
    identity: identity,
    sshTrustSnapshotId: sshTrustSnapshotId,
    internalMaterialHashes: internalMaterialHashes,
  );
  CredentialLaunchPlan withSshTrust(SshHostTrustSnapshot trust) =>
      CredentialLaunchPlan._(
        receiver,
        path,
        argv,
        cwd,
        env,
        identity: identity,
        sshTrustSnapshotId: trust.id,
        internalMaterialHashes: {
          'ssh_known_hosts': trust.sha256,
          'ssh_config': 'sha256:${_runtimeSha256(const [])}',
          'ssh_global_known_hosts': 'sha256:${_runtimeSha256(const [])}',
        },
      );
  Map<String, Object?> toJson() => {
    'receiver': receiver,
    'executable': path,
    'argv': argv.map((v) => v.toJson()).toList(),
    'cwd': cwd,
    'env': {for (final e in env.entries) e.key: e.value.toJson()},
    if (identity != null) 'executableIdentity': identity!.toJson(),
    if (sshTrustSnapshotId != null) 'sshTrustSnapshotId': sshTrustSnapshotId,
    if (internalMaterialHashes.isNotEmpty)
      'internalMaterialHashes': internalMaterialHashes,
  };
  factory CredentialLaunchPlan.fromStorageJson(Map<String, dynamic> j) {
    final shape = Map<String, dynamic>.from(j)
      ..remove('executableIdentity')
      ..remove('sshTrustSnapshotId')
      ..remove('internalMaterialHashes');
    // Archived plans describe another device's past facts. Request parsing
    // still requires this OS's absolute paths and runtime revalidates tools.
    final plan = CredentialLaunchPlan.parse(
      shape,
      allowInternal: true,
      allowPortablePaths: true,
    );
    final resolved = plan.resolved(
      ExecutableIdentity.fromJson(
        j['executableIdentity'] as Map<String, dynamic>,
      ),
      plan.cwd,
    );
    return CredentialLaunchPlan._(
      resolved.receiver,
      resolved.path,
      resolved.argv,
      resolved.cwd,
      resolved.env,
      identity: resolved.identity,
      sshTrustSnapshotId: j['sshTrustSnapshotId'] as String?,
      internalMaterialHashes:
          (j['internalMaterialHashes'] as Map?)?.cast<String, String>() ??
          const {},
    );
  }
  String get planHash {
    Object? ordered(Object? v) => v is Map
        ? {
            for (final key in (v.keys.cast<String>().toList()..sort()))
              key: ordered(v[key]),
          }
        : v is List
        ? v.map(ordered).toList()
        : v;
    return 'sha256:${sha256.convert(utf8.encode(jsonEncode(ordered(toJson()))))}';
  }
}

class CredentialUseRequest {
  CredentialUseRequest({
    this.protocolVersion = 1,
    required this.id,
    required this.chatLabel,
    required this.purpose,
    required this.alias,
    required this.credentialId,
    required this.version,
    required this.useGeneration,
    CredentialLaunchPlan? plan,
    FocusedFillPlan? fill,
    this.requestedPlan,
    required this.createdAt,
    required this.requestExpiresAt,
    required Iterable<FieldRef> fields,
    this.state = 'pending',
    this.credentialApproved = false,
    Iterable<FieldRef> approvedFields = const [],
    this.credentialExpiresAt,
    this.fieldExpiresAt,
    this.executionId,
    this.attemptConsumed = false,
    this.invalidatedCode,
    this.credentialName,
    this.decidedAt,
    this.revokedAt,
    this.attemptedAt,
    this.restoredAt,
  }) : specification = _credentialSpecification(
         protocolVersion,
         plan,
         fill,
         requestedPlan,
         fields,
       ),
       fields = List.unmodifiable(fields),
       approvedFields = List.unmodifiable(approvedFields);
  final String id, chatLabel, purpose, alias, credentialId, state;
  final int version, useGeneration;
  final int protocolVersion;
  final CredentialUseSpecification specification;
  bool get isFocusedFill => specification is CredentialFocusedFillSpecification;
  FocusedFillPlan? get focusedFill => switch (specification) {
    CredentialFocusedFillSpecification(:final plan) => plan,
    _ => null,
  };

  /// Compatibility accessor for existing command consumers. A fill has no
  /// launch plan; dispatch on specification instead of inventing one.
  CredentialLaunchPlan get plan => switch (specification) {
    CredentialCommandSpecification(:final plan) => plan,
    _ => throw const CredentialUseFailure('scope_not_approved'),
  };
  String get usePlanHash => focusedFill?.planHash ?? plan.planHash;
  final CredentialLaunchPlan? requestedPlan;
  final DateTime createdAt, requestExpiresAt;
  final List<FieldRef> fields, approvedFields;
  final bool credentialApproved, attemptConsumed;
  final DateTime? credentialExpiresAt, fieldExpiresAt;
  final String? executionId, invalidatedCode;
  final String? credentialName;
  final DateTime? decidedAt, revokedAt, attemptedAt;
  final DateTime? restoredAt;
  Map<String, Object?> toJson() => {
    if (protocolVersion != 1) 'protocolVersion': protocolVersion,
    'id': id,
    'chatLabel': chatLabel,
    'purpose': purpose,
    'alias': alias,
    'credentialId': credentialId,
    'version': version,
    'useGeneration': useGeneration,
    if (isFocusedFill) ...{
      'useKind': 'focused_fill',
      'fill': focusedFill!.toJson(),
    } else
      'plan': plan.toJson(),
    if (requestedPlan != null) 'requestedPlan': requestedPlan!.toJson(),
    'createdAt': _useTimestamp(createdAt),
    'requestExpiresAt': _useTimestamp(requestExpiresAt),
    'fields': fields.map((f) => f.toJson()).toList(),
    'state': state,
    'credentialApproved': credentialApproved,
    'approvedFields': approvedFields.map((f) => f.toJson()).toList(),
    'credentialExpiresAt': _useTimestamp(credentialExpiresAt),
    'fieldExpiresAt': _useTimestamp(fieldExpiresAt),
    'executionId': executionId,
    'attemptConsumed': attemptConsumed,
    'invalidatedCode': invalidatedCode,
    'credentialName': credentialName,
    'decidedAt': _useTimestamp(decidedAt),
    'revokedAt': _useTimestamp(revokedAt),
    'attemptedAt': _useTimestamp(attemptedAt),
    if (restoredAt != null) 'restoredAt': _useTimestamp(restoredAt),
  };
  factory CredentialUseRequest.fromJson(Map<String, dynamic> j) =>
      CredentialUseRequest(
        protocolVersion: _useProtocol(j),
        id: j['id'] as String,
        chatLabel: j['chatLabel'] as String,
        purpose: j['purpose'] as String,
        alias: j['alias'] as String,
        credentialId: j['credentialId'] as String,
        version: j['version'] as int,
        useGeneration: j['useGeneration'] as int,
        plan: _storedFocusedFill(j)
            ? null
            : CredentialLaunchPlan.fromStorageJson(
                j['plan'] as Map<String, dynamic>,
              ),
        fill: _storedFocusedFill(j)
            ? FocusedFillPlan.fromJson(j['fill'] as Map<String, dynamic>)
            : null,
        requestedPlan: j['requestedPlan'] == null
            ? null
            : CredentialLaunchPlan.fromStorageJson(
                j['requestedPlan'] as Map<String, dynamic>,
              ),
        createdAt: DateTime.parse(j['createdAt'] as String),
        requestExpiresAt: DateTime.parse(j['requestExpiresAt'] as String),
        fields: (j['fields'] as List).map(
          (dynamic f) =>
              FieldRef(f['itemId'] as String, f['fieldId'] as String),
        ),
        state: j['state'] as String,
        credentialApproved: j['credentialApproved'] as bool,
        approvedFields: (j['approvedFields'] as List).map(
          (dynamic f) =>
              FieldRef(f['itemId'] as String, f['fieldId'] as String),
        ),
        credentialExpiresAt: j['credentialExpiresAt'] == null
            ? null
            : DateTime.parse(j['credentialExpiresAt'] as String),
        fieldExpiresAt: j['fieldExpiresAt'] == null
            ? null
            : DateTime.parse(j['fieldExpiresAt'] as String),
        executionId: j['executionId'] as String?,
        attemptConsumed: j['attemptConsumed'] as bool,
        invalidatedCode: j['invalidatedCode'] as String?,
        credentialName: j['credentialName'] as String?,
        decidedAt: j['decidedAt'] == null
            ? null
            : DateTime.parse(j['decidedAt'] as String),
        revokedAt: j['revokedAt'] == null
            ? null
            : DateTime.parse(j['revokedAt'] as String),
        attemptedAt: j['attemptedAt'] == null
            ? null
            : DateTime.parse(j['attemptedAt'] as String),
        restoredAt: j['restoredAt'] == null
            ? null
            : DateTime.parse(j['restoredAt'] as String),
      );
  CredentialUseRequest changed(Map<String, Object?> values) =>
      CredentialUseRequest.fromJson({...toJson(), ...values});
  Map<String, Object?> toStorageJson() => toJson();
  Map<String, Object?> toRequestInputJson() => {
    'protocolVersion': protocolVersion,
    'command': 'request-use',
    'purpose': purpose,
    'credentials': [
      {'alias': alias, 'credentialId': credentialId, 'version': version},
    ],
    if (isFocusedFill)
      'fill': focusedFill!.toJson()
    else
      'launch': Map<String, Object?>.from((requestedPlan ?? plan).toJson())
        ..remove('executableIdentity'),
    'readFields': fields.map((f) => f.toJson()).toList(),
  };
}

class CredentialExecution {
  CredentialExecution({
    required this.id,
    required this.requestId,
    this.protocolVersion = 1,
    this.operationId,
    this.operationFingerprint,
    this.operationPlan,
    this.state = 'preparing',
    this.processStarted = false,
    this.exitCode,
    this.errorCode,
    this.startedAt,
    this.finishedAt,
    this.cleanupState = 'not_needed',
    this.pid,
    this.processCreatedAt,
    this.materialLease,
    this.jobName,
    this.supervisorPid,
    this.supervisorCreatedAt,
    this.workerPid,
    this.workerCreatedAt,
    this.createdAt,
    this.restoredAt,
  });
  final String id, requestId, state, cleanupState;
  final int protocolVersion;
  final String? operationId, operationFingerprint;
  final CredentialLaunchPlan? operationPlan;
  final bool processStarted;
  final int? exitCode, pid;
  final String? errorCode, processCreatedAt;
  final CredentialMaterialLease? materialLease;
  final String? jobName;
  final int? supervisorPid;
  final String? supervisorCreatedAt;
  final int? workerPid;
  final String? workerCreatedAt;
  final DateTime? startedAt, finishedAt;
  final DateTime? createdAt;
  final DateTime? restoredAt;
  Map<String, Object?> toJson() => {
    'protocolVersion': protocolVersion,
    if (protocolVersion == 2) 'operationId': operationId,
    if (protocolVersion == 2 && createdAt != null)
      'createdAt': _useTimestamp(createdAt),
    'status': 'ok',
    'executionId': id,
    'requestId': requestId,
    'executionState': state,
    if (protocolVersion == 1)
      'attemptConsumed': true
    else
      'operationClaimed': true,
    'processStarted': processStarted,
    'exitCode': exitCode,
    'errorCode': errorCode,
    'startedAt': _useTimestamp(startedAt),
    'finishedAt': _useTimestamp(finishedAt),
    'cleanupState': cleanupState,
    'outputAvailable': false,
    'outputTruncated': false,
    if (restoredAt != null) 'restoredAt': _useTimestamp(restoredAt),
  };
  Map<String, Object?> toArchiveJson() => {
    ...toJson(),
    if (operationFingerprint != null)
      'operationFingerprint': operationFingerprint,
    if (operationPlan != null) 'operationPlan': operationPlan!.toJson(),
  };
  Map<String, Object?> toStorageJson() => {
    ...toArchiveJson(),
    'pid': pid,
    'processCreatedAt': processCreatedAt,
    if (materialLease != null) 'materialLease': materialLease!.toPrivateJson(),
    if (jobName != null) 'jobName': jobName,
    if (supervisorPid != null) 'supervisorPid': supervisorPid,
    if (supervisorCreatedAt != null) 'supervisorCreatedAt': supervisorCreatedAt,
    if (workerPid != null) 'workerPid': workerPid,
    if (workerCreatedAt != null) 'workerCreatedAt': workerCreatedAt,
  };
  factory CredentialExecution.fromJson(Map<String, dynamic> j) =>
      CredentialExecution(
        protocolVersion: _useProtocol(j),
        operationId: j['operationId'] as String?,
        operationFingerprint: j['operationFingerprint'] as String?,
        operationPlan: j['operationPlan'] == null
            ? null
            : CredentialLaunchPlan.fromStorageJson(
                j['operationPlan'] as Map<String, dynamic>,
              ),
        createdAt: j['createdAt'] == null
            ? null
            : DateTime.parse(j['createdAt'] as String),
        id: j['executionId'] as String,
        requestId: j['requestId'] as String,
        state: j['executionState'] as String,
        processStarted: j['processStarted'] as bool,
        exitCode: j['exitCode'] as int?,
        errorCode: j['errorCode'] as String?,
        startedAt: j['startedAt'] == null
            ? null
            : DateTime.parse(j['startedAt'] as String),
        finishedAt: j['finishedAt'] == null
            ? null
            : DateTime.parse(j['finishedAt'] as String),
        cleanupState: j['cleanupState'] as String,
        pid: j['pid'] as int?,
        processCreatedAt: j['processCreatedAt'] as String?,
        materialLease: j['materialLease'] == null
            ? null
            : CredentialMaterialLease.fromPrivateJson(
                j['materialLease'] as Map<String, dynamic>,
              ),
        jobName: j['jobName'] as String?,
        supervisorPid: j['supervisorPid'] as int?,
        supervisorCreatedAt: j['supervisorCreatedAt'] as String?,
        workerPid: j['workerPid'] as int?,
        workerCreatedAt: j['workerCreatedAt'] as String?,
        restoredAt: j['restoredAt'] == null
            ? null
            : DateTime.parse(j['restoredAt'] as String),
      );
  CredentialExecution changed(Map<String, Object?> values) =>
      CredentialExecution.fromJson({...toStorageJson(), ...values});
}

/// Only the first private claim contains material. Never encode this as a
/// generic response: use toPublicJson for agent-facing metadata.
class CredentialOperationClaim {
  CredentialOperationClaim(
    this.execution, {
    this.material,
    required this.grantState,
  });
  final CredentialExecution execution;
  final CredentialExecutionMaterial? material;
  final String grantState;
  bool get newlyClaimed => material != null;
  Map<String, Object?> toPublicJson() => {
    ...execution.toJson(),
    'grantState': grantState,
    'duplicate': !newlyClaimed,
  };
  Map<String, Object?> toPrivateJson() => {
    'protocolVersion': 2,
    'execution': execution.toStorageJson(),
    'grantState': grantState,
    'newlyClaimed': newlyClaimed,
    if (material != null) 'material': material!.toPrivateJson(),
  };
  factory CredentialOperationClaim.fromPrivateJson(Map<String, dynamic> json) {
    _useShape(
      json,
      {'protocolVersion', 'execution', 'grantState', 'newlyClaimed'},
      {'material'},
    );
    if (_useProtocol(json) != 2 ||
        json['newlyClaimed'] is! bool ||
        json['execution'] is! Map<String, dynamic> ||
        json['grantState'] is! String ||
        json.containsKey('material') &&
            json['material'] is! Map<String, dynamic> ||
        (json['newlyClaimed'] == true) != json.containsKey('material')) {
      throw const CredentialUseFailure('invalid_type');
    }
    final execution = CredentialExecution.fromJson(
      json['execution'] as Map<String, dynamic>,
    );
    final material = json.containsKey('material')
        ? CredentialExecutionMaterial.fromPrivateJson(
            json['material'] as Map<String, dynamic>,
          )
        : null;
    if (execution.protocolVersion != 2 ||
        execution.operationId == null ||
        execution.operationId!.isEmpty ||
        execution.operationFingerprint == null ||
        !RegExp(
          r'^sha256:[0-9a-f]{64}$',
        ).hasMatch(execution.operationFingerprint!) ||
        execution.operationPlan == null ||
        !{
          'available',
          'revoked',
          'expired',
          'not_approved',
          'version_invalidated',
        }.contains(json['grantState']) ||
        material != null &&
            (material.executionId != execution.id ||
                material.approvedPlan.planHash !=
                    execution.operationPlan!.planHash ||
                execution.state != 'preparing' ||
                execution.processStarted ||
                json['grantState'] != 'available')) {
      throw const CredentialUseFailure('invalid_reference');
    }
    return CredentialOperationClaim(
      execution,
      material: material,
      grantState: json['grantState'] as String,
    );
  }
}

class CredentialExecutionReport {
  const CredentialExecutionReport({
    required this.executionId,
    required this.executionCapability,
    required this.state,
    this.pid,
    this.processCreatedAt,
    this.exitCode,
    this.errorCode,
    this.startedAt,
    this.finishedAt,
    this.jobName,
  });
  final String executionId, executionCapability, state;
  final int? pid, exitCode;
  final String? processCreatedAt, errorCode;
  final String? jobName;
  final DateTime? startedAt, finishedAt;
  Map<String, Object?> toPrivateJson() => {
    'executionId': executionId,
    'executionCapability': executionCapability,
    'executionState': state,
    'pid': pid,
    'processCreatedAt': processCreatedAt,
    'exitCode': exitCode,
    'errorCode': errorCode,
    'startedAt': _useTimestamp(startedAt),
    'finishedAt': _useTimestamp(finishedAt),
    if (jobName != null) 'jobName': jobName,
  };
  factory CredentialExecutionReport.fromPrivateJson(Map<String, dynamic> j) {
    _useShape(
      j,
      {
        'executionId',
        'executionCapability',
        'executionState',
        'pid',
        'processCreatedAt',
        'exitCode',
        'errorCode',
        'startedAt',
        'finishedAt',
      },
      {'jobName'},
    );
    if (j['pid'] != null && j['pid'] is! int ||
        j['exitCode'] != null && j['exitCode'] is! int) {
      throw const CredentialUseFailure('invalid_type');
    }
    return CredentialExecutionReport(
      executionId: _useId(j['executionId'], 'executionId'),
      executionCapability: _useId(
        j['executionCapability'],
        'executionCapability',
      ),
      state: _useText(
        j['executionState'],
        'executionState',
        max: 32,
        empty: false,
      ),
      pid: j['pid'] as int?,
      processCreatedAt: j['processCreatedAt'] as String?,
      exitCode: j['exitCode'] as int?,
      errorCode: j['errorCode'] as String?,
      jobName: j['jobName'] as String?,
      startedAt: j['startedAt'] == null
          ? null
          : DateTime.parse(j['startedAt'] as String),
      finishedAt: j['finishedAt'] == null
          ? null
          : DateTime.parse(j['finishedAt'] as String),
    );
  }
}

abstract interface class CredentialRuntimeRepository {
  List<CredentialUseRequest> get credentialUseRequests;
  List<CredentialExecution> get credentialExecutions;

  /// A decision's field audit and runtime facts form one transaction. No session
  /// secret, read token or execution capability is part of this snapshot.
  Future<void> commitCredentialRuntime(
    List<CredentialUseRequest> requests,
    List<CredentialExecution> executions, {
    GrantHistory? fieldGrant,
    RequestHistory? fieldRequest,
    void Function()? validate,
  });
}

/// Private channel DTO. Deliberately has no ordinary JSON serialization.
class CredentialExecutionMaterial {
  CredentialExecutionMaterial(
    this.executionId,
    this.executionCapability,
    this.approvedPlan,
    this.credentialMaterial,
    this.alias, [
    this.materialLease,
    Map<String, List<int>> internalMaterials = const {},
    this.jobName,
  ]) : internalMaterials = Map.unmodifiable(
         internalMaterials.map(
           (key, value) => MapEntry(key, List<int>.unmodifiable(value)),
         ),
       );
  final String executionId, executionCapability, alias;
  final CredentialLaunchPlan approvedPlan;
  final CredentialMaterialValue credentialMaterial;
  final CredentialMaterialLease? materialLease;
  final Map<String, List<int>> internalMaterials;
  final String? jobName;
  Map<String, Object?> toPrivateJson() => {
    'protocolVersion': 1,
    'status': 'ok',
    'executionId': executionId,
    'executionCapability': executionCapability,
    'approvedPlan': approvedPlan.toJson(),
    'credentialMaterial': credentialMaterial.toPrivateJson(),
    'alias': alias,
    if (jobName != null) 'jobName': jobName,
    if (materialLease != null) 'materialLease': materialLease!.toPrivateJson(),
    if (internalMaterials.isNotEmpty)
      'internalMaterials': internalMaterials.map(
        (key, value) => MapEntry(key, base64Encode(value)),
      ),
  };
  factory CredentialExecutionMaterial.fromPrivateJson(Map<String, dynamic> j) =>
      CredentialExecutionMaterial(
        j['executionId'] as String,
        j['executionCapability'] as String,
        CredentialLaunchPlan.fromStorageJson(
          j['approvedPlan'] as Map<String, dynamic>,
        ),
        CredentialMaterialValue.fromPrivateJson(
          j['credentialMaterial'] as Map<String, dynamic>,
        ),
        j['alias'] as String,
        j['materialLease'] == null
            ? null
            : CredentialMaterialLease.fromPrivateJson(
                j['materialLease'] as Map<String, dynamic>,
              ),
        (j['internalMaterials'] as Map?)?.map(
              (key, value) =>
                  MapEntry(key as String, base64Decode(value as String)),
            ) ??
            const {},
        j['jobName'] as String?,
      );
  @override
  String toString() => 'CredentialExecutionMaterial($executionId)';
}

class CredentialMaterialValue {
  CredentialMaterialValue(
    this.credentialId,
    this.version,
    this.form,
    Iterable<int> bytes,
  ) : bytes = List.unmodifiable(bytes);
  final String credentialId;
  final int version;
  final CredentialForm form;
  final List<int> bytes;
  String get stringValue => utf8.decode(bytes);
  Map<String, Object?> toPrivateJson() => {
    'credentialId': credentialId,
    'version': version,
    'form': form.name,
    'bytesBase64': base64Encode(bytes),
  };
  factory CredentialMaterialValue.fromPrivateJson(Map<String, dynamic> j) =>
      CredentialMaterialValue(
        j['credentialId'] as String,
        j['version'] as int,
        CredentialForm.values.byName(j['form'] as String),
        base64Decode(j['bytesBase64'] as String),
      );
  @override
  String toString() => 'CredentialMaterialValue($credentialId,v$version)';
}
