import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'agent_client.dart';
import 'chiyo_command_line.dart';
import 'chiyo_context.dart';
import 'chrome_browser_fill.dart';
import 'chiyo_intents.dart';
import 'chiyo_programs.dart';
import 'device_credential_batch_host.dart';
part 'chiyo_fill.dart';
part 'chiyo_proposals.dart';
part 'chiyo_reveal.dart';
part 'chiyo_exec.dart';

class ChiyoRunResult {
  const ChiyoRunResult(
    this.output,
    this.exitCode, {
    this.help,
    this.json = false,
  });
  final Map<String, Object?> output;
  final int exitCode;
  final String? help;
  final bool json;
  String render() {
    if (json) return jsonEncode(output);
    if (help != null) return help!;
    if (output['ok'] != true) {
      return (output['error'] as Map)['message'] as String;
    }
    // Structured human output keeps field names and full pagination visible.
    // No exception text, private context or transport credentials are included.
    return const JsonEncoder.withIndent('  ').convert(output['data']);
  }
}

class _PublicFailure implements Exception {
  const _PublicFailure(this.code, this.message, this.exitCode);
  final String code, message;
  final int exitCode;
}

/// Public CLI workflow. Host context and transport are internal to business
/// commands; help parses without touching configuration or opening a session.
class ChiyoCli {
  ChiyoCli({Map<String, String>? environment, Stream<List<int>>? input})
    : environment = environment ?? Platform.environment,
      input = input ?? stdin;
  final Map<String, String> environment;
  final Stream<List<int>> input;
  final _grammar = ChiyoCommandLine();

  Future<ChiyoRunResult> run(List<String> arguments) async {
    ChiyoInvocation? invocation;
    AgentClient? client;
    try {
      invocation = _grammar.parse(arguments);
      if (invocation.help != null) {
        return ChiyoRunResult(
          {
            'schemaVersion': 1,
            'ok': true,
            'data': {'help': invocation.help},
          },
          0,
          help: invocation.help,
          json: invocation.json,
        );
      }
      if (invocation.path == 'chat start') return await _start(invocation);
      if (invocation.path == 'browsers list') {
        final address = _required(invocation, 'browser');
        final data = await ChromeBrowserFill(address).pages();
        return _success(data, invocation);
      }
      final context = await _context(invocation);
      _activeContext = context;
      _intents = ChiyoIntentStore(
        Directory('${_contextFile!.parent.path}/chiyo-intents').absolute,
        chiyoIntentDigest({
          'session': context.secret,
          'connection': context.connection?.toPrivateJson(),
          'port': context.port,
        }),
      );
      client = context.client(
        stateDirectory: context.connection == null
            ? null
            : Directory('${_contextFile!.parent.path}/device-files'),
      );
      if (invocation.path == 'connection show' ||
          invocation.path == 'chat show') {
        final live = await client.execute({
          'command': 'session-check',
        }, maintainDeviceState: false);
        if (live['status'] != 'ok') return _protocol(live, invocation);
        return _success({'status': 'ok', ...context.publicStatus}, invocation);
      }
      if (invocation.path == 'doctor') {
        return await _doctor(invocation, context, client);
      }
      return _protocol(
        await _execute(invocation, client),
        invocation,
        executing: {
          'fill run',
          'exec run',
          'credentials reveal read',
          'access read',
        }.contains(invocation.path),
      );
    } on ChiyoUsageFailure catch (error) {
      return _failure(
        'invalid_usage',
        error.message,
        2,
        invocation?.json ?? arguments.contains('--json'),
      );
    } on ChiyoIntentFailure catch (error) {
      return _failure(
        error.code,
        error.code == 'operation_conflict'
            ? '原操作编号已经用于另一份内容，请核对原记录。'
            : '无法保存或核对本次操作，因此没有再次提交。请先查询原操作。',
        error.code == 'operation_conflict' ? 8 : 3,
        invocation?.json ?? false,
      );
    } on _PublicFailure catch (error) {
      return _failure(
        error.code,
        error.message,
        error.exitCode,
        invocation?.json ?? false,
      );
    } on BrowserFillFailure catch (error) {
      return _failure(
        error.code,
        '浏览器或指定页面不可用；请核对控制地址和标签页。',
        3,
        invocation?.json ?? false,
      );
    } on CredentialUseFailure catch (error) {
      return _failure(
        error.code,
        '凭据或目标参数不正确；请查看此命令的 --help。',
        2,
        invocation?.json ?? false,
      );
    } on Object {
      // Never echo paths, protocol bodies, private references or raw exceptions.
      return _failure(
        'context_unavailable',
        '当前聊天连接不可用；请检查本聊天的私有配置或运行 chiyo doctor。',
        3,
        invocation?.json ?? arguments.contains('--json'),
      );
    } finally {
      client?.close();
    }
  }

  File? _contextFile;
  late ChiyoIntentStore _intents;
  late ChiyoContext _activeContext;
  Future<ChiyoContext> _context(ChiyoInvocation i) async {
    final supplied =
        i.root['context'] as String? ?? environment['CHIYO_CONTEXT'];
    String? reference = supplied;
    if (i.root['context-stdin'] == true) {
      if (supplied != null) throw const ChiyoUsageFailure('只能提供一种聊天上下文来源。');
      final value = decodeProtocolObject(
        await _read(input, 16384),
        maxBytes: 16384,
      );
      if (value.length != 1 || value['association'] is! String) {
        throw const _PublicFailure(
          'context_unavailable',
          'stdin 必须仅包含宿主提供的私有上下文引用。',
          3,
        );
      }
      reference = value['association'] as String;
    }
    if (reference == null || reference.isEmpty) {
      throw const _PublicFailure(
        'context_required',
        '缺少本聊天的私有配置。宿主应提供 CHIYO_CONTEXT；普通终端可用 chiyo chat start 建立新聊天。',
        3,
      );
    }
    _contextFile = File(reference);
    return ChiyoContext.load(_contextFile!, environment: environment);
  }

  Future<ChiyoRunResult> _start(ChiyoInvocation i) async {
    if (i.root['context'] != null || i.root['context-stdin'] == true) {
      throw const ChiyoUsageFailure('新建聊天使用 --context-out，不覆盖现有上下文。');
    }
    final target = File(_required(i, 'context-out'));
    final agent = _required(i, 'agent'),
        chat = _required(i, 'id'),
        label = _required(i, 'label');
    if (!target.isAbsolute ||
        await FileSystemEntity.type(target.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const ChiyoUsageFailure('--context-out 必须指向新的私有文件绝对路径。');
    }
    final profilePath = i.options['connection'] as String?;
    final profileFile = profilePath != null
        ? File(profilePath)
        : await discoverAgentConnection(environment: environment);
    if (profileFile == null) {
      throw const _PublicFailure(
        'connection_unavailable',
        '请先在知予 App 选择本地模式或连接服务器。',
        3,
      );
    }
    final profile = await AgentConnectionProfile.read(profileFile);
    final client = AgentClient.remote(
      profile,
      sourceAgent: agent,
      externalChatId: chat,
    );
    var saved = false;
    try {
      final result = await client.openLifecycleSession(label);
      if (result['status'] != 'ok') return _protocol(result, i);
      final context = ChiyoContext(
        chatId: chat,
        agentName: agent,
        secret: client.sessionSecret!,
        endCapability: client.endCapability,
        port: profile.address.port,
        connection: profile,
      );
      await context.saveNew(target);
      saved = true;
      return _success({
        'status': 'created',
        ...context.publicStatus,
        'next': '由调用方在本聊天的环境中设置 CHIYO_CONTEXT，指向刚指定的私有文件。',
      }, i);
    } finally {
      if (!saved && client.endCapability != null) {
        await client
            .endLifecycleSession(client.endCapability!)
            .catchError((Object _) => <String, dynamic>{'status': 'unknown'});
      }
      client.close();
    }
  }

  Future<Map<String, dynamic>> _execute(
    ChiyoInvocation i,
    AgentClient client,
  ) async {
    final o = i.options;
    final id = o.rest.isEmpty ? null : o.rest.single;
    switch (i.path) {
      case 'chat end':
        return client.execute({
          'command': 'session-close',
        }, maintainDeviceState: false);
      case 'catalog list':
        return client.execute({
          'command': 'catalog',
          'protocolVersion': 2,
          if (o['query'] != null) 'query': o['query'],
          if (o['directory'] != null) 'directoryId': o['directory'],
          if (o['template'] != null) 'typeId': o['template'],
          if (o['tag'] != null) 'tagId': o['tag'],
          ..._page(i),
        });
      case 'directories list':
        return client.execute({'command': 'directory-list'});
      case 'credentials list':
        return client.execute({
          'command': 'credential-catalog',
          if (o['query'] != null) 'query': o['query'],
          if (o['directory'] != null) 'directoryId': o['directory'],
          if (o['cursor'] != null) 'cursor': o['cursor'],
          'limit': _integer(i, 'limit', 1, 100),
        });
      case 'templates list':
        return client.execute({
          'command': 'template-list',
          ..._page(i),
          if (o['plugin'] != null) 'packageId': o['plugin'],
        });
      case 'templates show':
        final result = await client.execute({
          'command': 'template-read',
          'templateId': id,
        });
        if (result['status'] != 'ok' ||
            result['template'] is! Map<String, dynamic>) {
          return result;
        }
        return {
          ...result,
          'template': _publicProposalTemplate(
            result['template'] as Map<String, dynamic>,
          ),
        };
      case 'templates examples':
        final result = await client.execute({
          'command': 'template-read',
          'templateId': id,
        });
        if (result['status'] != 'ok') return result;
        final template = _publicProposalTemplate(
          result['template'] as Map<String, dynamic>? ?? result,
        );
        return {
          'status': 'ok',
          'templateId': id,
          'workflow': template['workflow'],
          if (template['submissionExample'] != null)
            'submissionExample': template['submissionExample'],
          if (template['submissionExamples'] != null)
            'submissionExamples': template['submissionExamples'],
          if (template['definition'] case final Map definition) ...{
            'instructions': definition['instructions'],
            'example': definition['example'],
          },
        };
      case 'requests list':
        return client.execute({
          'command': 'requests-list',
          ..._page(i),
          if (o['kind'] != null) 'kind': o['kind'],
          if (o['status'] != null) 'state': o['status'],
        });
      case 'requests show':
      case 'proposals show':
        return client.execute({'command': 'requests-show', 'id': id});
      case 'operations list':
        final result = await client.execute({
          'command': 'operations-list',
          ..._page(i),
          if (o['request'] != null) 'requestId': o['request'],
        });
        if (result['status'] != 'ok') return result;
        final records = await _intents.list();
        return {
          ...result,
          'localIntents': [
            for (final record
                in records
                    .where(
                      (r) =>
                          r.kind != 'proposal-check' &&
                          (o['request'] == null ||
                              r.payload['requestId'] == o['request']),
                    )
                    .skip(_integer(i, 'offset', 0, 1000000))
                    .take(_integer(i, 'limit', 1, 100)))
              record.summary,
          ],
        };
      case 'operations show':
        final result = await client.execute({
          'command': 'operations-show',
          'id': id,
        });
        if (result['status'] != 'not_found') return result;
        final record = await _intents.read(id!);
        return record == null
            ? result
            : {'status': 'ok', ...record.summary, 'serverRecord': 'not_found'};
      case 'operations retry':
        final record = await _intents.read(id!);
        if (record == null) return {'status': 'not_found', 'operationId': id};
        if (record.kind == 'access-request') {
          return _submitAccess(client, record);
        }
        if (record.kind == 'fill-request' || record.kind == 'fill-run') {
          return _continueFill(record, recover: true);
        }
        if (record.kind == 'proposal-submit') {
          return _recoverProposal(client, record);
        }
        if (record.kind == 'reveal-request') {
          return _submitReveal(client, record);
        }
        if (record.kind == 'reveal-read') {
          return _revealReceipt(client, record);
        }
        if (record.kind == 'exec-request' || record.kind == 'exec-run') {
          return _continueProgram(client, record, recover: true);
        }
        // An execution record is never an instruction to type again. Remaining
        // adapters can recover their own immutable intent through this seam.
        return client.execute({'command': 'operations-show', 'id': id});
      case 'requests cancel':
        return client.execute({'command': 'cancel', 'requestId': id});
      case 'requests wait':
        final timeout = Duration(seconds: _integer(i, 'timeout', 0, 300));
        final elapsed = Stopwatch()..start();
        while (true) {
          final result = await client.execute({
            'command': 'requests-show',
            'id': id,
          });
          if (result['status'] != 'pending') return result;
          if (elapsed.elapsed >= timeout) {
            return {...result, 'waitTimedOut': true};
          }
          await Future<void>.delayed(
            Duration(
              milliseconds: (timeout - elapsed.elapsed).inMilliseconds.clamp(
                1,
                500,
              ),
            ),
          );
        }
      case 'proposals list':
        if (o['kind'] != null) {
          return client.execute({
            'command': 'requests-list',
            'kind': o['kind'],
            if (o['status'] != null) 'state': o['status'],
            ..._page(i),
          });
        }
        // A distinct server filter preserves pagination across proposal kinds.
        return client.execute({
          'command': 'proposals-list',
          if (o['status'] != null) 'state': o['status'],
          ..._page(i),
        });
      case 'access read':
        final request = _required(i, 'request');
        final claim = await client.execute({
          'command': 'claim',
          'requestId': request,
        });
        if (claim['status'] != 'ok') return claim;
        return client.execute({
          'command': 'read',
          'requestId': request,
          'itemId': _required(i, 'item'),
          'fieldId': _required(i, 'field'),
        });
      case 'access request':
        final body = o['input'] == null
            ? {
                'fields': [
                  {
                    'itemId': _required(i, 'item'),
                    'fieldId': _required(i, 'field'),
                  },
                ],
              }
            : await _businessInput(i, 65536);
        final fields = body['fields'];
        if (_required(i, 'purpose').length > 2000) {
          throw const ChiyoUsageFailure('用途说明不能超过2000个字符。');
        }
        if (body.length != 1 ||
            fields is! List ||
            fields.isEmpty ||
            fields.length > 200 ||
            fields.any(
              (value) =>
                  value is! Map<String, dynamic> ||
                  value.length != 2 ||
                  value['itemId'] is! String ||
                  (value['itemId'] as String).isEmpty ||
                  (value['itemId'] as String).length > 200 ||
                  value['fieldId'] is! String ||
                  (value['fieldId'] as String).isEmpty ||
                  (value['fieldId'] as String).length > 200,
            )) {
          throw const ChiyoUsageFailure(
            '业务文件应只包含 fields，每项填写 itemId 和 fieldId。',
          );
        }
        final intent = await _intents.remember('access-request', {
          'command': 'request',
          'protocolVersion': 2,
          'purpose': _required(i, 'purpose'),
          'fields': fields,
        }, operationId: o['operation'] as String?);
        return _submitAccess(client, intent);
      case 'fill request':
        return _requestFill(i);
      case 'fill run':
        return _runFill(i);
      case 'exec request':
        return _requestProgram(i, client);
      case 'exec run':
        return _runProgram(i, client);
      case 'exec output':
        return client.execute({
          'command': 'program-output',
          'operationId': _required(i, 'operation'),
          'cursor': _integer(i, 'cursor', 0, 2147483647),
          'limit': _integer(i, 'limit', 1, 16),
        });
      case 'proposals check':
      case 'proposals submit':
        return _proposal(i, client);
      case 'credentials reveal request':
        return _requestReveal(i, client);
      case 'credentials reveal read':
        return _readReveal(i, client);
      default:
        // New target and multi-credential semantics must be implemented by the
        // receiving service; never translate them to a broader old script plan.
        return {'status': 'unsupported_capability'};
    }
  }

  Future<Map<String, dynamic>> _businessInput(
    ChiyoInvocation i,
    int maxBytes,
  ) async {
    try {
      final path = _required(i, 'input');
      final text = await _read(
        path == '-' ? input : File(path).openRead(),
        maxBytes,
      );
      return decodeProtocolObject(text, maxBytes: maxBytes);
    } on ChiyoUsageFailure {
      rethrow;
    } on Object {
      throw const ChiyoUsageFailure('无法读取业务 JSON 文件，请检查文件和格式。');
    }
  }

  Future<Map<String, dynamic>> _submitAccess(
    AgentClient client,
    ChiyoIntent intent,
  ) async {
    final original = await client.execute({
      'command': 'operations-show',
      'id': intent.operationId,
    });
    if (original['status'] == 'ok') {
      if (original['requestId'] is! String ||
          original['requestKind'] != 'access') {
        return {
          'status': 'operation_conflict',
          'operationId': intent.operationId,
        };
      }
    }
    if (!{'not_found', 'ok'}.contains(original['status'])) {
      return {...original, 'operationId': intent.operationId};
    }
    // The server also checks the stored content. A matching local ID cannot
    // hide different content submitted on another device.
    final response = await client.execute({
      ...intent.payload,
      'operationId': intent.operationId,
    });
    return {
      ...response,
      'operationId': intent.operationId,
      if (original['status'] == 'ok' &&
          {
            'pending',
            'approved',
            'denied',
            'expired',
            'revoked',
            'cancelled',
          }.contains(response['status']))
        'recovered': true,
    };
  }

  Future<ChiyoRunResult> _doctor(
    ChiyoInvocation i,
    ChiyoContext context,
    AgentClient client,
  ) async {
    final live = await client.execute({
      'command': 'session-check',
    }, maintainDeviceState: false);
    if (live['status'] != 'ok') return _protocol(live, i);
    final capabilities = await client.execute({
      'command': 'capabilities',
    }, maintainDeviceState: false);
    if (capabilities['status'] != 'ok') return _protocol(capabilities, i);
    final checks = <String, Object?>{
      'status': 'ok',
      ...context.publicStatus,
      'sessionValid': true,
      'capabilities': capabilities['capabilities'],
      'credentialTools': capabilities['credentialTools'] ?? const [],
      'targetChecked': false,
    };
    final batchSupported = (capabilities['capabilities'] as List? ?? [])
        .contains('credential-batches.v3');
    final host = batchSupported && context.connection != null
        ? await _batchClient.execute(null, {'command': 'capabilities'})
        : <String, dynamic>{'status': 'unsupported_capability'};
    final appAvailable = host['status'] == 'ok';
    final providers = host['providers'] as List? ?? [];
    checks['fill'] = {
      'supported': batchSupported,
      'appAvailable': appAvailable,
      'targetChecked': false,
      for (final via in ['ego', 'chrome', 'focus'])
        via: {
          'supported': batchSupported,
          'available': appAvailable && providers.contains(via),
          'targetReady': null,
          'reason': !batchSupported
              ? 'update_required'
              : !appAvailable
              ? 'matching_app_unavailable'
              : !providers.contains(via)
              ? 'provider_not_installed'
              : 'target_not_checked',
        },
    };
    if (i.options['via'] == 'chrome') {
      final browser = i.options['browser'] as String?;
      if (browser == null) {
        checks['chrome'] = {
          'supported': batchSupported,
          'available': false,
          'reason': batchSupported
              ? 'browser_address_required'
              : 'update_required',
        };
      } else {
        try {
          final pages = await ChromeBrowserFill(browser).pages();
          checks['chrome'] = {
            'supported': batchSupported,
            'available': appAvailable && providers.contains('chrome'),
            'browserConnected': true,
            'pageCount': (pages['pages'] as List).length,
            'targetReady': null,
            'reason': appAvailable
                ? 'target_not_checked'
                : 'matching_app_unavailable',
          };
        } on Object {
          checks['chrome'] = {
            'supported': batchSupported,
            'available': false,
            'reason': 'browser_unavailable',
          };
        }
      }
    }
    return _success(checks, i);
  }

  Map<String, int> _page(ChiyoInvocation i) => {
    'offset': _integer(i, 'offset', 0, 1000000),
    'limit': _integer(i, 'limit', 1, 100),
  };
  int _integer(ChiyoInvocation i, String key, int min, int max) {
    final value = int.tryParse(i.options[key] as String? ?? '');
    if (value == null || value < min || value > max) {
      throw ChiyoUsageFailure('--$key 必须是 $min–$max 的整数。');
    }
    return value;
  }

  String _required(ChiyoInvocation i, String key) {
    final value = i.options[key] as String?;
    if (value == null || value.trim().isEmpty) {
      throw ChiyoUsageFailure('缺少 --$key；请查看此命令的 --help。');
    }
    return value;
  }

  Future<String> _read(Stream<List<int>> stream, int maxBytes) async {
    final bytes = <int>[];
    await for (final chunk in stream.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const ChiyoUsageFailure('输入内容超过此命令允许的大小。');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  ChiyoRunResult _success(Map<String, Object?> data, ChiyoInvocation i) =>
      ChiyoRunResult(
        {'schemaVersion': 1, 'ok': true, 'data': data},
        0,
        json: i.json,
      );
  ChiyoRunResult _failure(
    String code,
    String message,
    int exit,
    bool json, {
    Map<String, Object?>? data,
  }) => ChiyoRunResult(
    {
      'schemaVersion': 1,
      'ok': false,
      'error': {'code': code, 'message': message},
      'data': ?data,
    },
    exit,
    json: json,
  );

  ChiyoRunResult _protocol(
    Map<String, dynamic> data,
    ChiyoInvocation i, {
    bool executing = false,
  }) {
    final status = data['status'] as String? ?? 'invalid_response';
    final code = data['errorCode'] as String? ?? status;
    final int? failure = switch (code) {
      'operation_conflict' ||
      'credential_version_changed' ||
      'template_changed' => 8,
      'request_pending' ||
      'request_denied' ||
      'grant_expired' ||
      'grant_revoked' ||
      'credential_disabled' ||
      'credential_deleted' ||
      'scope_not_approved' => 4,
      _ => switch (status) {
        'service_unavailable' ||
        'connection_unavailable' ||
        'server_changed' ||
        'association_unavailable' ||
        'session_required' ||
        'unsupported_capability' => 3,
        'unauthorized' => code == 'scope_not_approved' ? 4 : 3,
        'invalid_request' ||
        'invalid_query' ||
        'invalid_type' ||
        'invalid_cursor' ||
        'invalid_submission_metadata' ||
        'source_required' ||
        'validation_failed' ||
        'invalid_response' => 2,
        'operation_conflict' ||
        'template_changed' ||
        'source_changed' ||
        'check_changed' ||
        'proposal_conflict' ||
        'credential_version_changed' => 8,
        'conflict' =>
          {
                'execution_unknown',
                'fill_unknown',
                'fill_needs_attention',
              }.contains(code)
              ? 7
              : 8,
        'request_unknown' || 'operation_unknown' => 7,
        'request_denied' || 'scope_not_approved' || 'grant_expired' => 4,
        _ =>
          status.startsWith('invalid_')
              ? 2
              : status.startsWith('unsupported_')
              ? 3
              : null,
      },
    };
    if (failure != null) {
      return _failure(
        code,
        switch (failure) {
          2 => '内容或参数未通过检查；请查看返回的字段说明。',
          3 => '当前聊天、连接或所需能力不可用；请检查连接和软件版本。',
          4 => '本次操作没有有效批准；请查看原申请状态。',
          8 => '内容或版本已变化；请核对原记录，不要直接重复提交。',
          7 => '结果尚未确认，请查询原操作，不要重新提交或执行。',
          _ => '本次操作未完成。',
        },
        failure,
        i.json,
        data: data,
      );
    }
    if (data['waitTimedOut'] == true) {
      return _failure(
        'wait_timeout',
        '本次等待已结束，原申请仍保留；稍后可继续查询。',
        6,
        i.json,
        data: data,
      );
    }
    if (executing) {
      if ({
        'denied',
        'expired',
        'revoked',
        'cancelled',
        'ended',
      }.contains(status)) {
        return _failure(code, '本次使用没有有效批准，请查看原申请。', 4, i.json, data: data);
      }
      final state = data['fillState'] ?? data['executionState'] ?? status;
      if (state == 'unknown' || state == 'request_unknown') {
        return _failure(
          'execution_unknown',
          '结果尚无法确认，请查询原操作；不要重新执行。',
          7,
          i.json,
          data: data,
        );
      }
      if ({
            'failed',
            'refused',
            'not_started',
            'partial',
            'start_failed',
            'prepare_failed',
          }.contains(state) ||
          state == 'exited' && data['exitCode'] != 0) {
        return _failure(code, '本次执行未完成，请查看原操作记录。', 5, i.json, data: data);
      }
    }
    if (!{
      'ok',
      'accepted',
      'pending',
      'approved',
      'partially_approved',
      'denied',
      'expired',
      'revoked',
      'cancelled',
      'ended',
      'not_found',
      'active',
      'proposed',
      'confirmed',
      'conflicted',
      'completed',
      'rejected',
      'approved_awaiting_admission',
      'approvedAwaitingAdmission',
    }.contains(status)) {
      return _failure(
        'invalid_response',
        '软件返回了无法识别的结果，请检查运行版本。',
        3,
        i.json,
        data: data,
      );
    }
    return _success(data, i);
  }
}
