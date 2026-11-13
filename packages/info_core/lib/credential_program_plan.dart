part of 'info_core.dart';

/// A credential reference names saved material directly. It is never a caller
/// alias, an arbitrary source file, or the actual password.
class CredentialProgramReference {
  const CredentialProgramReference._(this.credentialId, this.version);
  final String credentialId;
  final int? version;
  factory CredentialProgramReference.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'credentialId'}, {'version'});
    final version = json['version'];
    if (json.containsKey('version') && (version is! int || version < 1)) {
      throw const CredentialUseFailure('invalid_reference');
    }
    return CredentialProgramReference._(
      _useId(json['credentialId'], 'credentialId'),
      version as int?,
    );
  }
  Map<String, Object?> toJson() => {
    'credentialId': credentialId,
    if (version != null) 'version': version,
  };
  CredentialProgramReference withVersion(Map<String, int> currentVersions) {
    final fixed = version ?? currentVersions[credentialId];
    if (fixed == null || fixed < 1) {
      throw const CredentialUseFailure('credential_version_changed');
    }
    return CredentialProgramReference._(credentialId, fixed);
  }
}

enum CredentialProgramValueKind { literal, material, file }

class CredentialProgramValue {
  const CredentialProgramValue._(this.kind, this.literal, this.reference);
  final CredentialProgramValueKind kind;
  final String? literal;
  final CredentialProgramReference? reference;
  static CredentialProgramValue parse(
    Object? raw,
    String path, {
    required bool argument,
    bool stdin = false,
  }) {
    if (raw is String && !stdin) {
      return CredentialProgramValue._(
        CredentialProgramValueKind.literal,
        _useText(raw, path),
        null,
      );
    }
    if (raw is! Map<String, dynamic>) {
      throw CredentialUseFailure('invalid_type', fieldPath: path);
    }
    if (!stdin && raw.length == 1 && raw['file'] is Map<String, dynamic>) {
      return CredentialProgramValue._(
        CredentialProgramValueKind.file,
        null,
        CredentialProgramReference.fromJson(
          raw['file'] as Map<String, dynamic>,
        ),
      );
    }
    if (argument) {
      throw CredentialUseFailure('invalid_reference', fieldPath: path);
    }
    return CredentialProgramValue._(
      CredentialProgramValueKind.material,
      null,
      CredentialProgramReference.fromJson(raw),
    );
  }

  Object toJson() => switch (kind) {
    CredentialProgramValueKind.literal => literal!,
    CredentialProgramValueKind.material => reference!.toJson(),
    CredentialProgramValueKind.file => {'file': reference!.toJson()},
  };
  CredentialProgramValue withVersions(Map<String, int> currentVersions) =>
      reference == null
      ? this
      : CredentialProgramValue._(
          kind,
          null,
          reference!.withVersion(currentVersions),
        );
}

/// One real receiving position, such as DB_PASSWORD or argv[2]. The index/name
/// is part of the approved scope; no secret can be inserted into literal argv.
class CredentialProgramBinding {
  const CredentialProgramBinding._(this.location, this.via, this.reference);
  final String location, via;
  final CredentialProgramReference reference;
  factory CredentialProgramBinding.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'location', 'via', 'credentialId'}, {'version'});
    final location = json['location'], via = json['via'];
    if (location is! String ||
        !(location == 'stdin' && via == 'stdin' ||
            RegExp(
                  r'^argv\[(?:0|[1-9][0-9]?|1[01][0-9]|12[0-7])\]$',
                ).hasMatch(location) &&
                via == 'file' ||
            RegExp(r'^env\.[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(location) &&
                {'env', 'file'}.contains(via))) {
      throw const CredentialUseFailure('invalid_reference');
    }
    return CredentialProgramBinding._(
      location,
      via as String,
      CredentialProgramReference.fromJson({
        'credentialId': json['credentialId'],
        if (json.containsKey('version')) 'version': json['version'],
      }),
    );
  }
  bool acceptsForm(CredentialForm form) =>
      via == 'file' || form == CredentialForm.string;
  Map<String, Object?> toJson() => {
    'location': location,
    'via': via,
    ...reference.toJson(),
  };
  String get fingerprint => _useFingerprint(toJson());
}

/// A single process with any combination of typed environment, stdin and file
/// receivers. This non-secret module owns parsing, version freezing and scope
/// checks; the execution host owns material, private files and process lifetime.
class CredentialProgramPlan {
  CredentialProgramPlan._(
    this.path,
    this.cwd,
    Iterable<CredentialProgramValue> argv,
    Map<String, CredentialProgramValue> env,
    this.stdin, {
    this.identity,
  }) : argv = List.unmodifiable(argv),
       env = Map.unmodifiable(env);
  final String path, cwd;
  final List<CredentialProgramValue> argv;
  final Map<String, CredentialProgramValue> env;
  final CredentialProgramValue? stdin;
  final ExecutableIdentity? identity;
  factory CredentialProgramPlan.fromJson(
    Map<String, dynamic> json, {
    bool allowPortablePaths = false,
  }) {
    _useShape(json, {'executable', 'cwd', 'argv', 'env'}, {'stdin'});
    final path = _useText(
      json['executable'],
      'launch.executable',
      max: 4096,
      empty: false,
    );
    final cwd = _useText(json['cwd'], 'launch.cwd', max: 4096, empty: false);
    bool absolute(String value) =>
        (allowPortablePaths || Platform.isWindows) &&
            RegExp(r'^[A-Za-z]:[/\\]').hasMatch(value) ||
        (allowPortablePaths || !Platform.isWindows) && value.startsWith('/');
    final rawArgs = json['argv'], rawEnv = json['env'];
    if (!absolute(path) || !absolute(cwd)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    if (rawArgs is! List || rawEnv is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_type');
    }
    if (rawArgs.length > 128 ||
        rawEnv.length > 32 ||
        utf8.encode(jsonEncode(json)).length > 262144) {
      throw const CredentialUseFailure('limit_exceeded');
    }
    // Keep portable plans unambiguous on Windows as well as on macOS. Scope
    // matching still uses the actual, case-sensitive approved spelling.
    if (rawEnv.keys.map((k) => k.toLowerCase()).toSet().length !=
        rawEnv.length) {
      throw const CredentialUseFailure('invalid_env');
    }
    final plan = CredentialProgramPlan._(
      path,
      cwd,
      [
        for (var i = 0; i < rawArgs.length; i++)
          CredentialProgramValue.parse(
            rawArgs[i],
            'launch.argv[$i]',
            argument: true,
          ),
      ],
      {
        for (final entry in rawEnv.entries)
          _useAlias(entry.key, 'launch.env'): CredentialProgramValue.parse(
            entry.value,
            'launch.env.${entry.key}',
            argument: false,
          ),
      },
      json.containsKey('stdin')
          ? CredentialProgramValue.parse(
              json['stdin'],
              'launch.stdin',
              argument: false,
              stdin: true,
            )
          : null,
    );
    if (plan.bindings.isEmpty || plan.bindings.length > 20) {
      throw const CredentialUseFailure('limit_exceeded');
    }
    return plan;
  }
  List<CredentialProgramBinding> get bindings => [
    for (var i = 0; i < argv.length; i++)
      if (argv[i].reference case final r?)
        CredentialProgramBinding._('argv[$i]', 'file', r),
    for (final entry in env.entries)
      if (entry.value.reference case final r?)
        CredentialProgramBinding._(
          'env.${entry.key}',
          entry.value.kind == CredentialProgramValueKind.file ? 'file' : 'env',
          r,
        ),
    if (stdin?.reference case final r?)
      CredentialProgramBinding._('stdin', 'stdin', r),
  ];
  CredentialProgramPlan withVersions(Map<String, int> currentVersions) =>
      CredentialProgramPlan._(
        path,
        cwd,
        argv.map((v) => v.withVersions(currentVersions)),
        {
          for (final entry in env.entries)
            entry.key: entry.value.withVersions(currentVersions),
        },
        stdin?.withVersions(currentVersions),
        identity: identity,
      );
  CredentialProgramPlan resolved(
    ExecutableIdentity executable,
    String directory,
  ) => CredentialProgramPlan._(
    executable.path,
    directory,
    argv,
    env,
    stdin,
    identity: executable,
  );
  Map<String, Object?> toJson() => {
    'executable': path,
    'cwd': cwd,
    'argv': argv.map((v) => v.toJson()).toList(),
    'env': {for (final entry in env.entries) entry.key: entry.value.toJson()},
    if (stdin != null) 'stdin': stdin!.toJson(),
    if (identity != null) 'executableIdentity': identity!.toJson(),
  };
  String get planHash => _useFingerprint(toJson());

  /// Only private Host transport and stored public plan facts contain the
  /// identity. Business input uses fromJson and cannot choose this snapshot.
  factory CredentialProgramPlan.fromPreparedJson(Map<String, dynamic> json) {
    final raw = Map<String, dynamic>.from(json)..remove('executableIdentity');
    final requested = CredentialProgramPlan.fromJson(
      raw,
      allowPortablePaths: true,
    );
    final prepared = DeviceCredentialLaunch.fromPrivateJson({
      'version': 1,
      'planHash': requested.planHash,
      'executable': json['executableIdentity'],
      'cwd': requested.cwd,
    });
    if (prepared.executable.path != requested.path) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return prepared.resolveProgram(requested);
  }

  /// A later command may use a subset of the originally requested receivers,
  /// but cannot move material, change versions or substitute a program. The
  /// caller must separately check every remaining binding's current approval.
  void requireApprovedScope(CredentialProgramPlan approved) {
    if (identity == null ||
        approved.identity == null ||
        _useFingerprint(identity!.toJson()) !=
            _useFingerprint(approved.identity!.toJson()) ||
        bindings.any((b) => b.reference.version == null) ||
        approved.bindings.any((b) => b.reference.version == null)) {
      throw const CredentialUseFailure('scope_not_approved');
    }
    final allowed = approved.bindings.map((b) => b.fingerprint).toSet();
    if (bindings.any((b) => !allowed.contains(b.fingerprint))) {
      throw const CredentialUseFailure('scope_not_approved');
    }
  }
}

class CredentialProgramDestination {
  const CredentialProgramDestination(this.executable, this.binding);
  final ExecutableIdentity executable;
  final CredentialProgramBinding binding;
  Map<String, Object?> toJson() => {
    'executable': executable.toJson(),
    'binding': binding.toJson(),
  };
  factory CredentialProgramDestination.fromJson(Map<String, dynamic> json) {
    _useShape(json, {'executable', 'binding'});
    if (json['binding'] is! Map<String, dynamic> ||
        json['executable'] is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_type');
    }
    // Reuse the established, portable identity validation without looking up a
    // Windows/Mac path on the NAS or accepting extra executable fields.
    final identity = ExecutableIdentity.fromPreparedJson(
      json['executable'] as Map<String, dynamic>,
    );
    return CredentialProgramDestination(
      identity,
      CredentialProgramBinding.fromJson(
        json['binding'] as Map<String, dynamic>,
      ),
    );
  }
}

List<CredentialBatchCandidate> _programCandidates(CredentialProgramPlan plan) {
  if (plan.identity == null) throw const CredentialUseFailure('invalid_plan');
  return [
    for (final b in plan.bindings)
      CredentialBatchCandidate(
        b.reference.credentialId,
        b.reference.version,
        CredentialBatchDestination._(
          'program',
          null,
          null,
          CredentialProgramDestination(plan.identity!, b),
        ),
      ),
  ];
}
