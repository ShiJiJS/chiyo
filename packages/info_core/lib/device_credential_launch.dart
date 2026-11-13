part of 'info_core.dart';

/// A non-secret tool/cwd snapshot prepared on the executing device. The server
/// validates receiver rules but never probes these paths on its own filesystem.
/// This is private Host transport, not a replacement for the Agent's plan.
final class DeviceCredentialLaunch {
  DeviceCredentialLaunch._(this.planHash, this.executable, this.cwd);
  final String planHash, cwd;
  final ExecutableIdentity executable;

  static Future<DeviceCredentialLaunch> prepare(
    CredentialLaunchPlan plan, {
    CredentialExecutableInspector inspector = inspectCredentialExecutable,
  }) => _prepare(plan.path, plan.cwd, plan.planHash, plan.receiver, inspector);

  static Future<DeviceCredentialLaunch> prepareProgram(
    CredentialProgramPlan plan, {
    CredentialExecutableInspector inspector = inspectCredentialExecutable,
  }) => _prepare(plan.path, plan.cwd, plan.planHash, 'program_env', inspector);

  static Future<DeviceCredentialLaunch> _prepare(
    String path,
    String directory,
    String planHash,
    String receiver,
    CredentialExecutableInspector inspector,
  ) async {
    final identity = await inspector(path, receiver);
    String cwd;
    try {
      cwd = await Directory(directory).resolveSymbolicLinks();
      if (!await Directory(cwd).exists()) throw const FormatException();
    } on Object {
      throw const CredentialUseFailure('invalid_plan', fieldPath: 'launch.cwd');
    }
    // Validate the same transport shape before sending it to the server.
    return DeviceCredentialLaunch.fromPrivateJson({
      'version': 1,
      'planHash': planHash,
      'executable': identity.toJson(),
      'cwd': cwd,
    });
  }

  CredentialProgramPlan resolveProgram(CredentialProgramPlan requested) {
    if (requested.identity != null || requested.planHash != planHash) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return requested.resolved(executable, cwd);
  }

  Map<String, Object?> toPrivateJson() => {
    'version': 1,
    'planHash': planHash,
    'executable': executable.toJson(),
    'cwd': cwd,
  };

  factory DeviceCredentialLaunch.fromPrivateJson(Map<String, dynamic> json) {
    _useShape(json, {'version', 'planHash', 'executable', 'cwd'});
    if (json['version'] != 1 ||
        json['planHash'] is! String ||
        !RegExp(
          r'^sha256:[0-9a-f]{64}$',
        ).hasMatch(json['planHash'] as String) ||
        json['executable'] is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final raw = json['executable'] as Map<String, dynamic>;
    _useShape(raw, {'path', 'byteLength', 'modifiedMicros', 'sha256'});
    final path = _useText(
      raw['path'],
      'launch.executable',
      max: 4096,
      empty: false,
    );
    final cwd = _useText(json['cwd'], 'launch.cwd', max: 4096, empty: false);
    bool absolute(String value) =>
        value.startsWith('/') || RegExp(r'^[A-Za-z]:[/\\]').hasMatch(value);
    if (!absolute(path) ||
        !absolute(cwd) ||
        raw['byteLength'] is! int ||
        (raw['byteLength'] as int) <= 0 ||
        raw['modifiedMicros'] is! int ||
        (raw['modifiedMicros'] as int) < 0 ||
        raw['sha256'] is! String ||
        !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(raw['sha256'] as String)) {
      throw const CredentialUseFailure('invalid_plan');
    }
    return DeviceCredentialLaunch._(
      json['planHash'] as String,
      ExecutableIdentity(
        path,
        raw['byteLength'] as int,
        raw['modifiedMicros'] as int,
        raw['sha256'] as String,
      ),
      cwd,
    );
  }

  CredentialLaunchPlan resolve(CredentialLaunchPlan requested) {
    if (requested.identity != null ||
        requested.planHash != planHash ||
        requested.internalMaterialHashes.isNotEmpty ||
        requested.sshTrustSnapshotId != null) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final names = switch (requested.receiver) {
      'gh_token' => {'gh', 'gh.exe'},
      'aws_shared_credentials' => {'aws', 'aws.exe'},
      'ssh_identity' => {'ssh', 'ssh.exe'},
      _ => <String>{},
    };
    if (!requested.isProgramReceiver &&
        !names.contains(
          executable.path.split(RegExp(r'[/\\]')).last.toLowerCase(),
        )) {
      throw const CredentialUseFailure('unsupported_tool_version');
    }
    return requested.resolved(executable, cwd);
  }
}
