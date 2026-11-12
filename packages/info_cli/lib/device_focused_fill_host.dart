import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'private_device_state.dart';

String _profileHash(AgentConnectionProfile profile) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          ...profile.toPrivateJson(),
          'certificate': profile.certificate.trim(),
        }),
      ),
    )
    .toString();
Map<String, dynamic> _failure(String code, {bool uncertain = false}) =>
    Map<String, dynamic>.from(
      CredentialUseFailure(
        code,
        attemptConsumed: uncertain,
      ).toJson(protocolVersion: 2),
    );
const _commands = {'capabilities', 'focus-target', 'request-use', 'fill-use'};
const _base = '/credential-use/device/fill';

/// Agent-side control client. It cannot create an App host or contact private
/// native XPC. The existing running App resolves its own saved device profile;
/// this IPC carries only its hash, the exact original chat proof and command.
final class DeviceFocusedFillClient {
  DeviceFocusedFillClient(this.profile, {this.directory});
  final AgentConnectionProfile profile;
  final Directory? directory;

  Future<Map<String, dynamic>> execute(
    String? session,
    Map<String, dynamic> input,
  ) async {
    if (!_commands.contains(input['command']) || profile.isLocal) {
      return _failure('unsupported_capability');
    }
    var submitted = false;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final roots = directory == null
          ? automaticConnectionDirectories()
          : [directory!.absolute.path];
      for (final root in roots) {
        final record = await readPrivateDeviceState(
          File('$root/focused-fill-host/endpoint.json'),
        );
        if (record == null) continue;
        _validateRecord(record);
        if (record['phase'] != 'ready' ||
            CredentialProcessIdentity.isActive(
                  record['processId'] as int,
                  record['processIdentity'] as String,
                ) !=
                true) {
          continue;
        }
        return await (() async {
          final request = await http.postUrl(
            Uri.parse('http://127.0.0.1:${record['port']}/execute'),
          );
          request.followRedirects = false;
          request.headers.contentType = ContentType.json;
          request.headers.set(
            'authorization',
            'Bearer ${record['controlCapability']}',
          );
          request.write(
            jsonEncode({
              'profileHash': _profileHash(profile),
              'serverId': profile.serverId,
              'sessionSecret': session,
              'input': input,
            }),
          );
          submitted = true;
          final response = await request.close();
          final result = decodeProtocolObject(
            utf8.decode(await _bounded(response)),
            maxBytes: 262144,
          );
          if (response.statusCode != 200 || result['status'] is! String) {
            throw const FormatException();
          }
          return result;
        })().timeout(
          Duration(seconds: input['command'] == 'fill-use' ? 12 : 8),
        );
      }
      return _failure('service_unavailable');
    } on Object {
      final uncertain = submitted && input['command'] == 'fill-use';
      return _failure(
        uncertain ? 'fill_unknown' : 'service_unavailable',
        uncertain: uncertain,
      );
    } finally {
      http.close(force: true);
    }
  }
}

void _validateRecord(Map<String, dynamic> record) {
  if (record.length != 7 ||
      record['version'] != 1 ||
      record['processId'] is! int ||
      (record['processId'] as int) < 1 ||
      record['processIdentity'] is! String ||
      !const {'ready', 'closed'}.contains(record['phase']) ||
      record['port'] is! int ||
      (record['port'] as int) < 1 ||
      (record['port'] as int) > 65535 ||
      record['executable'] is! String ||
      !RegExp(
        r'^[A-Za-z0-9_-]{43}$',
      ).hasMatch(record['controlCapability'] as String? ?? '')) {
    throw const FormatException('Invalid App host');
  }
}

Future<List<int>> _bounded(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > 262144) throw const FormatException();
    bytes.addAll(chunk);
  }
  return bytes;
}

void _requireOk(Map<String, dynamic> value) {
  if (value['status'] == 'ok') return;
  final code = value['errorCode'] ?? value['status'];
  throw CredentialUseFailure(
    focusedFillErrorCodes.contains(code)
        ? code as String
        : 'service_unavailable',
  );
}

/// Started only by the signed desktop App, with its build-bound native driver.
/// It accepts no raw secret, application launcher, owner Token or native IPC
/// endpoint. NAS material is acquired privately after a durable operation and
/// actual target preparation; only typed, non-secret results leave this host.
final class DeviceFocusedFillHost {
  DeviceFocusedFillHost._(
    this.directory,
    this.driver,
    this._lock,
    this._server,
    this._record,
  );
  final Directory directory;
  final FocusedFillDriver driver;
  final RandomAccessFile _lock;
  final HttpServer _server;
  final Map<String, dynamic> _record;
  final _tasks = <Future<void>>{};
  final _connections = <AgentConnection>{};
  bool _closed = false, _filling = false;
  PreparedFocusedFill? _prepared;

  static Future<DeviceFocusedFillHost> start({
    required Directory directory,
    required FocusedFillDriver driver,
  }) async {
    final folder = await privateDeviceDirectory(
      Directory('${directory.path}/focused-fill-host'),
    );
    final guard = File('${folder.path}/owner.lock');
    await privateDeviceFile(guard);
    final lock = await guard.open(mode: FileMode.append);
    HttpServer? server;
    final identity = CredentialProcessIdentity.capture(pid);
    try {
      if (identity == null) throw const FormatException();
      await lock.lock(FileLock.exclusive);
      final file = File('${folder.path}/endpoint.json');
      final previous = await readPrivateDeviceState(file);
      if (previous != null) {
        _validateRecord(previous);
        if (previous['phase'] == 'ready' &&
            CredentialProcessIdentity.isActive(
                  previous['processId'] as int,
                  previous['processIdentity'] as String,
                ) !=
                false) {
          throw const FormatException('App host already running');
        }
      }
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final record = <String, dynamic>{
        'version': 1,
        'processId': pid,
        'processIdentity': identity.value,
        'executable': Platform.resolvedExecutable,
        'controlCapability': base64Url
            .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
            .replaceAll('=', ''),
        'phase': 'ready',
        'port': server.port,
      };
      final host = DeviceFocusedFillHost._(
        directory,
        driver,
        lock,
        server,
        record,
      );
      await writePrivateDeviceState(file, record);
      server.listen(host._accept);
      return host;
    } on Object {
      await server?.close(force: true);
      await lock.close();
      rethrow;
    } finally {
      identity?.close();
    }
  }

  void _accept(HttpRequest request) {
    late final Future<void> task;
    task = _respond(request).whenComplete(() => _tasks.remove(task));
    _tasks.add(task);
    unawaited(task);
  }

  Future<void> _respond(HttpRequest request) async {
    Map<String, dynamic> result;
    try {
      if (_closed ||
          _tasks.length > 32 ||
          request.method != 'POST' ||
          request.uri.path != '/execute' ||
          request.uri.hasQuery ||
          request.headers.value('origin') != null ||
          request.headers.value('host') != '127.0.0.1:${_server.port}' ||
          request.headers.value('authorization') !=
              'Bearer ${_record['controlCapability']}') {
        throw const CredentialUseFailure('service_unavailable');
      }
      final body = decodeProtocolObject(
        utf8.decode(
          await _bounded(request).timeout(const Duration(seconds: 3)),
        ),
      );
      if (body.length != 4 ||
          body['input'] is! Map<String, dynamic> ||
          body['profileHash'] is! String ||
          body['serverId'] is! String ||
          body['sessionSecret'] != null && body['sessionSecret'] is! String) {
        throw const FormatException();
      }
      final profile = await _profile(
        body['serverId'] as String,
        body['profileHash'] as String,
      );
      result = await _execute(
        profile,
        body['sessionSecret'] as String?,
        body['input'] as Map<String, dynamic>,
      );
    } on CredentialUseFailure catch (error) {
      result = Map<String, dynamic>.from(error.toJson(protocolVersion: 2));
    } on Object {
      result = _failure('service_unavailable');
    }
    try {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    } on Object {
      /* The App owns any accepted fill independently of the adapter socket. */
    }
  }

  Future<AgentConnectionProfile> _profile(String serverId, String hash) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(serverId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException();
    }
    final current = await AutomaticConnectionStore(directory.path).agentFile();
    if (current != null) {
      final profile = await AgentConnectionProfile.read(current);
      if (!profile.isLocal &&
          profile.serverId == serverId &&
          _profileHash(profile) == hash) {
        return profile;
      }
    }
    throw const CredentialUseFailure('session_unavailable');
  }

  Future<Map<String, dynamic>> _execute(
    AgentConnectionProfile profile,
    String? session,
    Map<String, dynamic> input,
  ) async {
    final command = input['command'];
    if (!_commands.contains(command)) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    final connection = AgentConnection(profile);
    _connections.add(connection);
    try {
      final support = await connection.call('/capabilities', {});
      _requireOk(support);
      if (!(support['capabilities'] as List? ?? []).contains(
        'credential-device-focused-fill.v1',
      )) {
        throw const CredentialUseFailure('unsupported_capability');
      }
      if (command == 'capabilities') {
        if (input.length != 1) {
          throw const CredentialUseFailure('unknown_field');
        }
        final target = driver is FocusedFillDiscoveryDriver
            ? await (driver as FocusedFillDiscoveryDriver).inspectTarget()
            : null;
        final available =
            target != null &&
            !const {
              'session_unavailable',
              'unsupported_desktop',
              'access_denied',
              'service_unavailable',
            }.contains(target.errorCode);
        return {
          'protocolVersion': 2,
          'status': 'ok',
          'capabilities': [
            if (available) ...[
              'credential-focused-fill.v1',
              'credential-focused-target.v1',
            ],
          ],
        };
      }
      if (session == null) throw const CredentialUseFailure('session_required');
      _requireOk(
        await connection.call('/session/check', {'sessionSecret': session}),
      );
      if (command == 'focus-target') {
        FocusedFillTargetQuery.fromJson(input);
        if (driver is! FocusedFillDiscoveryDriver) {
          throw const CredentialUseFailure('unsupported_capability');
        }
        return Map<String, dynamic>.from(
          (await (driver as FocusedFillDiscoveryDriver).inspectTarget())
              .toJson(),
        );
      }
      if (command == 'request-use') {
        final parsed = FocusedFillInput.fromJson(input);
        final prepared = await driver.prepare(parsed.fill.application);
        try {
          if (!prepared.application.matches(parsed.fill.application)) {
            throw const CredentialUseFailure('application_changed');
          }
          return await connection.call('$_base/request', {
            'sessionSecret': session,
            ...input,
            'fill': FocusedFillPlan(
              prepared.application,
              parsed.fill.targetHint,
            ).toJson(),
          });
        } finally {
          await prepared.close();
        }
      }
      FocusedFillOperationInput.fromJson(input);
      final status = await connection.call('$_base/status', {
        'sessionSecret': session,
        ...input,
        'command': 'fill-status',
      });
      if (status['status'] != 'not_found') return status;
      if (_filling) throw const CredentialUseFailure('busy');
      _filling = true;
      try {
        return await _beginFill(profile, connection, session, input);
      } on Object {
        _filling = false;
        rethrow;
      }
    } finally {
      _connections.remove(connection);
      connection.close();
    }
  }

  Future<Map<String, dynamic>> _beginFill(
    AgentConnectionProfile profile,
    AgentConnection connection,
    String session,
    Map<String, dynamic> input,
  ) async {
    final claim = await connection.call('$_base/begin', {
      'sessionSecret': session,
      ...input,
    });
    final capability = claim.remove('fillCapability');
    if (capability is! String) {
      _filling = false;
      if (claim['status'] == 'service_unavailable') {
        return {
          ..._failure('fill_unknown', uncertain: true),
          'requestId': input['requestId'],
          'operationId': input['operationId'],
        };
      }
      return claim;
    }
    final operationConnection = AgentConnection(profile);
    _connections.add(operationConnection);
    late final Future<void> task;
    task = _performFill(profile, operationConnection, claim, capability)
        .catchError((Object _) {
          // NAS timeout/reopen retains an uncertain operation; never replay.
        })
        .whenComplete(() {
          _connections.remove(operationConnection);
          operationConnection.close();
          _filling = false;
          _tasks.remove(task);
        });
    _tasks.add(task);
    unawaited(task);
    return claim;
  }

  Future<void> _performFill(
    AgentConnectionProfile profile,
    AgentConnection connection,
    Map<String, dynamic> claim,
    String capability,
  ) async {
    final proof = {'fillId': claim['fillId'], 'fillCapability': capability};
    PreparedFocusedFill? prepared;
    List<int>? bytes;
    var result = const FocusedFillBatchResult(
      FocusedFillState.refused,
      'service_unavailable',
    );
    try {
      final application = FocusedFillApplication.fromJson(
        Map<String, dynamic>.from(claim['application'] as Map),
      );
      prepared = await driver.prepare(application);
      _prepared = prepared;
      if (_closed) throw const CredentialUseFailure('session_unavailable');
      if (!prepared.application.matches(application)) {
        throw const CredentialUseFailure('application_changed');
      }
      final material = await connection.call('$_base/material', {
        ...proof,
        'application': prepared.application.toJson(),
      });
      _requireOk(material);
      bytes = base64Decode(material.remove('materialBase64') as String);
      result = await sendPreparedFocusedFill(
        prepared,
        bytes,
        beforeBatch: () async {
          if (_closed) throw const CredentialUseFailure('session_unavailable');
          await _profile(profile.serverId, _profileHash(profile));
          _requireOk(await connection.call('$_base/batch', proof));
        },
      );
    } on Object catch (error) {
      result = FocusedFillBatchResult(
        FocusedFillState.refused,
        error is CredentialUseFailure &&
                focusedFillErrorCodes.contains(error.code)
            ? error.code
            : 'service_unavailable',
      );
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      try {
        await prepared?.close();
      } on Object {
        /* dispose only */
      }
      _prepared = null;
    }
    final reported = await connection.call('$_base/finish', {
      ...proof,
      'fillState': result.state.name,
      'errorCode': result.errorCode,
    });
    // A missing report remains the NAS's durable checking intent and expires
    // to unknown. No App or adapter automatically replays it.
    if (reported['fillState'] is! String) return;
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    for (final connection in _connections) {
      connection.close();
    }
    try {
      await _prepared?.close();
    } on Object {
      /* native expiry closes too */
    }
    await _server.close(force: true);
    await Future.wait(_tasks.toList());
    try {
      await writePrivateDeviceState(
        File('${directory.path}/focused-fill-host/endpoint.json'),
        {..._record, 'phase': 'closed'},
      );
    } finally {
      await _lock.close();
    }
  }
}
