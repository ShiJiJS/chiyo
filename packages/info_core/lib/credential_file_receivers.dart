part of 'info_core.dart';

/// Static default credentials only. Never evaluates credential_process, SSO,
/// profiles, interpolation, or source files supplied by the invoking account.
void validateAwsSharedCredentialFile(List<int> bytes) {
  try {
    var section = false;
    final values = <String, String>{};
    for (final raw in const LineSplitter().convert(
      utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), ''),
    )) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      if (line == '[default]' && !section) {
        section = true;
        continue;
      }
      final split = line.indexOf('=');
      if (!section || split < 1 || line.contains('\u0000')) {
        throw const FormatException();
      }
      final name = line.substring(0, split).trim().toLowerCase(),
          value = line.substring(split + 1).trim();
      if (!{
            'aws_access_key_id',
            'aws_secret_access_key',
            'aws_session_token',
          }.contains(name) ||
          values.containsKey(name) ||
          value.isEmpty) {
        throw const FormatException();
      }
      values[name] = value;
    }
    if (!values.containsKey('aws_access_key_id') ||
        !values.containsKey('aws_secret_access_key')) {
      throw const FormatException();
    }
  } on Object {
    throw const CredentialUseFailure('material_prepare_failed');
  }
}

extension _FileCredentialReceivers on InformationService {
  CredentialLaunchPlan _validateSshReceiver(
    CredentialUseInput input,
    ManagedCredential credential,
  ) {
    if (credential.form != CredentialForm.file) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final trust = _sshHostTrust;
    if (trust == null) throw const CredentialUseFailure('receiver_not_ready');
    final plan = input.launch;
    if (plan.env.isNotEmpty) throw const CredentialUseFailure('invalid_env');
    var tty = false, batch = false, identity = false, port = false;
    var destination = -1;
    for (var i = 0; i < plan.argv.length; i++) {
      final value = plan.argv[i];
      if (value.kind != LaunchValueKind.literal) {
        throw const CredentialUseFailure('invalid_reference');
      }
      if (value.value == '-T' && !tty) {
        tty = true;
        continue;
      }
      if (value.value == '-o' || value.value.startsWith('-o')) {
        final LaunchValue option;
        if (value.value == '-o') {
          if (++i >= plan.argv.length) {
            throw const CredentialUseFailure('invalid_plan');
          }
          option = plan.argv[i];
        } else {
          option = LaunchValue(
            LaunchValueKind.literal,
            value.value.substring(2),
          );
        }
        if (option.kind != LaunchValueKind.literal ||
            option.value.toLowerCase() != 'batchmode=yes' ||
            batch) {
          throw const CredentialUseFailure('invalid_plan');
        }
        batch = true;
        continue;
      }
      if (value.value == '-i' && !identity) {
        if (++i >= plan.argv.length ||
            plan.argv[i].kind != LaunchValueKind.file ||
            plan.argv[i].value != input.alias) {
          throw const CredentialUseFailure('invalid_reference');
        }
        identity = true;
        continue;
      }
      if (value.value == '-p' && !port) {
        if (++i >= plan.argv.length ||
            plan.argv[i].kind != LaunchValueKind.literal) {
          throw const CredentialUseFailure('invalid_plan');
        }
        final number = int.tryParse(plan.argv[i].value);
        if (number == null || number < 1 || number > 65535) {
          throw const CredentialUseFailure('invalid_plan');
        }
        port = true;
        continue;
      }
      if (value.value.startsWith('-') ||
          !RegExp(
            r'^[A-Za-z0-9_.-]+@(?:[A-Za-z0-9_.-]+|\[[0-9a-fA-F:]+\])$',
          ).hasMatch(value.value)) {
        throw const CredentialUseFailure('invalid_plan');
      }
      destination = i;
      break;
    }
    if (!tty ||
        !batch ||
        !identity ||
        destination < 0 ||
        destination + 1 >= plan.argv.length) {
      throw const CredentialUseFailure('invalid_plan');
    }
    final remote = plan.argv.skip(destination + 1).toList();
    if (remote.any((v) => v.kind != LaunchValueKind.literal || v.value.isEmpty)) {
      throw const CredentialUseFailure('invalid_reference');
    }
    String quote(String value) =>
        RegExp(r'^[A-Za-z0-9_./:@%+=,-]+$').hasMatch(value)
        ? value
        : "'${value.replaceAll("'", "'\"'\"'")}'";
    return plan
        .withDelivery(
          argv: [
            const LaunchValue(LaunchValueKind.literal, '-F'),
            const LaunchValue(LaunchValueKind.internalMaterial, 'ssh_config'),
            for (final option in [
              'IdentitiesOnly=yes',
              'IdentityAgent=none',
              'PasswordAuthentication=no',
              'KbdInteractiveAuthentication=no',
              'StrictHostKeyChecking=yes',
            ]) ...[
              const LaunchValue(LaunchValueKind.literal, '-o'),
              LaunchValue(LaunchValueKind.literal, option),
            ],
            const LaunchValue(LaunchValueKind.literal, '-o'),
            const LaunchValue(
              LaunchValueKind.internalMaterial,
              'ssh_user_hosts_option',
            ),
            const LaunchValue(LaunchValueKind.literal, '-o'),
            const LaunchValue(
              LaunchValueKind.internalMaterial,
              'ssh_global_hosts_option',
            ),
            ...plan.argv.take(destination + 1),
            LaunchValue(
              LaunchValueKind.literal,
              remote.map((v) => quote(v.value)).join(' '),
            ),
          ],
        )
        .withSshTrust(trust);
  }

  CredentialLaunchPlan _validateAwsReceiver(
    CredentialUseInput input,
    ManagedCredential credential,
  ) {
    final plan = input.launch;
    final binding = plan.env['AWS_SHARED_CREDENTIALS_FILE'];
    if (credential.form != CredentialForm.file ||
        binding?.kind != LaunchValueKind.file ||
        binding?.value != input.alias) {
      throw const CredentialUseFailure(
        'invalid_reference',
        fieldPath: 'launch.env.AWS_SHARED_CREDENTIALS_FILE',
      );
    }
    if (plan.env.length != 1) {
      throw const CredentialUseFailure('invalid_env', fieldPath: 'launch.env');
    }
    validateAwsSharedCredentialFile(
      _currentCredentialMaterial(credential).bytes,
    );
    if (plan.argv.any((v) => v.kind != LaunchValueKind.literal)) {
      throw const CredentialUseFailure(
        'invalid_reference',
        fieldPath: 'launch.argv',
      );
    }
    final argv = plan.argv.map((v) => v.value).toList();
    if (argv.isEmpty ||
        {
          'configure',
          'sso',
          'login',
          'sso-oidc',
          'cli-dev',
          'history',
          'help',
        }.contains(argv.first) ||
        argv.first.startsWith('-')) {
      throw const CredentialUseFailure(
        'invalid_plan',
        fieldPath: 'launch.argv',
      );
    }
    String? region;
    for (var i = 1; i < argv.length; i++) {
      final value = argv[i];
      if ({
        '--no-sign-request',
        '--cli-auto-prompt',
        '--no-verify-ssl',
      }.any((flag) => value == flag || value.startsWith('$flag='))) {
        throw const CredentialUseFailure(
          'invalid_plan',
          fieldPath: 'launch.argv',
        );
      }
      for (final flag in ['--region', '--profile', '--endpoint-url']) {
        if (value != flag && !value.startsWith('$flag=')) continue;
        final String argument;
        if (value == flag) {
          if (++i >= argv.length) {
            throw const CredentialUseFailure(
              'invalid_plan',
              fieldPath: 'launch.argv',
            );
          }
          argument = argv[i];
        } else {
          argument = value.substring(flag.length + 1);
        }
        if (flag == '--region') {
          if (region != null ||
              !RegExp(r'^[a-z]{2}(?:-[a-z0-9]+)+-\d+$').hasMatch(argument)) {
            throw const CredentialUseFailure(
              'invalid_plan',
              fieldPath: 'launch.argv',
            );
          }
          region = argument;
        } else if (flag == '--profile' && argument != 'default') {
          throw const CredentialUseFailure(
            'invalid_plan',
            fieldPath: 'launch.argv',
          );
        } else if (flag == '--endpoint-url') {
          final uri = Uri.tryParse(argument);
          if (uri == null ||
              uri.userInfo.isNotEmpty ||
              uri.host.isEmpty ||
              uri.fragment.isNotEmpty ||
              !(uri.scheme == 'https' ||
                  uri.scheme == 'http' &&
                      {'localhost', '127.0.0.1', '::1'}.contains(uri.host))) {
            throw const CredentialUseFailure(
              'invalid_plan',
              fieldPath: 'launch.argv',
            );
          }
        }
      }
    }
    if (region == null) {
      throw const CredentialUseFailure(
        'invalid_plan',
        fieldPath: 'launch.argv',
      );
    }
    return plan.withDelivery(
      env: {
        ...plan.env,
        'AWS_CONFIG_FILE': const LaunchValue(
          LaunchValueKind.internalMaterial,
          'aws_config',
        ),
        'AWS_EC2_METADATA_DISABLED': const LaunchValue(
          LaunchValueKind.literal,
          'true',
        ),
        'AWS_PAGER': const LaunchValue(LaunchValueKind.literal, ''),
        'AWS_CLI_AUTO_PROMPT': const LaunchValue(
          LaunchValueKind.literal,
          'off',
        ),
      },
    );
  }
}
