import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';

import 'chrome_browser_fill.dart';
import 'ego_browser_fill.dart';
import 'private_device_state.dart';

const _folder = 'credential-batch-host';
const _base = '/credential-use/batch';
const _commands = {
  'capabilities',
  'batch-request',
  'batch-run',
  'batch-status',
  'native-targets',
};
const _publicCodes = {
  ...credentialBatchErrorCodes,
  'unsupported_capability',
  'unsupported_receiver',
  'session_mismatch',
  'operation_conflict',
  'invalid_operation_id',
  'invalid_type',
  'invalid_plan',
  'unknown_field',
  'limit_exceeded',
  'invalid_reference',
  'invalid_submission_metadata',
  'request_pending',
  'request_denied',
  'request_limit',
  'scope_not_approved',
  'busy',
  'application_changed',
  'unsupported_desktop',
};
String _hash(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
Object? _canonical(Object? value) => value is Map
    ? {
        for (final key in value.keys.cast<String>().toList()..sort())
          key: _canonical(value[key]),
      }
    : value is List
    ? value.map(_canonical).toList()
    : value;
String _profileHash(AgentConnectionProfile p) =>
    _hash({...p.toPrivateJson(), 'certificate': p.certificate.trim()});
Map<String, dynamic> _failure(String code) => Map<String, dynamic>.from(
  CredentialUseFailure(
    _publicCodes.contains(code) ? code : 'service_unavailable',
  ).toJson(protocolVersion: 3),
);
Map<String, dynamic> _unknown(String operation, [String? request]) => {
  ..._failure('execution_unknown'),
  'operationId': operation,
  'requestId': ?request,
  'executionState': 'unknown',
};
Map<String, dynamic> _map(Object? v) {
  if (v is! Map<String, dynamic>) {
    throw const CredentialUseFailure('invalid_type');
  }
  return v;
}

void _shape(
  Map<String, dynamic> value,
  Set<String> required, [
  Set<String> optional = const {},
]) {
  if (!value.keys.toSet().containsAll(required) ||
      value.keys.any((k) => !required.contains(k) && !optional.contains(k))) {
    throw const CredentialUseFailure('unknown_field');
  }
}

String _text(Object? value, {int max = 2000}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.contains('\x00')) {
    throw const CredentialUseFailure('invalid_type');
  }
  return value;
}

String _operation(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value)) {
    throw const CredentialUseFailure('invalid_operation_id');
  }
  return value;
}

void _requireOk(Map<String, dynamic> value) {
  if (value['status'] != 'ok') {
    throw CredentialUseFailure(
      _publicCodes.contains(value['errorCode'] ?? value['status'])
          ? (value['errorCode'] ?? value['status']) as String
          : 'service_unavailable',
    );
  }
}

Future<void> _writeJournal(File file, Map<String, dynamic> value) async {
  // The private state reader has this bound too. Never publish a journal that
  // cannot be reopened, including when prepared target metadata grows.
  if (utf8.encode(jsonEncode(value)).length > 131072) {
    throw const CredentialUseFailure('limit_exceeded');
  }
  try {
    await writePrivateDeviceState(file, value);
  } on Object {
    throw const CredentialUseFailure('audit_unavailable');
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

void _validateRecord(Map<String, dynamic> record) {
  if (record.length != 7 ||
      record['version'] != 1 ||
      record['processId'] is! int ||
      (record['processId'] as int) < 1 ||
      record['processIdentity'] is! String ||
      !{'ready', 'closed'}.contains(record['phase']) ||
      record['port'] is! int ||
      (record['port'] as int) < 1 ||
      (record['port'] as int) > 65535 ||
      record['executable'] is! String ||
      !RegExp(
        r'^[A-Za-z0-9_-]{43}$',
      ).hasMatch(record['controlCapability'] as String? ?? '')) {
    throw const FormatException();
  }
}

/// The installed App owns this IPC endpoint. The Agent supplies references and
/// public locators only; neither this client nor its receipts carry material.
final class DeviceCredentialBatchClient {
  DeviceCredentialBatchClient(this.profile, {this.directory});
  final AgentConnectionProfile profile;
  final Directory? directory;
  Future<Map<String, dynamic>> execute(
    String? session,
    Map<String, dynamic> input,
  ) async {
    if (!_commands.contains(input['command'])) {
      return _failure('unsupported_capability');
    }
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    var sent = false;
    try {
      final roots = directory == null
          ? automaticConnectionDirectories()
          : [directory!.absolute.path];
      for (final root in roots) {
        final record = await readPrivateDeviceState(
          File('$root/$_folder/endpoint.json'),
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
          sent = true;
          final response = await request.close();
          if (response.statusCode != 200) throw const FormatException();
          return _public(
            decodeProtocolObject(utf8.decode(await _bounded(response))),
          );
        })().timeout(const Duration(seconds: 12));
      }
      return _failure('service_unavailable');
    } on Object {
      return sent &&
              input['command'] == 'batch-run' &&
              input['operationId'] is String
          ? _unknown(
              input['operationId'] as String,
              input['requestId'] as String?,
            )
          : _failure('service_unavailable');
    } finally {
      http.close(force: true);
    }
  }
}

/// A real seam for installed Chrome/Ego drivers and controlled browser tests.
/// The host validates locators and grants; adapters never receive a proof.
abstract interface class DeviceCredentialBatchBrowser {
  Future<BrowserFormInspection> inspect(Map<String, dynamic> locator);

  /// Run the guard after the last target inspection, immediately before the
  /// final dispatch. A refused result must establish that no write occurred.
  Future<Map<String, Object?>> fill(
    BrowserFormTarget target,
    List<int> material, {
    required Future<void> Function() beforeDispatch,
  });
}

final class _InstalledBrowsers implements DeviceCredentialBatchBrowser {
  _InstalledBrowsers(this.egoExecutable);
  final String? egoExecutable;
  @override
  Future<BrowserFormInspection> inspect(Map<String, dynamic> locator) {
    if (locator['via'] == 'chrome') {
      return ChromeBrowserFill(locator['browser'] as String).inspect(
        tab: locator['tab'] as String,
        url: locator['url'] as String,
        form: locator['form'] as String,
        field: locator['selector'] as String,
      );
    }
    if (egoExecutable == null) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    return EgoBrowserFill(egoExecutable!).inspect(
      space: locator['space'] as int,
      page: locator['page'] as String,
      url: locator['url'] as String,
      form: locator['form'] as String,
      field: locator['selector'] as String,
    );
  }

  @override
  Future<Map<String, Object?>> fill(
    BrowserFormTarget target,
    List<int> material, {
    required Future<void> Function() beforeDispatch,
  }) => target.provider == 'chrome'
      ? ChromeBrowserFill(
          target.browserAddress!,
        ).fill(target, utf8.decode(material), beforeDispatch: beforeDispatch)
      : EgoBrowserFill(
          egoExecutable!,
        ).fill(target, utf8.decode(material), beforeDispatch: beforeDispatch);
}

/// Private App execution, independent of the lifetime of a calling CLI socket.
/// Journals freeze prepared requests and at-most-once execution intent before
/// mutation. Proofs and material are never serialized into those journals.
final class DeviceCredentialBatchHost {
  DeviceCredentialBatchHost._(
    this.directory,
    this.driver,
    this.nativeDriver,
    this.browser,
    this._providers,
    this._lock,
    this._server,
    this._record,
  );
  final Directory directory;
  final FocusedFillDriver? driver;
  final NativeFillDriver? nativeDriver;
  final DeviceCredentialBatchBrowser browser;
  final List<String> _providers;
  final RandomAccessFile _lock;
  final HttpServer _server;
  final Map<String, dynamic> _record;
  final _tasks = <Future<void>>{};
  final _connections = <AgentConnection>{};
  final _prepared = <PreparedFocusedFill>{};
  final _nativePrepared = <PreparedNativeFill>{};
  final _retainedNativeTargets = <String, Set<String>>{};
  final _serials = <String, Future<void>>{};
  bool _closed = false;

  static Future<DeviceCredentialBatchHost> start({
    required Directory directory,
    FocusedFillDriver? driver,
    NativeFillDriver? nativeDriver,
    String? egoExecutable,
    DeviceCredentialBatchBrowser? browser,
  }) async {
    final folder = await privateDeviceDirectory(
      Directory('${directory.path}/$_folder'),
    );
    await privateDeviceDirectory(Directory('${folder.path}/journal'));
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
      final host = DeviceCredentialBatchHost._(
        directory,
        driver,
        nativeDriver,
        browser ?? _InstalledBrowsers(egoExecutable),
        [
          'chrome',
          if (egoExecutable != null) 'ego',
          if (driver != null) 'focus',
          if (nativeDriver != null) 'native',
        ],
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

  void _track(Future<void> task) {
    _tasks.add(task);
    unawaited(task.whenComplete(() => _tasks.remove(task)));
  }

  void _accept(HttpRequest request) => _track(_respond(request));
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
      _shape(body, {'profileHash', 'serverId', 'sessionSecret', 'input'});
      if (body['sessionSecret'] != null && body['sessionSecret'] is! String) {
        throw const FormatException();
      }
      final profile = await _profile(
        _text(body['serverId']),
        _text(body['profileHash']),
      );
      result = await _execute(
        profile,
        body['sessionSecret'] as String?,
        _map(body['input']),
      );
    } on CredentialUseFailure catch (e) {
      result = _failure(e.code);
    } on Object {
      result = _failure('service_unavailable');
    }
    try {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(_public(result)));
      await request.response.close();
    } on Object {
      /* The App task continues if the calling adapter disconnects. */
    }
  }

  Future<AgentConnectionProfile> _profile(String serverId, String hash) async {
    final current = await AutomaticConnectionStore(directory.path).agentFile();
    if (current != null) {
      final p = await AgentConnectionProfile.read(current);
      if (p.serverId == serverId && _profileHash(p) == hash) return p;
    }
    throw const CredentialUseFailure('session_mismatch');
  }

  AgentConnection _connection(AgentConnectionProfile p) {
    final connection = AgentConnection(p);
    _connections.add(connection);
    return connection;
  }

  void _dispose(AgentConnection connection) {
    _connections.remove(connection);
    connection.close();
  }

  Future<T> _serialized<T>(String key, Future<T> Function() action) async {
    final previous = _serials[key] ?? Future<void>.value();
    final done = Completer<void>();
    _serials[key] = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
      if (identical(_serials[key], done.future)) _serials.remove(key);
    }
  }

  Future<Map<String, dynamic>> _execute(
    AgentConnectionProfile p,
    String? session,
    Map<String, dynamic> input,
  ) async {
    final command = input['command'];
    if (!_commands.contains(command)) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    _validateInput(input);
    final connection = _connection(p);
    try {
      final support = await connection.call('/capabilities', {});
      _requireOk(support);
      if (!(support['capabilities'] as List? ?? []).contains(
        'credential-batches.v3',
      )) {
        throw const CredentialUseFailure('unsupported_capability');
      }
      if (command == 'capabilities') {
        return {
          'status': 'ok',
          'protocolVersion': 3,
          'capabilities': [
            'credential-batches.v3',
            if (nativeDriver != null &&
                (support['capabilities'] as List).contains(
                  'credential-native-fill.v1',
                ))
              'credential-native-fill.v1',
          ],
          'providers': [
            for (final provider in _providers)
              if (provider != 'native' ||
                  (support['capabilities'] as List).contains(
                    'credential-native-fill.v1',
                  ))
                provider,
          ],
        };
      }
      if (session == null) throw const CredentialUseFailure('session_required');
      _requireOk(
        await connection.call('/session/check', {'sessionSecret': session}),
      );
      if (command == 'native-targets') {
        _requireNativeSupport(support);
        final targets = await nativeDriver!.discover(
          scope: _nativeScope(p, session),
          appId: input['appId'] as String,
          windowId: input['windowId'] as String?,
        );
        if (targets.length > 64 ||
            targets.map((t) => t.targetId).toSet().length != targets.length ||
            utf8
                    .encode(jsonEncode(targets.map((t) => t.toJson()).toList()))
                    .length >
                131072) {
          throw const CredentialUseFailure('limit_exceeded');
        }
        return {
          'status': 'ok',
          'targets': targets.map((t) => t.toJson()).toList(),
        };
      }
      if (command == 'batch-request' &&
          ((_map(input['input'])['items'] as List).any(
            (item) => _map(_map(item)['destination'])['via'] == 'native',
          ))) {
        _requireNativeSupport(support);
      }
      if (command == 'batch-status') {
        return _public(
          await connection.call('$_base/operation', {
            'sessionSecret': session,
            'operationId': input['operationId'],
          }),
        );
      }
      final scope = _hash({
        'profile': _profileHash(p),
        'session': _hash(session),
        'operation': input['operationId'],
      });
      return await _serialized(scope, () async {
        if (_closed) throw const CredentialUseFailure('session_unavailable');
        final file = File('${directory.path}/$_folder/journal/$scope.json');
        final intent = _hash(input);
        var journal = await readPrivateDeviceState(file);
        if (journal != null &&
            (journal['version'] != 1 ||
                journal['scope'] != scope ||
                journal['intent'] != intent ||
                journal['command'] != command)) {
          throw const CredentialUseFailure('operation_conflict');
        }
        if (command == 'batch-request') {
          return _request(
            connection,
            session,
            input,
            file,
            journal,
            scope,
            intent,
          );
        }
        journal ??= {
          'version': 1,
          'scope': scope,
          'intent': intent,
          'command': command,
          'phase': 'intent',
        };
        if (journal['phase'] != 'intent') {
          final status = await connection.call('$_base/operation', {
            'sessionSecret': session,
            'operationId': input['operationId'],
          });
          return status['status'] == 'ok'
              ? _public(status)
              : _unknown(
                  input['operationId'] as String,
                  input['requestId'] as String,
                );
        }
        await _writeJournal(file, journal);
        return _begin(p, connection, session, input, file, journal);
      });
    } finally {
      _dispose(connection);
    }
  }

  Future<Map<String, dynamic>> _request(
    AgentConnection connection,
    String session,
    Map<String, dynamic> input,
    File file,
    Map<String, dynamic>? journal,
    String scope,
    String intent,
  ) async {
    if (journal == null) {
      final raw = _map(input['input']);
      final items = <Map<String, dynamic>>[];
      for (final value in raw['items'] as List) {
        final item = _map(value);
        final prepared = await _inspectLocator(
          _map(item['destination']),
          nativeScope: _nativeScope(connection.profile, session),
        );
        items.add({...item, 'destination': prepared.toJson()});
      }
      final prepared = CredentialBatchInput.fromJson({
        ...raw,
        'protocolVersion': 3,
        'items': items,
      });
      journal = {
        'version': 1,
        'scope': scope,
        'intent': intent,
        'command': 'batch-request',
        'phase': 'prepared',
        'prepared': prepared.toJson(),
      };
      await _writeJournal(file, journal);
    } else {
      final found = await connection.call('/operations/show', {
        'sessionSecret': session,
        'id': input['operationId'],
      });
      if (found['status'] == 'ok') {
        if (found['kind'] != 'request-submit' ||
            found['requestKind'] != 'credential-use' ||
            found['requestId'] is! String) {
          throw const CredentialUseFailure('operation_conflict');
        }
      } else if (found['status'] != 'not_found') {
        return _public(found);
      }
    }
    // A lost submit reply only ever resends this exact frozen prepared input.
    // A known server ID must also match that immutable digest: another caller
    // may have submitted a different intent before the local journal existed.
    final frozen = CredentialBatchInput.fromJson(_map(journal['prepared']));
    await _profile(
      connection.profile.serverId,
      _profileHash(connection.profile),
    );
    final result = await connection.call('$_base/request', {
      'sessionSecret': session,
      'operationId': input['operationId'],
      'input': frozen.toJson(),
    });
    return {..._public(result), 'operationId': input['operationId']};
  }

  Future<CredentialBatchDestination> _inspectLocator(
    Map<String, dynamic> locator, {
    String? nativeScope,
  }) async {
    if (locator['via'] == 'native') {
      if (nativeDriver == null || nativeScope == null) {
        throw const CredentialUseFailure('unsupported_capability');
      }
      final prepared = await nativeDriver!.prepare(
        scope: nativeScope,
        targetId: locator['targetId'] as String,
      );
      try {
        if (prepared.target.targetId != locator['targetId']) {
          throw const CredentialUseFailure('destination_changed');
        }
        _retainedNativeTargets
            .putIfAbsent(nativeScope, () => {})
            .add(prepared.target.targetId);
        return CredentialBatchDestination.fromJson({
          'via': 'native',
          'target': prepared.target.toJson(),
        });
      } finally {
        await prepared.close();
      }
    }
    if (locator['via'] != 'focus') {
      final BrowserFormInspection checked;
      try {
        checked = await browser.inspect(locator);
      } on BrowserFillFailure catch (error) {
        // Inspection cannot submit an approval or dispatch input. Preserve its
        // public refusal instead of making the CLI report an unknown submit.
        throw CredentialUseFailure(browserDispatchError(error));
      }
      final target = checked.target;
      if (target.provider != locator['via'] ||
          target.url != locator['url'] ||
          target.formSelector != locator['form'] ||
          target.fieldSelector != locator['selector'] ||
          (target.provider == 'ego'
              ? target.space != locator['space'] ||
                    target.pageId != locator['page']
              : target.pageId != locator['tab'] ||
                    target.browserAddress !=
                        BrowserFormTarget.chromeAddress(
                          locator['browser'] as String,
                        ).toString())) {
        throw const CredentialUseFailure('destination_changed');
      }
      return CredentialBatchDestination.fromJson({
        'via': locator['via'],
        'target': checked.target.toJson(),
      });
    }
    final native = driver;
    if (native is! FocusedFillDiscoveryDriver) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    final target = await native.inspectTarget();
    if (target.application == null) {
      throw CredentialUseFailure(target.errorCode ?? 'unsupported_target');
    }
    final prepared = await native.prepare(target.application!);
    try {
      if (!prepared.application.matches(target.application!)) {
        throw const CredentialUseFailure('application_changed');
      }
      return CredentialBatchDestination.fromJson({
        'via': 'focus',
        'application': prepared.application.toJson(),
      });
    } finally {
      await prepared.close();
    }
  }

  Future<Map<String, dynamic>> _begin(
    AgentConnectionProfile p,
    AgentConnection connection,
    String session,
    Map<String, dynamic> input,
    File file,
    Map<String, dynamic> journal,
  ) async {
    final existing = await connection.call('$_base/operation', {
      'sessionSecret': session,
      'operationId': input['operationId'],
    });
    if (existing['status'] != 'not_found') {
      if (existing['status'] != 'ok') return _public(existing);
      if (existing['requestId'] != input['requestId']) {
        throw const CredentialUseFailure('operation_conflict');
      }
      var requested = input['itemIds'] as List<String>?;
      if (requested == null) {
        final request = await connection.call('$_base/status', {
          'sessionSecret': session,
          'requestId': input['requestId'],
        });
        if (request['items'] is! List) return _public(request);
        requested = (request['items'] as List)
            .map((i) => _text(_map(i)['id']))
            .toList();
      }
      if (existing['itemIds'] is! List ||
          _hash((requested.toList()..sort())) !=
              _hash(
                (existing['itemIds'] as List).cast<String>().toList()..sort(),
              )) {
        throw const CredentialUseFailure('operation_conflict');
      }
      await _writeJournal(file, {...journal, 'phase': 'recovered'});
      return _public(existing);
    }
    final status = await connection.call('$_base/status', {
      'sessionSecret': session,
      'requestId': input['requestId'],
    });
    if (status['items'] is! List) return _public(status);
    final all = (status['items'] as List).map(_map).toList();
    final ids =
        input['itemIds'] as List<String>? ??
        all.map((i) => _text(i['id'])).toList();
    if (ids.isEmpty ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !all.any((i) => i['id'] == id))) {
      throw const CredentialUseFailure('invalid_reference');
    }
    final selected = all.where((i) => ids.contains(i['id'])).toList();
    final destinations = <String, CredentialBatchDestination>{};
    final prepared = <String, PreparedFocusedFill>{};
    final nativePrepared = <String, PreparedNativeFill>{};
    var detached = false;
    try {
      for (final item in selected) {
        if (item['grantState'] != 'available') {
          throw CredentialUseFailure(
            item['grantState'] == 'pending'
                ? 'request_pending'
                : 'scope_not_approved',
          );
        }
        final approved = CredentialBatchDestination.fromJson(
          _map(item['destination']),
        );
        final id = _text(item['id']);
        CredentialBatchDestination observed;
        if (approved.native case final target?) {
          final support = await connection.call('/capabilities', {});
          _requireOk(support);
          _requireNativeSupport(support);
          final native = await nativeDriver!.prepare(
            scope: _nativeScope(p, session),
            targetId: target.targetId,
            expected: target,
          );
          nativePrepared[id] = native;
          _retainedNativeTargets
              .putIfAbsent(_nativeScope(p, session), () => {})
              .add(target.targetId);
          _nativePrepared.add(native);
          observed = CredentialBatchDestination.fromJson({
            'via': 'native',
            'target': native.target.toJson(),
          });
        } else if (approved.application != null) {
          if (driver == null) {
            throw const CredentialUseFailure('unsupported_capability');
          }
          final target = await driver!.prepare(approved.application!);
          prepared[id] = target;
          _prepared.add(target);
          observed = CredentialBatchDestination.fromJson({
            'via': 'focus',
            'application': target.application.toJson(),
          });
        } else {
          final target = approved.browser!;
          observed = await _inspectLocator(_locator(target));
        }
        if (!approved.matches(observed)) {
          throw const CredentialUseFailure('destination_changed');
        }
        destinations[id] = observed;
      }
      await _profile(p.serverId, _profileHash(p));
      journal = {
        ...journal,
        'phase': 'starting',
        'observations': destinations.map((k, v) => MapEntry(k, v.toJson())),
      };
      await _writeJournal(file, journal);
      final claim = await connection.call('$_base/begin', {
        'sessionSecret': session,
        'requestId': input['requestId'],
        'operationId': input['operationId'],
        if (input.containsKey('itemIds')) 'itemIds': ids,
      });
      final proof = claim.remove('privateProof');
      if (proof is! String) {
        final uncertain =
            claim['status'] == 'service_unavailable' &&
            (claim['errorCode'] == null ||
                {
                  'service_unavailable',
                  'audit_unavailable',
                }.contains(claim['errorCode']));
        if (!uncertain) {
          // A definite refusal (including busy) did not register an operation.
          // Keep the intent, without pretending an input might have started.
          await _writeJournal(file, {...journal, 'phase': 'intent'});
        }
        return uncertain
            ? _unknown(
                input['operationId'] as String,
                input['requestId'] as String,
              )
            : _public(claim);
      }
      final operationConnection = _connection(p);
      detached = true;
      _track(
        _perform(
              p,
              operationConnection,
              proof,
              input,
              file,
              journal,
              destinations,
              prepared,
              nativePrepared,
            )
            .catchError((Object _) {})
            .whenComplete(() => _dispose(operationConnection)),
      );
      return _public(claim);
    } finally {
      if (!detached) {
        await _closePrepared(prepared.values);
        await _closeNativePrepared(nativePrepared.values);
      }
    }
  }

  Future<void> _perform(
    AgentConnectionProfile p,
    AgentConnection connection,
    String proof,
    Map<String, dynamic> input,
    File file,
    Map<String, dynamic> journal,
    Map<String, CredentialBatchDestination> targets,
    Map<String, PreparedFocusedFill> prepared,
    Map<String, PreparedNativeFill> nativePrepared,
  ) async {
    final materials = <String, List<int>>{};
    final results = {for (final id in targets.keys) id: 'not_attempted'};
    var state = 'refused';
    String? code;
    String? activeId;
    var authorized = false, anySent = false, inputInFlight = false;
    final deadline = Stopwatch()..start();
    Future<void> authorize() async {
      if (_closed || deadline.elapsed >= const Duration(seconds: 28)) {
        throw const CredentialUseFailure('session_unavailable');
      }
      await _profile(p.serverId, _profileHash(p));
      authorized = true;
      _requireOk(
        await connection.call('$_base/authorize', {'privateProof': proof}),
      );
      if (_closed || deadline.elapsed >= const Duration(seconds: 28)) {
        throw const CredentialUseFailure('session_unavailable');
      }
      await _profile(p.serverId, _profileHash(p));
    }

    try {
      if (_closed) throw const CredentialUseFailure('session_unavailable');
      await _profile(p.serverId, _profileHash(p));
      final reply = await connection.call('$_base/material', {
        'privateProof': proof,
        'observations': targets.map((k, v) => MapEntry(k, v.toJson())),
      });
      _requireOk(reply);
      final values = _map(reply.remove('materials'));
      if (values.length != targets.length ||
          targets.keys.any((id) => !values.containsKey(id))) {
        throw const CredentialUseFailure('material_prepare_failed');
      }
      for (final id in targets.keys) {
        final encoded = values.remove(id);
        if (encoded is! String || encoded.length > 90000) {
          throw const CredentialUseFailure('material_prepare_failed');
        }
        final bytes = base64Decode(encoded);
        materials[id] = bytes;
        if (bytes.isEmpty || bytes.length > 65536) {
          throw const CredentialUseFailure('material_prepare_failed');
        }
      }
      for (final entry in targets.entries) {
        final id = entry.key, target = entry.value;
        activeId = id;
        if (target.browser != null) {
          // Each browser module rechecks the exact target again before writing.
          inputInFlight = true;
          final result = await browser.fill(
            target.browser!,
            materials[id]!,
            beforeDispatch: authorize,
          );
          inputInFlight = false;
          final received = result['status'];
          results[id] = {'filled', 'refused', 'unknown'}.contains(received)
              ? received as String
              : 'unknown';
          if (received != 'filled') {
            state = received == 'refused'
                ? (anySent
                      ? 'partial'
                      : authorized
                      ? 'failed'
                      : 'refused')
                : 'unknown';
            code = _resultCode(result['code']);
            break;
          }
        } else if (target.native != null) {
          inputInFlight = true;
          var dispatchChecked = false;
          NativeFillResult result;
          try {
            result = await nativePrepared[id]!.setValue(
              materials[id]!,
              beforeDispatch: () async {
                if (dispatchChecked) {
                  throw const CredentialUseFailure('operation_conflict');
                }
                await authorize();
                dispatchChecked = true;
              },
            );
          } on Object catch (error) {
            result = NativeFillResult(
              dispatchChecked
                  ? NativeFillState.unknown
                  : NativeFillState.refused,
              error is CredentialUseFailure
                  ? _nativeResultCode(error.code)
                  : 'fill_unknown',
            );
          }
          inputInFlight = false;
          final sent =
              dispatchChecked &&
              result.state == NativeFillState.sent &&
              result.errorCode == null;
          final refused = result.state == NativeFillState.refused;
          results[id] = sent
              ? 'sent'
              : refused
              ? 'refused'
              : 'unknown';
          if (!sent) {
            state = refused ? (anySent ? 'partial' : 'refused') : 'unknown';
            code = _nativeResultCode(result.errorCode ?? 'fill_unknown');
            break;
          }
        } else {
          inputInFlight = true;
          final result = await sendPreparedFocusedFill(
            prepared[id]!,
            materials[id]!,
            beforeBatch: authorize,
          );
          inputInFlight = false;
          results[id] = result.state == FocusedFillState.sent
              ? 'sent'
              : result.state == FocusedFillState.refused
              ? 'refused'
              : 'unknown';
          if (result.state != FocusedFillState.sent) {
            state =
                result.state == FocusedFillState.partial ||
                    anySent && result.state == FocusedFillState.refused
                ? 'partial'
                : result.state == FocusedFillState.refused
                ? 'failed'
                : 'unknown';
            code = _resultCode(result.errorCode);
            break;
          }
        }
        anySent = true;
        state = 'filled';
      }
    } on Object catch (error) {
      if (inputInFlight && activeId != null) results[activeId] = 'unknown';
      state = inputInFlight
          ? 'unknown'
          : anySent
          ? 'partial'
          : authorized
          ? 'failed'
          : 'refused';
      code = _resultCode(
        error is CredentialUseFailure
            ? error.code
            : error is BrowserFillFailure
            ? error.code
            : null,
      );
    } finally {
      for (final bytes in materials.values) {
        bytes.fillRange(0, bytes.length, 0);
      }
      materials.clear();
      await _closePrepared(prepared.values);
      await _closeNativePrepared(nativePrepared.values);
    }
    final reported = await connection.call('$_base/finish', {
      'privateProof': proof,
      'state': state,
      'itemResults': results,
      'errorCode': code,
    });
    final result = reported['status'] == 'ok'
        ? _public(reported)
        : _unknown(
            input['operationId'] as String,
            input['requestId'] as String,
          );
    await _writeJournal(file, {
      ...journal,
      'phase': 'completed',
      'result': result,
    });
  }

  Future<void> _closePrepared(Iterable<PreparedFocusedFill> values) async {
    for (final value in values) {
      try {
        await value.close();
      } on Object {
        /* Native expiry also closes. */
      }
      _prepared.remove(value);
    }
  }

  Future<void>? _closing;
  Future<void> _closeNativePrepared(Iterable<PreparedNativeFill> values) async {
    for (final value in values) {
      try {
        await value.close();
      } on Object {
        // Helper expiry independently invalidates the original reservation.
      }
      _nativePrepared.remove(value);
    }
  }

  String _nativeScope(AgentConnectionProfile p, String session) =>
      _hash({'profile': _profileHash(p), 'session': _hash(session)});

  void _requireNativeSupport(Map<String, dynamic> support) {
    if (nativeDriver == null ||
        !(support['capabilities'] as List? ?? []).contains(
          'credential-native-fill.v1',
        )) {
      throw const CredentialUseFailure('unsupported_capability');
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    for (final c in _connections.toList()) {
      c.close();
    }
    await _closePrepared(_prepared.toList());
    await _closeNativePrepared(_nativePrepared.toList());
    await _server.close(force: true);
    await Future.wait(_tasks.toList());
    for (final entry in _retainedNativeTargets.entries) {
      for (final targetId in entry.value) {
        try {
          await nativeDriver?.release(scope: entry.key, targetId: targetId);
        } on Object {
          // Loss of the original private helper connection also drops targets.
        }
      }
    }
    _retainedNativeTargets.clear();
    try {
      await writePrivateDeviceState(
        File('${directory.path}/$_folder/endpoint.json'),
        {..._record, 'phase': 'closed'},
      );
    } finally {
      await _lock.close();
    }
  }
}

String _nativeResultCode(Object? code) =>
    code == 'scope_not_approved' ? 'grant_revoked' : _resultCode(code);

String _resultCode(Object? code) =>
    {
      'browser_timeout',
      'browser_response_invalid',
      'browser_not_started',
    }.contains(code)
    ? 'browser_operation_failed'
    : credentialBatchErrorCodes.contains(code)
    ? code as String
    : 'service_unavailable';
Map<String, dynamic> _locator(BrowserFormTarget t) => {
  'via': t.provider,
  'url': t.url,
  'form': t.formSelector,
  'selector': t.fieldSelector,
  if (t.provider == 'ego') ...{
    'space': t.space,
    'page': t.pageId,
  } else ...{
    'browser': t.browserAddress,
    'tab': t.pageId,
  },
};
void _validateLocator(Map<String, dynamic> value) {
  final via = value['via'];
  if (via == 'native') {
    _shape(value, {'via', 'targetId'});
    if (!RegExp(
      r'^[A-Za-z0-9_-]{22,128}$',
    ).hasMatch(value['targetId'] as String? ?? '')) {
      throw const CredentialUseFailure('invalid_reference');
    }
    return;
  }
  if (via == 'focus') {
    _shape(value, {'via'});
    return;
  }
  if (via != 'ego' && via != 'chrome') {
    throw const CredentialUseFailure('unsupported_receiver');
  }
  _shape(value, {
    'via',
    'url',
    'form',
    'selector',
    if (via == 'ego') ...['space', 'page'] else ...['browser', 'tab'],
  });
  BrowserFormTarget.fromJson({
    'provider': via,
    'instanceId': 'unobserved',
    'structureDigest': '0' * 64,
    'url': value['url'],
    'form': value['form'],
    'field': value['selector'],
    'pageId': value[via == 'ego' ? 'page' : 'tab'],
    if (via == 'ego')
      'space': value['space']
    else
      'browserAddress': value['browser'],
  });
}

void _validateInput(Map<String, dynamic> value) {
  final command = value['command'];
  if (command == 'capabilities') {
    _shape(value, {'command'});
    return;
  }
  if (command == 'native-targets') {
    _shape(value, {'command', 'appId'}, {'windowId'});
    _text(value['appId'], max: 4096);
    if (value['windowId'] != null) _text(value['windowId'], max: 128);
    return;
  }
  _operation(value['operationId']);
  if (command == 'batch-status') {
    _shape(value, {'command', 'operationId'});
    return;
  }
  if (command == 'batch-run') {
    _shape(value, {'command', 'operationId', 'requestId'}, {'itemIds'});
    _text(value['requestId']);
    if (value.containsKey('itemIds')) {
      final ids = value['itemIds'];
      if (ids is! List ||
          ids.isEmpty ||
          ids.length > 20 ||
          ids.any(
            (i) => i is! String || !RegExp(r'^b[1-9][0-9]?$').hasMatch(i),
          ) ||
          ids.toSet().length != ids.length) {
        throw const CredentialUseFailure('invalid_reference');
      }
      value['itemIds'] = ids.cast<String>().toList()..sort();
    }
    return;
  }
  _shape(value, {'command', 'operationId', 'input'});
  final raw = _map(value['input']);
  _shape(raw, {
    'purpose',
    'agentName',
    'externalChatId',
    'submissionVersion',
    'items',
  });
  if (raw['submissionVersion'] != 1 ||
      submissionMetadataErrors(raw).isNotEmpty) {
    throw const CredentialUseFailure('invalid_submission_metadata');
  }
  final items = raw['items'];
  if (items is! List || items.isEmpty || items.length > 20) {
    throw const CredentialUseFailure('limit_exceeded');
  }
  for (final item in items) {
    final row = _map(item);
    _shape(row, {'credentialId', 'destination'}, {'version'});
    _text(row['credentialId'], max: 200);
    if (row.containsKey('version') &&
        (row['version'] is! int || (row['version'] as int) < 1)) {
      throw const CredentialUseFailure('invalid_type');
    }
    _validateLocator(_map(row['destination']));
  }
}

/// Only the defined public projection crosses App IPC or enters a journal.
Map<String, dynamic> _public(Map<String, dynamic> value) {
  final result = <String, dynamic>{'protocolVersion': 3};
  const fields = {
    'status',
    'requestId',
    'operationId',
    'purpose',
    'revision',
    'createdAt',
    'requestExpiresAt',
    'itemIds',
    'executionState',
    'finishedAt',
    'errorCode',
    'attentionAcknowledgedAt',
    'retryable',
    'operationClaimed',
    'capabilities',
    'providers',
  };
  for (final k in fields) {
    if (value.containsKey(k)) result[k] = value[k];
  }
  if (!const {
    'ok',
    'pending',
    'approved',
    'partially_approved',
    'denied',
    'expired',
    'revoked',
    'cancelled',
    'ended',
    'not_found',
    'unauthorized',
    'invalid_request',
    'conflict',
    'service_unavailable',
  }.contains(result['status'])) {
    return _failure('service_unavailable');
  }
  if (result['errorCode'] != null &&
      !_publicCodes.contains(result['errorCode'])) {
    result['errorCode'] = 'service_unavailable';
  }
  if (value['items'] is List) {
    result['items'] = [
      for (final row in value['items'] as List)
        {
          for (final k in const [
            'id',
            'credentialId',
            'name',
            'version',
            'decision',
            'grantState',
            'expiresAt',
            'account',
          ])
            if (_map(row).containsKey(k)) k: row[k],
          'destination': CredentialBatchDestination.fromJson(
            _map(_map(row)['destination']),
          ).toJson(),
        },
    ];
  }
  if (value['targets'] is List) {
    final targets = value['targets'] as List;
    if (targets.length > 64) return _failure('limit_exceeded');
    result['targets'] = [
      for (final target in targets)
        NativeFillTarget.fromJson(_map(target)).toJson(),
    ];
  }
  if (value['itemResults'] is Map) {
    result['itemResults'] = {
      for (final entry in (value['itemResults'] as Map).entries)
        if (entry.key is String &&
            RegExp(r'^b[1-9][0-9]?$').hasMatch(entry.key as String))
          entry.key:
              const {
                'filled',
                'sent',
                'refused',
                'failed',
                'unknown',
                'not_attempted',
              }.contains(entry.value)
              ? entry.value
              : 'unknown',
    };
  }
  return result;
}
