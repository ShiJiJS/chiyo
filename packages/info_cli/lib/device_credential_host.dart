import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';
import 'package:info_remote/agent_connection.dart';
import 'credential_execution_host.dart';
import 'device_credential_journal.dart';
import 'private_device_state.dart';
import 'runtime_worker_command.dart';

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
String _proof() => base64Url
    .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');
Map<String, dynamic> _failure(String code, {bool uncertain = false}) =>
    Map<String, dynamic>.from(
      CredentialUseFailure(
        code,
        attemptConsumed: uncertain,
      ).toJson(protocolVersion: 2),
    );

void _validate(Map<String, dynamic> record) {
  if (record.length != 8 ||
      !record.keys.toSet().containsAll(const {
        'version',
        'scope',
        'profileHash',
        'workerPid',
        'workerIdentity',
        'controlCapability',
        'phase',
        'port',
      }) ||
      record['version'] != 1 ||
      record['scope'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(record['scope'] as String) ||
      record['profileHash'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(record['profileHash'] as String) ||
      record['workerPid'] is! int ||
      (record['workerPid'] as int) < 1 ||
      record['workerIdentity'] is! String ||
      (record['workerIdentity'] as String).isEmpty ||
      record['controlCapability'] is! String ||
      !RegExp(
        r'^[A-Za-z0-9_-]{43}$',
      ).hasMatch(record['controlCapability'] as String) ||
      !const {'starting', 'ready', 'closed'}.contains(record['phase']) ||
      (record['phase'] == 'ready'
          ? record['port'] is! int ||
                (record['port'] as int) < 1 ||
                (record['port'] as int) > 65535
          : record['port'] != null)) {
    throw const CredentialUseFailure('service_unavailable');
  }
}

/// Device-private loopback control for the existing bounded executor. The
/// durable locator cannot read information or start work without the original
/// session proof supplied by the calling adapter; that proof stays in memory.
final class DeviceCredentialHost {
  DeviceCredentialHost(this.profile, this.deviceFiles, {this.workerExecutable});
  final AgentConnectionProfile profile;
  final Directory deviceFiles;
  final String? workerExecutable;
  String get _scope => _hash('${profile.serverId}\n${profile.deviceToken}');
  String get _profileHash => _hash(jsonEncode(profile.toPrivateJson()));
  Directory get directory =>
      Directory('${deviceFiles.absolute.parent.path}/credential-host');
  static final _queues = <String, Future<void>>{};
  Future<T> _serialize<T>(Future<T> Function() action) async {
    final key = '${directory.path}/$_scope';
    final next = (_queues[key] ?? Future<void>.value()).then((_) => action());
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _queues[key] = settled;
    try {
      return await next;
    } finally {
      if (identical(_queues[key], settled)) _queues.remove(key);
    }
  }

  Future<Map<String, dynamic>> execute(
    String session,
    Map<String, dynamic> input,
  ) async {
    try {
      final record = await _serialize(_record);
      return await _control(record, '/execute', {
        'sessionSecret': session,
        'input': input,
      }, uncertain: input['command'] == 'run-use');
    } on Object {
      // No timeout/failed probe creates a replacement while the original Host
      // identity or its lifetime lock is still live or inconclusive.
      final uncertain = input['command'] == 'run-use';
      return _failure(
        uncertain ? 'material_claim_failed' : 'service_unavailable',
        uncertain: uncertain,
      );
    }
  }

  /// Trusted lifecycle utility, not an Agent JSON-lines command. It refuses to
  /// stop any active execution; finished in-memory output may be discarded.
  Future<Map<String, dynamic>> stopIfIdle() async {
    try {
      final folder = await privateDeviceDirectory(directory);
      final record = await readPrivateDeviceState(
        File('${folder.path}/$_scope.json'),
      );
      if (record == null) return {'status': 'ok'};
      _validate(record);
      if (record['scope'] != _scope || record['profileHash'] != _profileHash) {
        return _failure('service_unavailable');
      }
      if (CredentialProcessIdentity.isActive(
            record['workerPid'] as int,
            record['workerIdentity'] as String,
          ) ==
          false) {
        return {'status': 'ok'};
      }
      return await _control(record, '/stop', const {});
    } on Object {
      return _failure('service_unavailable');
    }
  }

  Future<Map<String, dynamic>> _record() async {
    final folder = await privateDeviceDirectory(directory);
    final file = File('${folder.path}/$_scope.json');
    final guardFile = File('${file.path}.launch');
    await privateDeviceFile(guardFile);
    final guard = await guardFile.open(mode: FileMode.append);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    try {
      while (true) {
        try {
          await guard.lock(FileLock.exclusive);
          break;
        } on FileSystemException {
          if (DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      var record = await readPrivateDeviceState(file);
      if (record != null) {
        _validate(record);
        if (record['scope'] != _scope ||
            record['profileHash'] != _profileHash) {
          throw const CredentialUseFailure('service_unavailable');
        }
        final alive = CredentialProcessIdentity.isActive(
          record['workerPid'] as int,
          record['workerIdentity'] as String,
        );
        if (alive != false) return await _ready(file, record);
      }
      // The durable locator alone is not the authority for absence. A live
      // daemon retains this separate OS lock, including across caller death.
      final lifetimeFile = File('${file.path}.host');
      await privateDeviceFile(lifetimeFile);
      final lifetime = await lifetimeFile.open(mode: FileMode.append);
      try {
        await lifetime.lock(FileLock.exclusive);
      } finally {
        await lifetime.close();
      }
      record = await _spawn(file);
      return await _ready(file, record);
    } finally {
      await guard.close();
    }
  }

  Future<Map<String, dynamic>> _spawn(File file) async {
    final worker = await RuntimeWorkerCommand.resolve(
      workerExecutable: workerExecutable,
    );
    final system = Platform.isWindows
        ? Platform.environment['SystemRoot']
        : null;
    if (Platform.isWindows && (system == null || system.isEmpty)) {
      throw const CredentialUseFailure('service_unavailable');
    }
    final environment = Platform.isWindows
        ? <String, String>{
            'SystemRoot': system!,
            'WINDIR': system,
            'COMSPEC': '$system\\System32\\cmd.exe',
            'PATH': '$system\\System32',
            'HOME': file.parent.path,
            'USERPROFILE': file.parent.path,
            'APPDATA': file.parent.path,
            'LOCALAPPDATA': file.parent.path,
            'TEMP': Directory.systemTemp.path,
            'TMP': Directory.systemTemp.path,
          }
        : <String, String>{
            'PATH': '/usr/bin:/bin',
            'HOME': file.parent.path,
            'TMPDIR': Directory.systemTemp.path,
            'LANG': 'C.UTF-8',
          };
    final process = await Process.start(
      worker.executable,
      [...worker.arguments, '--credential-execution-host'],
      mode: ProcessStartMode.detachedWithStdio,
      runInShell: false,
      environment: environment,
      includeParentEnvironment: false,
    );
    await process.stdout.listen((_) {}).cancel();
    await process.stderr.listen((_) {}).cancel();
    final identity = CredentialProcessIdentity.capture(process.pid);
    if (identity == null) {
      await process.stdin.close();
      throw const CredentialUseFailure('service_unavailable');
    }
    try {
      final record = <String, dynamic>{
        'version': 1,
        'scope': _scope,
        'profileHash': _profileHash,
        'workerPid': process.pid,
        'workerIdentity': identity.value,
        'controlCapability': _proof(),
        'phase': 'starting',
        'port': null,
      };
      await writePrivateDeviceState(file, record);
      process.stdin.writeln(
        jsonEncode({
          'statePath': file.path,
          'profile': profile.toPrivateJson(),
          'deviceFiles': deviceFiles.absolute.path,
          'workerExecutable': worker.worker,
        }),
      );
      process.stdin.writeln('start');
      await process.stdin.close();
      return record;
    } on Object {
      await process.stdin.close();
      rethrow;
    } finally {
      identity.close();
    }
  }

  Future<Map<String, dynamic>> _ready(
    File file,
    Map<String, dynamic> original,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final record = await readPrivateDeviceState(file);
      if (record == null) {
        throw const CredentialUseFailure('service_unavailable');
      }
      _validate(record);
      if (record['workerPid'] != original['workerPid'] ||
          record['workerIdentity'] != original['workerIdentity'] ||
          record['controlCapability'] != original['controlCapability'] ||
          record['scope'] != _scope ||
          record['profileHash'] != _profileHash) {
        throw const CredentialUseFailure('service_unavailable');
      }
      if (record['phase'] == 'ready') return record;
      if (record['phase'] == 'closed' ||
          DateTime.now().isAfter(deadline) ||
          CredentialProcessIdentity.isActive(
                record['workerPid'] as int,
                record['workerIdentity'] as String,
              ) ==
              false) {
        throw const CredentialUseFailure('service_unavailable');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }
}

Future<Map<String, dynamic>> _control(
  Map<String, dynamic> record,
  String path,
  Map<String, dynamic> body, {
  bool uncertain = false,
}) async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    return await (() async {
      if (record['phase'] != 'ready') throw const FormatException();
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:${record['port']}$path'),
      );
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(
        'authorization',
        'Bearer ${record['controlCapability']}',
      );
      request.write(jsonEncode(body));
      final response = await request.close();
      final result = decodeProtocolObject(
        utf8.decode(await _bounded(response, 262144)),
      );
      if (response.statusCode != 200 || result['status'] is! String) {
        throw const FormatException();
      }
      return result;
    })().timeout(const Duration(seconds: 35));
  } on Object {
    return _failure(
      uncertain ? 'material_claim_failed' : 'service_unavailable',
      uncertain: uncertain,
    );
  } finally {
    http.close(force: true);
  }
}

Future<List<int>> _bounded(Stream<List<int>> stream, int limit) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) throw const FormatException();
    bytes.addAll(chunk);
  }
  return bytes;
}

/// Internal worker bootstrap contains the device connection but no session.
/// Each authenticated local call supplies its own exact original session in
/// memory; the executor still checks server approval before material/output.
Future<void> runDeviceCredentialHost() async {
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  RandomAccessFile? lifetime;
  _Resident? resident;
  try {
    if (!await input.moveNext() || utf8.encode(input.current).length > 262144) {
      throw const FormatException();
    }
    final plan = decodeProtocolObject(input.current);
    final file = File(plan['statePath'] as String);
    await privateDeviceDirectory(file.parent);
    final record = await readPrivateDeviceState(file);
    if (record == null) throw const FormatException();
    _validate(record);
    final profile = AgentConnectionProfile.fromPrivateJson(
      plan['profile'] as Map<String, dynamic>,
    );
    if (record['workerPid'] != pid ||
        record['phase'] != 'starting' ||
        record['scope'] !=
            _hash('${profile.serverId}\n${profile.deviceToken}') ||
        record['profileHash'] != _hash(jsonEncode(profile.toPrivateJson())) ||
        CredentialProcessIdentity.isActive(
              pid,
              record['workerIdentity'] as String,
            ) !=
            true) {
      throw const FormatException();
    }
    final guard = File('${file.path}.host');
    await privateDeviceFile(guard);
    lifetime = await guard.open(mode: FileMode.append);
    await lifetime.lock(FileLock.exclusive);
    if (!await input.moveNext() || input.current != 'start') {
      throw const FormatException();
    }
    resident = _Resident(
      file,
      record,
      profile,
      Directory(plan['deviceFiles'] as String),
      plan['workerExecutable'] as String,
    );
    await resident.run();
  } on Object {
    exitCode = 70;
  } finally {
    await resident?.close();
    await lifetime?.close();
    await input.cancel();
  }
}

final class _Resident {
  _Resident(
    this.file,
    this.record,
    this.profile,
    this.deviceFiles,
    String worker,
  ) : host = CredentialExecutionHost(
        port: profile.address.port,
        connection: profile,
        deviceFileStateDirectory: deviceFiles,
        workerExecutable: worker,
      );
  final File file;
  Map<String, dynamic> record;
  final AgentConnectionProfile profile;
  final Directory deviceFiles;
  final CredentialExecutionHost host;
  final stopped = Completer<void>();
  HttpServer? server;
  Timer? timer;
  DateTime touched = DateTime.now();
  bool closing = false;
  Future<void>? maintenance;
  Future<void> commands = Future.value();
  Future<T> serialize<T>(Future<T> Function() action) {
    final next = commands.then((_) => action());
    commands = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> run() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) {
      unawaited(_serve(request));
    });
    record = {...record, 'phase': 'ready', 'port': server!.port};
    await writePrivateDeviceState(file, record);
    timer = Timer.periodic(const Duration(seconds: 15), (_) {
      maintenance ??=
          DeviceCredentialJournal(
                profile,
                Directory(
                  '${deviceFiles.absolute.parent.path}/credential-executions',
                ),
              )
              .maintain()
              .catchError((Object _) {})
              .whenComplete(() => maintenance = null);
      if (host.isIdle &&
          DateTime.now().difference(touched) > const Duration(minutes: 1)) {
        closing = true;
        if (!stopped.isCompleted) stopped.complete();
      }
    });
    await stopped.future;
  }

  Future<void> _serve(HttpRequest request) async {
    var acceptedStop = false;
    try {
      if (closing ||
          request.method != 'POST' ||
          request.uri.hasQuery ||
          !const {'/execute', '/stop'}.contains(request.uri.path) ||
          request.headers.value('origin') != null ||
          request.headers.value('host') != '127.0.0.1:${server!.port}' ||
          request.headers.value('authorization') !=
              'Bearer ${record['controlCapability']}') {
        request.response.statusCode = 403;
        return;
      }
      final body = decodeProtocolObject(
        utf8.decode(await _bounded(request, 262144)),
      );
      final result = await serialize<Map<String, dynamic>>(() async {
        if (closing) return _failure('service_unavailable');
        if (request.uri.path == '/stop') {
          if (body.isNotEmpty) throw const FormatException();
          acceptedStop = host.canStop;
          if (acceptedStop) closing = true;
          return acceptedStop ? {'status': 'ok'} : _failure('cleanup_busy');
        }
        if (body.length != 2 ||
            body['sessionSecret'] is! String ||
            (body['sessionSecret'] as String).isEmpty ||
            (body['sessionSecret'] as String).length > 2000 ||
            body['input'] is! Map<String, dynamic>) {
          throw const FormatException();
        }
        touched = DateTime.now();
        return await host.execute(
          body['sessionSecret'] as String,
          body['input'] as Map<String, dynamic>,
        );
      });
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    } on Object {
      try {
        request.response.statusCode = 400;
        request.response.write('{"status":"invalid_request"}');
      } on Object {
        /* Disconnected caller cannot cancel an admitted operation. */
      }
    } finally {
      try {
        await request.response.close();
      } on Object {
        /* disconnected */
      }
      if (acceptedStop && !stopped.isCompleted) stopped.complete();
    }
  }

  Future<void> close() async {
    closing = true;
    timer?.cancel();
    await maintenance;
    await host.drain();
    host.close();
    await server?.close(force: true);
    record = {...record, 'phase': 'closed', 'port': null};
    await writePrivateDeviceState(file, record);
  }
}
