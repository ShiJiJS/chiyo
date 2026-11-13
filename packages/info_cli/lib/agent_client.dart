import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';
import 'package:info_remote/agent_connection.dart';
import 'macos_bundled_tools.dart';
import 'windows_bundled_tools.dart';
import 'credential_output_filter.dart';
import 'device_information_files.dart';
import 'device_credential_journal.dart';
import 'runtime_worker_command.dart';
import 'device_credential_host.dart';
import 'device_focused_fill_host.dart';
import 'agent_help.dart';
part 'credential_runtime_client.dart';
part 'credential_program_client.dart';
part 'information_file_client.dart';
part 'credential_import_client.dart';
part 'information_import_client.dart';

class AgentClient {
  AgentClient(
    this.port, {
    String? sessionSecret,
    this.sourceAgent = '通用 CLI',
    this.requireSubmissionMetadata = false,
    String externalChatId = '',
    CredentialProcessStarter? credentialProcessStarter,
    this.hostedCredentialExecutions = false,
    String? runtimeWorkerExecutable,
    AgentConnectionProfile? connection,
    this.deviceFileStateDirectory,
    this.focusedFillHostDirectory,
  }) : _session = sessionSecret,
       _externalChatId = externalChatId,
       _remote = connection == null || connection.isLocal
           ? null
           : AgentConnection(connection),
       _local = connection != null && connection.isLocal
           ? AgentConnection(connection)
           : null,
       _runtimeWorkerExecutable = runtimeWorkerExecutable,
       _usesDefaultCredentialStarter = credentialProcessStarter == null,
       _credentialProcessStarter =
           credentialProcessStarter ??
           ((exe, argv, cwd, env) => _startCredentialProcess(
             exe,
             argv,
             cwd,
             env,
             workerExecutable: runtimeWorkerExecutable,
           ));
  factory AgentClient.remote(
    AgentConnectionProfile profile, {
    String? sessionSecret,
    String sourceAgent = '通用 CLI',
    bool requireSubmissionMetadata = false,
    String externalChatId = '',
    bool hostedCredentialExecutions = false,
    Directory? deviceFileStateDirectory,
    Directory? focusedFillHostDirectory,
    String? runtimeWorkerExecutable,
  }) => AgentClient(
    profile.address.port,
    sessionSecret: sessionSecret,
    sourceAgent: sourceAgent,
    requireSubmissionMetadata: requireSubmissionMetadata,
    externalChatId: externalChatId,
    hostedCredentialExecutions: hostedCredentialExecutions,
    connection: profile,
    deviceFileStateDirectory: deviceFileStateDirectory,
    focusedFillHostDirectory: focusedFillHostDirectory,
    runtimeWorkerExecutable: runtimeWorkerExecutable,
  );
  final Directory? deviceFileStateDirectory;
  final Directory? focusedFillHostDirectory;
  DeviceFocusedFillClient get _focusedFillHost => DeviceFocusedFillClient(
    _remote!.profile,
    directory: focusedFillHostDirectory,
  );
  DeviceCredentialJournal? get _deviceCredentialJournal =>
      _remote != null && deviceFileStateDirectory != null
      ? DeviceCredentialJournal(
          _remote.profile,
          Directory(
            '${deviceFileStateDirectory!.absolute.parent.path}/credential-executions',
          ),
        )
      : null;
  late final Future<void> _deviceFileMaintenance =
      _remote != null && deviceFileStateDirectory != null
      ? DeviceInformationFiles(
          _remote.profile,
          deviceFileStateDirectory!,
          workerExecutable: _runtimeWorkerExecutable,
        ).maintain()
      : Future<void>.value();
  final AgentConnection? _remote, _local;
  final bool hostedCredentialExecutions;
  final String? _runtimeWorkerExecutable;
  final CredentialProcessStarter _credentialProcessStarter;
  final bool _usesDefaultCredentialStarter;
  late final _credentialExecutions = _CredentialRuntimeExecutor(this);
  late final _programExecutions = _CredentialProgramExecutor(this);
  Future<void> drainCredentialExecutions() async {
    await Future.wait([
      _credentialExecutions.drain(),
      _programExecutions.drain(),
    ]);
  }

  final int port;
  final String sourceAgent;

  /// Shipping CLI entry points require current submission metadata. Embedders
  /// may retain the legacy protocol while migrating their existing commands.
  final bool requireSubmissionMetadata;
  String _externalChatId;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  String? _session;
  String? _endCapability;

  /// Private capability, for trusted adapters only. Never include in diagnostics.
  String? get sessionSecret => _session;
  String? get endCapability => _endCapability;
  Future<Map<String, dynamic>> endLifecycleSession(
    String capability, {
    Duration timeout = const Duration(seconds: 5),
  }) => _call('/session/end', {'endCapability': capability}, timeout: timeout);
  final _tokens = <String, String>{};

  /// Trusted hook bootstrap only; creates a fresh, unapproved session.
  /// Ordinary CLI commands retain the original response contract.
  Future<Map<String, dynamic>> openLifecycleSession(String label) async {
    if (_session != null) return {'status': 'invalid_request'};
    final result = await _call('/session/lifecycle', {'chatLabel': label});
    final secret = result.remove('sessionSecret');
    final endCapability = result.remove('endCapability');
    if (result['status'] == 'ok' &&
        secret is String &&
        endCapability is String) {
      _session = secret;
      _endCapability = endCapability;
    }
    return result;
  }

  void close() {
    _tokens.clear();
    _session = null;
    _endCapability = null;
    _http.close(force: true);
    _remote?.close();
    _local?.close();
  }

  Future<Map<String, dynamic>> execute(
    Map<String, dynamic> input, {
    bool maintainDeviceState = true,
    Map<String, ({String sha256, int byteLength})>? checkedSourceFiles,
  }) async {
    if (input['command'] == 'help' && input.length == 1) {
      return agentCommandHelp();
    }
    if (maintainDeviceState) {
      try {
        await _deviceFileMaintenance;
      } on Object {
        // Preserve failed cleanup journals. An unrelated catalog/proposal must
        // still work; file fetch/release rechecks its own journal and fails closed.
      }
      try {
        await _deviceCredentialJournal?.maintain();
      } on Object {
        // Failed/uncertain cleanup remains journaled; it cannot authorize a new
        // launch or turn unrelated catalog queries into material delivery.
      }
    }
    final command = input['command'];
    const submissions = {
      'request',
      'request-use',
      'request-reveal',
      'organize-request',
      'import-submit',
      'update-submit',
      'delete-submit',
      'program-request',
    };
    if (_session != null &&
        (requireSubmissionMetadata || input.containsKey('submissionVersion')) &&
        submissions.contains(command)) {
      input = {
        ...input,
        'submissionVersion': input.containsKey('submissionVersion')
            ? input['submissionVersion']
            : 1,
        'agentName': input['agentName'] ?? sourceAgent,
        'externalChatId': input['externalChatId'] ?? _externalChatId,
      };
      final errors = submissionMetadataErrors(
        input,
        proposal: const {
          'organize-request',
          'import-submit',
          'update-submit',
          'delete-submit',
        }.contains(command),
      );
      if (errors.isNotEmpty) {
        return {
          'status': 'invalid_request',
          'errorCode': 'invalid_submission_metadata',
          'message': '请补齐提交说明；标题和说明中不要填写密码或 Token。',
          'fieldErrors': errors,
        };
      }
      final support = await _call('/capabilities', {});
      if (support['status'] != 'ok') return support;
      if (!(support['capabilities'] as List? ?? []).contains(
        'submission-metadata.v1',
      )) {
        return {
          'status': 'unsupported_capability',
          'message': '服务器暂不支持新的提交说明，请更新服务器后重试。',
        };
      }
    }
    if ({
      'program-request',
      'program-run',
      'program-status',
      'program-output',
      'program-cleanup',
    }.contains(command)) {
      return _executeProgramCommand(input);
    }
    if (command == 'request-reveal' || command == 'read-reveal') {
      if (_session == null) return {'status': 'unauthorized'};
      final capabilities = await _call('/capabilities', {});
      if (!(capabilities['capabilities'] as List? ?? []).contains(
            'credential-reveal.v1',
          ) ||
          command == 'request-reveal' &&
              input.containsKey('operationId') &&
              !(capabilities['capabilities'] as List? ?? []).contains(
                'credential-reveal-operations.v1',
              )) {
        return Map<String, dynamic>.from(
          const CredentialUseFailure(
            'unsupported_capability',
          ).toJson(protocolVersion: 2),
        );
      }
      if (utf8.encode(jsonEncode(input)).length > 16384) {
        return {'status': 'invalid_request', 'errorCode': 'limit_exceeded'};
      }
      return _call(
        command == 'request-reveal'
            ? '/credential-reveal/request'
            : '/credential-reveal/read',
        {...input, 'sessionSecret': _session},
      );
    }
    if ({'file-fetch', 'file-status', 'file-release'}.contains(command)) {
      return _executeInformationFileCommand(input);
    }
    if ({
      'request-use',
      'run-use',
      'operation-status',
      'execution-status',
      'execution-output',
      'cleanup-use',
      'fill-use',
      'fill-status',
      'focus-target',
    }.contains(command)) {
      return _executeCredentialCommand(input);
    }
    if (utf8.encode(jsonEncode(input)).length >
        (command == 'proposals-check' ||
                command == 'import-submit' ||
                command == 'import-revise'
            ? 6000000
            : command == 'credential-catalog' ||
                  command == 'update-submit' ||
                  command == 'update-revise' ||
                  command == 'organize-submit'
            ? 262144
            : 16384)) {
      return command == 'credential-catalog'
          ? {
              'protocolVersion': 1,
              'status': 'invalid_request',
              'errorCode': 'limit_exceeded',
              'retryable': false,
            }
          : {'status': 'invalid_request'};
    }
    switch (command) {
      case 'requests-list':
      case 'requests-show':
      case 'proposals-list':
      case 'operations-list':
      case 'operations-show':
        if (_session == null) return {'status': 'unauthorized'};
        final allowed = switch (command) {
          'requests-list' ||
          'proposals-list' => {'command', 'kind', 'state', 'offset', 'limit'},
          'operations-list' => {'command', 'requestId', 'offset', 'limit'},
          _ => {'command', 'id'},
        };
        if (input.keys.any((k) => !allowed.contains(k))) {
          return {'status': 'invalid_query'};
        }
        final support = await _call('/capabilities', {});
        if (support['status'] != 'ok') return support;
        if (!(support['capabilities'] as List? ?? const []).contains(
          'agent-record-queries.v1',
        )) {
          return {'status': 'unsupported_capability'};
        }
        return _call('/${(command as String).replaceAll('-', '/')}', {
          'sessionSecret': _session,
          for (final entry in input.entries)
            if (entry.key != 'command') entry.key: entry.value,
        });
      case 'capabilities':
        if (input.keys.any((k) => k != 'command')) {
          return Map<String, dynamic>.from(
            const CredentialUseFailure('unknown_field').toJson(),
          );
        }
        final result = await _call('/capabilities', {});
        if (_remote != null &&
            (Platform.isMacOS || Platform.isWindows) &&
            result['status'] == 'ok') {
          final focused = await _focusedFillHost.execute(null, {
            'command': 'capabilities',
          });
          final tools = Platform.isWindows
              ? await WindowsBundledTools().read()
              : await MacBundledTools().read();
          return {
            ...result,
            'capabilities': [
              ...result['capabilities'] as List,
              ...focused['capabilities'] as List? ?? const [],
              'credential-tools.v1',
            ],
            'supportedCredentialReceivers': [
              for (final receiver in CredentialLaunchPlan.supportedReceivers)
                if ((result['supportedCredentialReceivers'] as List? ??
                        const [])
                    .contains(receiver))
                  receiver,
            ],
            'credentialToolScope': 'current_device',
            'credentialTools': tools.map((t) => t.toJson()).toList(),
          };
        }
        return result;
      case 'import-file-status':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/import-file/status', {
          'sessionSecret': _session,
          'operationId': input['operationId'],
        });
      case 'plugin-list':
        if (input.length != 1) return {'status': 'invalid_request'};
        return _call('/plugins/catalog', {});
      case 'directory-list':
        if (input.length != 1) return {'status': 'invalid_request'};
        return _call('/directories/catalog', {});
      case 'template-list':
        if (input.keys.any(
          (k) => !{'command', 'packageId', 'offset', 'limit'}.contains(k),
        )) {
          return {'status': 'invalid_request'};
        }
        return _call('/templates/catalog', {
          for (final key in ['packageId', 'offset', 'limit'])
            if (input.containsKey(key)) key: input[key],
        });
      case 'proposals-check':
        if (_session == null) return {'status': 'unauthorized'};
        if (input.keys.any((k) => !{'command', 'kind', 'input'}.contains(k))) {
          return {'status': 'invalid_request'};
        }
        return _call('/proposals/check', {
          'sessionSecret': _session,
          'kind': input['kind'],
          'input': input['input'],
        });
      case 'template-read':
        if (input.length != 2 || input['templateId'] is! String) {
          return {'status': 'invalid_request'};
        }
        return _call('/templates/read', {'templateId': input['templateId']});
      case 'credential-catalog':
        if (input.keys.any(
          (k) => !{
            'command',
            'cursor',
            'limit',
            'query',
            'directoryId',
          }.contains(k),
        )) {
          return {
            'protocolVersion': 1,
            'status': 'invalid_request',
            'errorCode': 'unknown_field',
            'retryable': false,
          };
        }
        if (input['query'] != null || input['directoryId'] != null) {
          final support = await _call('/capabilities', {});
          if (support['status'] != 'ok') return support;
          if (!(support['capabilities'] as List? ?? const []).contains(
            'credential-catalog-search.v1',
          )) {
            return {'status': 'unsupported_capability'};
          }
        }
        if (input['cursor'] != null && input['cursor'] is! String ||
            input.containsKey('limit') &&
                (input['limit'] is! int ||
                    (input['limit'] as int) < 1 ||
                    (input['limit'] as int) > 100)) {
          return {
            'protocolVersion': 1,
            'status': 'invalid_request',
            'errorCode': 'invalid_type',
            'retryable': false,
          };
        }
        return _call('/credentials/catalog', {
          'cursor': input['cursor'],
          'limit': input['limit'] ?? 50,
          if (input.containsKey('query')) 'query': input['query'],
          if (input.containsKey('directoryId'))
            'directoryId': input['directoryId'],
        });
      case 'organize-request':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/request', {
          'sessionSecret': _session,
          'purpose': input['purpose'],
          'itemIds': input['itemIds'],
          'agentName': input['agentName'] ?? sourceAgent,
          ..._submissionFields(input, proposal: true),
        });
      case 'organize-status':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/status', {
          'sessionSecret': _session,
          'taskId': input['taskId'],
        });
      case 'organize-wait':
        if (_session == null) return {'status': 'unauthorized'};
        final timeout = input['timeoutMs'] ?? 30000;
        if (timeout is! int || timeout < 0 || timeout > 300000) {
          return {'status': 'invalid_request'};
        }
        final watch = Stopwatch()..start();
        while (true) {
          final status = await _call('/organization/status', {
            'sessionSecret': _session,
            'taskId': input['taskId'],
          });
          if (status['status'] != 'pending') return status;
          if (watch.elapsedMilliseconds >= timeout) {
            return {...status, 'waitTimedOut': true};
          }
          await Future<void>.delayed(
            Duration(
              milliseconds: (timeout - watch.elapsedMilliseconds).clamp(1, 250),
            ),
          );
        }
      case 'organize-tasks':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/tasks', {'sessionSecret': _session});
      case 'organize-metadata':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/metadata', {
          'sessionSecret': _session,
          'taskId': input['taskId'],
        });
      case 'organize-submit':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/submit', {
          'sessionSecret': _session,
          'taskId': input['taskId'],
          'changes': input['changes'],
        });
      case 'delete-submit':
        if (_session == null) return {'status': 'unauthorized'};
        if (input.containsKey('operationId')) {
          final support = await _call('/capabilities', {});
          if (support['status'] != 'ok') return support;
          if (!(support['capabilities'] as List? ?? []).contains(
            'information-delete-operations.v1',
          )) {
            return {'status': 'unsupported_capability'};
          }
        }
        return _call('/delete/submit', {
          'sessionSecret': _session,
          'itemId': input['itemId'],
          'baseVersion': input['baseVersion'],
          ..._submissionFields(input, proposal: true),
          if (input['fieldId'] != null) 'fieldId': input['fieldId'],
          if (input.containsKey('operationId'))
            'operationId': input['operationId'],
        });
      case 'delete-status':
        if (_session == null) return {'status': 'unauthorized'};
        if (input.containsKey('operationId')) {
          if (input.containsKey('proposalId')) {
            return {'status': 'invalid_request'};
          }
          final support = await _call('/capabilities', {});
          if (support['status'] != 'ok') return support;
          if (!(support['capabilities'] as List? ?? []).contains(
            'information-delete-operations.v1',
          )) {
            return {'status': 'unsupported_capability'};
          }
          return _call('/delete/status', {
            'sessionSecret': _session,
            'operationId': input['operationId'],
          });
        }
        return _call('/delete/status', {
          'sessionSecret': _session,
          'proposalId': input['proposalId'],
        });
      case 'update-submit':
        return _executeUpdateCommand(
          input,
          revise: false,
          checkedSourceFiles: checkedSourceFiles,
        );
      case 'update-status':
        if (_session == null) return {'status': 'unauthorized'};
        if (input.containsKey('operationId')) {
          if (input.containsKey('proposalId')) {
            return {'status': 'invalid_request'};
          }
          final support = await _call('/capabilities', {});
          if (support['status'] != 'ok') return support;
          if (!(support['capabilities'] as List? ?? []).contains(
            'information-update-operations.v1',
          )) {
            return {'status': 'unsupported_capability'};
          }
          return _call('/update/status', {
            'sessionSecret': _session,
            'operationId': input['operationId'],
          });
        }
        return _call('/update/status', {
          'sessionSecret': _session,
          'proposalId': input['proposalId'],
        });
      case 'update-revise':
        return _executeUpdateCommand(input, revise: true);
      case 'import-submit':
        return _executeImportCommand(
          input,
          revise: false,
          checkedSourceFiles: checkedSourceFiles,
        );
      case 'import-status':
        if (_session == null) return {'status': 'unauthorized'};
        if (input.containsKey('operationId')) {
          if (input.containsKey('proposalId')) {
            return {'status': 'invalid_request'};
          }
          final support = await _call('/capabilities', {});
          if (support['status'] != 'ok') return support;
          if (!(support['capabilities'] as List? ?? []).contains(
            'information-import-operations.v1',
          )) {
            return {'status': 'unsupported_capability'};
          }
          return _call('/import/status', {
            'sessionSecret': _session,
            'operationId': input['operationId'],
          });
        }
        return _call('/import/status', {
          'sessionSecret': _session,
          'proposalId': input['proposalId'],
        });
      case 'import-revise':
        return _executeImportCommand(input, revise: true);
      case 'catalog':
        return _call('/catalog', {
          'protocolVersion': input['protocolVersion'] ?? 2,
          for (final key in [
            'query',
            'typeId',
            'directoryId',
            'tagId',
            'offset',
            'limit',
          ])
            if (input.containsKey(key)) key: input[key],
        });
      case 'session':
        if (_session != null) return {'status': 'invalid_request'};
        if (input.containsKey('externalChatId') &&
            (input['externalChatId'] is! String ||
                !validSubmissionMetadata(
                  externalChatId: input['externalChatId'] as String,
                ))) {
          return {
            'status': 'invalid_request',
            'fieldErrors': {'externalChatId': '聊天标识格式无效。'},
          };
        }
        final result = await _call('/session', {
          'chatLabel': input['chatLabel'],
        });
        final secret = result.remove('sessionSecret');
        final endCapability = result.remove('endCapability');
        if (result['status'] == 'ok' && secret is String) {
          _session = secret;
          if (input['externalChatId'] is String) {
            _externalChatId = input['externalChatId'] as String;
          }
        }
        if (result['status'] == 'ok' && endCapability is String) {
          _endCapability = endCapability;
        }
        return result;
      case 'session-check':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/session/check', {'sessionSecret': _session});
      case 'session-close':
        if (_session == null || input.length != 1) {
          return {'status': 'unauthorized'};
        }
        return _call('/session/close', {'sessionSecret': _session});
      case 'request':
      case 'request-status':
        if (_session == null) return {'status': 'unauthorized'};
        final operation = input['operationId'];
        final hasOperation = input.containsKey('operationId');
        if (hasOperation || command == 'request-status') {
          if (operation is! String ||
              !RegExp(
                r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
              ).hasMatch(operation)) {
            return {'status': 'invalid_request'};
          }
          // Old servers ignore unknown request fields. Verify support before
          // sending an idempotent intent; never silently create duplicates.
          final support = await _call('/capabilities', {});
          if (support['status'] != 'ok') return support;
          if (support['capabilities'] is! List ||
              !(support['capabilities'] as List).contains(
                'information-request-operations.v1',
              )) {
            return {'status': 'unsupported_capability'};
          }
        }
        if (command == 'request-status') {
          return _call('/request/status', {
            'sessionSecret': _session,
            'operationId': operation,
          });
        }
        final result = await _call('/request', {
          'protocolVersion': input['protocolVersion'] ?? 2,
          'sessionSecret': _session,
          'purpose': input['purpose'],
          'fields': input['fields'],
          ..._submissionFields(input),
          if (hasOperation) 'operationId': operation,
        });
        if (result['status'] == 'service_unavailable') {
          return {
            'status': 'request_unknown',
            if (hasOperation) 'operationId': operation,
          };
        }
        return result;
      case 'status':
      case 'cancel':
      case 'claim':
        if (_session == null) return {'status': 'unauthorized'};
        final id = input['requestId'];
        if (id is! String) return {'status': 'invalid_request'};
        final result = await _call('/$command', {
          'sessionSecret': _session,
          'requestId': id,
        });
        final token = result.remove('token');
        if (command == 'claim' && result['status'] == 'ok' && token is String) {
          _tokens[id] = token;
        }
        return result;
      case 'wait':
        if (_session == null) return {'status': 'unauthorized'};
        final id = input['requestId'];
        final timeout = input['timeoutMs'] ?? 30000;
        if (id is! String ||
            timeout is! int ||
            timeout < 0 ||
            timeout > 300000) {
          return {'status': 'invalid_request'};
        }
        final elapsed = Stopwatch()..start();
        while (true) {
          final result = await _call('/status', {
            'sessionSecret': _session,
            'requestId': id,
          });
          if (result['status'] != 'pending') return result;
          final remaining = timeout - elapsed.elapsedMilliseconds;
          if (remaining <= 0) return {...result, 'waitTimedOut': true};
          await Future<void>.delayed(
            Duration(milliseconds: remaining < 250 ? remaining : 250),
          );
        }
      case 'read':
        final token = _tokens[input['requestId']];
        if (token == null) return {'status': 'unauthorized'};
        return _call('/read', {
          'token': token,
          'itemId': input['itemId'],
          'fieldId': input['fieldId'],
        });
      default:
        return {'status': 'invalid_request'};
    }
  }

  Future<Map<String, dynamic>> _call(
    String path,
    Map<String, dynamic> data, {
    Duration? timeout,
  }) async {
    final transport = _remote ?? _local;
    if (transport != null) {
      return transport.call(
        path,
        data,
        timeout: timeout ?? AgentConnection.defaultRequestTimeout,
      );
    }
    try {
      return await (() async {
        final request = await _http.post('127.0.0.1', port, path);
        request.headers.contentType = ContentType.json;
        request.followRedirects = false;
        request.write(jsonEncode(data));
        final response = await request.close();
        final text = await utf8.decoder.bind(response).join();
        return jsonDecode(text) as Map<String, dynamic>;
      })().timeout(timeout ?? const Duration(seconds: 5));
    } on Object {
      return {'status': 'service_unavailable'};
    }
  }

  Map<String, dynamic> _submissionFields(
    Map<String, dynamic> input, {
    bool proposal = false,
  }) => {
    for (final key in [
      'submissionVersion',
      'agentName',
      'externalChatId',
      if (proposal) 'title',
      if (proposal) 'purpose',
    ])
      if (input.containsKey(key)) key: input[key],
  };
}
