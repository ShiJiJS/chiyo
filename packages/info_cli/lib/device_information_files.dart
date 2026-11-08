import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';
import 'package:info_remote/agent_connection.dart';
import 'private_device_state.dart';

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
String _secret() => base64Url
    .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

Map<String, dynamic> _manifest(Map<String, dynamic> reply) {
  if (reply['status'] != 'ok' || reply['delivery'] is! Map) {
    throw InformationFileFailure(
      reply['errorCode'] as String? ?? 'delivery_unknown',
      operationClaimed: true,
    );
  }
  final result = Map<String, dynamic>.from(reply['delivery'] as Map);
  if (result['deviceDelivery'] != true ||
      result['deliveryId'] is! String ||
      result['cleanupCapability'] is! String ||
      !RegExp(
        r'^[A-Za-z0-9_-]{43}$',
      ).hasMatch(result['cleanupCapability'] as String) ||
      result['byteLength'] is! int ||
      (result['byteLength'] as int) < 0 ||
      (result['byteLength'] as int) > informationFileByteLimit ||
      result['sha256'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(result['sha256'] as String) ||
      result['fileName'] is! String ||
      result['mediaType'] is! String ||
      result['expiresAt'] is! String ||
      DateTime.tryParse(result['expiresAt'] as String) == null) {
    throw const InformationFileFailure(
      'delivery_unknown',
      operationClaimed: true,
    );
  }
  return result;
}

const _immutable = [
  'deliveryId',
  'operationId',
  'requestId',
  'itemId',
  'fieldId',
  'fieldVersion',
  'attachmentId',
  'attachmentVersion',
  'fileName',
  'mediaType',
  'byteLength',
  'sha256',
  'expiresAt',
  'cleanupCapability',
];
bool _sameManifest(Map a, Map b) => _immutable.every((key) => a[key] == b[key]);
Map<String, dynamic> _public(Map<String, dynamic> reply) {
  final delivery = reply['delivery'];
  if (delivery is! Map) return reply;
  return {
    ...reply,
    'delivery': {
      for (final key in [
        'deliveryId',
        'operationId',
        'requestId',
        'itemId',
        'fieldId',
        'fieldVersion',
        'attachmentVersion',
        'state',
        'expiresAt',
        'errorCode',
        'fileName',
        'mediaType',
        'byteLength',
        'path',
      ])
        if (delivery.containsKey(key)) key: delivery[key],
    },
  };
}

/// A private device journal, separate from the information library and Codex's
/// end-only index. It stores cleanup/control proofs, never readable chat proof.
/// A worker retains an OS lock for its whole lifetime; an observation timeout
/// never authorizes a replacement worker or a second original download.
final class DeviceInformationFiles {
  DeviceInformationFiles(this.profile, this.directory, {this.workerExecutable});
  final AgentConnectionProfile profile;
  final Directory directory;
  final String? workerExecutable;
  String get _deviceScope =>
      _digest('${profile.serverId}\n${profile.deviceToken}');
  static final _operations = <String, Future<void>>{};
  static Future<T> _serialize<T>(
    String key,
    Future<T> Function() action,
  ) async {
    final before = _operations[key] ?? Future<void>.value();
    final next = before.then((_) => action());
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _operations[key] = settled;
    try {
      return await next;
    } finally {
      if (identical(_operations[key], settled)) _operations.remove(key);
    }
  }

  /// Maintenance needs no readable chat proof or association lookup.
  Future<void> maintain() async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return;
    final folder = await privateDeviceDirectory(directory.absolute);
    var count = 0;
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File ||
          !RegExp(r'/[0-9a-f]{64}\.json$').hasMatch(entry.path)) {
        continue;
      }
      if (++count > informationDeliveryHistoryLimit) {
        throw const InformationFileFailure('delivery_capacity');
      }
      await _serialize(entry.path, () async {
        final record = await readPrivateDeviceState(entry);
        if (record == null ||
            record['deviceScope'] != _deviceScope ||
            {'released', 'expired', 'failed'}.contains(record['phase'])) {
          return;
        }
        if (record['workerPid'] is int &&
            record['workerIdentity'] is String &&
            CredentialProcessIdentity.isActive(
                  record['workerPid'] as int,
                  record['workerIdentity'] as String,
                ) ==
                false) {
          await _recoverDead(entry, record);
        }
      });
    }
  }

  Future<Map<String, dynamic>> fetch(
    String session,
    Map<String, dynamic> input,
    Map<String, dynamic> response,
  ) async {
    final manifest = _manifest(response);
    if (!{'preparing', 'ready'}.contains(manifest['state'])) {
      return _public(response);
    }
    final folder = await privateDeviceDirectory(directory.absolute);
    final scope = _digest(
      '${profile.serverId}\n${profile.deviceToken}\n$session',
    );
    final file = File(
      '${folder.path}/${_digest(manifest['deliveryId'] as String)}.json',
    );
    return _serialize(
      file.path,
      () => _fetch(file, scope, manifest, session, input),
    );
  }

  Future<Map<String, dynamic>> _fetch(
    File file,
    String scope,
    Map<String, dynamic> manifest,
    String session,
    Map<String, dynamic> input,
  ) async {
    final launch = File('${file.path}.launch');
    await privateDeviceFile(launch);
    final lock = await launch.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      var record = await readPrivateDeviceState(file);
      if (record != null &&
          (record['scope'] != scope ||
              record['manifest'] is! Map ||
              !_sameManifest(record['manifest'] as Map, manifest))) {
        throw const InformationFileFailure(
          'operation_conflict',
          operationClaimed: true,
        );
      }
      if (record == null) {
        // A committed ready operation without its journal cannot safely be
        // repeated: its former copy might still be in use elsewhere.
        if (manifest['state'] != 'preparing') {
          throw const InformationFileFailure(
            'delivery_unknown',
            operationClaimed: true,
          );
        }
        record = await _start(file, scope, manifest, session, input);
      }
      final wait = Stopwatch()..start();
      while (wait.elapsed < const Duration(seconds: 35)) {
        final current = await readPrivateDeviceState(file);
        if (current == null) break;
        if ({'released', 'expired', 'failed'}.contains(current['phase'])) {
          return Map<String, dynamic>.from(
            const InformationFileFailure(
              'delivery_unknown',
              operationClaimed: true,
            ).toJson(),
          );
        }
        // Only a process identity proves death. Never infer death from an old
        // receipt, inability to connect, elapsed observation, or PID alone.
        if (current['workerPid'] is int &&
            current['workerIdentity'] is String &&
            CredentialProcessIdentity.isActive(
                  current['workerPid'] as int,
                  current['workerIdentity'] as String,
                ) ==
                false) {
          await _recoverDead(file, current);
          break;
        }
        if (current['phase'] == 'ready' && current['port'] is int) {
          return _public(
            await _control(current, 'fetch', {
              'sessionSecret': session,
              'input': input,
            }),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw const InformationFileFailure(
        'delivery_unknown',
        operationClaimed: true,
      );
    } finally {
      await lock.close();
    }
  }

  Future<Map<String, dynamic>> release(
    String session,
    Map<String, dynamic> response,
  ) async {
    final delivery = response['delivery'];
    if (delivery is! Map || delivery['deliveryId'] is! String) {
      return _public(response);
    }
    final file = File(
      '${directory.absolute.path}/${_digest(delivery['deliveryId'] as String)}.json',
    );
    final record = await readPrivateDeviceState(file);
    if (record == null ||
        record['scope'] !=
            _digest('${profile.serverId}\n${profile.deviceToken}\n$session')) {
      return _public(response);
    }
    bool cleaned(Map value) =>
        value['lease'] == null &&
        {'released', 'expired'}.contains(value['phase']);
    if (cleaned(record)) return _public(response);
    if (record['workerPid'] is int &&
        record['workerIdentity'] is String &&
        CredentialProcessIdentity.isActive(
              record['workerPid'] as int,
              record['workerIdentity'] as String,
            ) ==
            false) {
      await _recoverDead(file, record);
      return _public(response);
    }
    final result = await _control(record, 'release', {});
    if (result['status'] != 'ok') {
      // The periodic guardian may finish cleanup and close its control socket
      // between the server release and this request. Only its original,
      // acknowledged terminal journal can resolve that race as successful.
      final latest = await readPrivateDeviceState(file);
      if (latest != null &&
          latest['scope'] == record['scope'] &&
          latest['manifest'] is Map &&
          record['manifest'] is Map &&
          _sameManifest(latest['manifest'] as Map, record['manifest'] as Map) &&
          cleaned(latest)) {
        return _public(response);
      }
    }
    return _public(result);
  }

  Future<Map<String, dynamic>> _start(
    File file,
    String scope,
    Map<String, dynamic> manifest,
    String session,
    Map<String, dynamic> input,
  ) async {
    final runtime = Platform.resolvedExecutable;
    final interpreted =
        workerExecutable == null &&
        RegExp(r'/(dart|dartvm)$').hasMatch(runtime);
    final worker =
        workerExecutable ??
        (interpreted
            ? (await Isolate.resolvePackageUri(
                Uri.parse('package:info_cli/runtime_worker.dart'),
              ))!.toFilePath()
            : '${File(runtime).parent.path}/info-runtime-worker');
    final args = [
      if (interpreted) ...[
        '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
        worker,
      ],
      '--information-file-guardian',
    ];
    if (!await File(worker).exists()) {
      throw const InformationFileFailure('delivery_io_failed');
    }
    final process = await Process.start(
      interpreted ? runtime : worker,
      args,
      mode: ProcessStartMode.detachedWithStdio,
      runInShell: false,
    );
    // The worker publishes only private receipts. Close its unused output
    // handles now so a one-command CLI does not stay alive for its lifetime.
    await process.stdout.listen((_) {}).cancel();
    await process.stderr.listen((_) {}).cancel();
    final identity = CredentialProcessIdentity.capture(process.pid);
    if (identity == null) {
      await process.stdin.close();
      throw const InformationFileFailure(
        'delivery_unknown',
        operationClaimed: true,
      );
    }
    final record = <String, dynamic>{
      'version': 1,
      'scope': scope,
      'deviceScope': _deviceScope,
      'manifest': manifest,
      'phase': 'starting',
      'workerPid': process.pid,
      'workerIdentity': identity.value,
      'controlCapability': _secret(),
    };
    identity.close();
    try {
      await writePrivateDeviceState(file, record);
      process.stdin.writeln(
        jsonEncode({
          'statePath': file.path,
          'profile': profile.toPrivateJson(),
          'sessionSecret': session,
          'input': input,
        }),
      );
      process.stdin.writeln('start');
      await process.stdin.close();
      return record;
    } on Object {
      await process.stdin.close();
      rethrow;
    }
  }

  Future<void> _recoverDead(File file, Map<String, dynamic> record) async {
    final guard = File('${file.path}.guard');
    await privateDeviceFile(guard);
    final handle = await guard.open(mode: FileMode.append);
    try {
      // A replacement or still active worker owns this lock; don't race it.
      await handle.lock(FileLock.exclusive);
      final lease = record['lease'];
      if (lease is Map) {
        await NativeInformationDeliveryFiles().cleanup(
          InformationDeliveryLease.fromPrivateJson(
            Map<String, dynamic>.from(lease),
          ),
        );
      }
      final connection = AgentConnection(profile);
      try {
        final manifest = record['manifest'] as Map;
        final result = await connection.call('/information-file/discard', {
          'protocolVersion': 2,
          'command': 'file-discard',
          'deliveryId': manifest['deliveryId'],
          'cleanupCapability': manifest['cleanupCapability'],
        });
        await writePrivateDeviceState(file, {
          ...record,
          'lease': null,
          'phase': result['status'] == 'ok' ? 'released' : 'cleanup_pending',
        });
      } finally {
        connection.close();
      }
    } on FileSystemException {
      // Lock ownership is inconclusive. Preserve the journal and do not respawn.
    } finally {
      await handle.close();
    }
  }
}

Future<Map<String, dynamic>> _control(
  Map<String, dynamic> record,
  String action,
  Map<String, dynamic> body,
) async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    return await (() async {
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:${record['port']}/$action'),
      );
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(
        'authorization',
        'Bearer ${record['controlCapability']}',
      );
      request.write(jsonEncode(body));
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 16384) {
          throw const FormatException();
        }
        bytes.addAll(chunk);
      }
      return decodeProtocolObject(utf8.decode(bytes), maxBytes: 16384);
    })().timeout(const Duration(seconds: 35));
  } on Object {
    return Map<String, dynamic>.from(
      const InformationFileFailure(
        'delivery_unknown',
        operationClaimed: true,
      ).toJson(),
    );
  } finally {
    http.close(force: true);
  }
}

/// Internal worker mode. stdin is the sole bootstrap channel. A durable
/// reservation precedes all plaintext writes; private cleanup proof suffices
/// after bootstrap, so no chat read proof is retained on disk or in the timer.
Future<void> runInformationFileGuardian() async {
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  RandomAccessFile? guard;
  _Guardian? guardian;
  try {
    if (!await input.moveNext() || utf8.encode(input.current).length > 262144) {
      throw const FormatException();
    }
    final plan = decodeProtocolObject(input.current);
    final file = File(plan['statePath'] as String);
    await privateDeviceDirectory(file.parent);
    final record = await readPrivateDeviceState(file);
    if (record == null ||
        record['workerPid'] != pid ||
        record['workerIdentity'] is! String ||
        CredentialProcessIdentity.isActive(
              pid,
              record['workerIdentity'] as String,
            ) !=
            true) {
      throw const FormatException();
    }
    final guardFile = File('${file.path}.guard');
    await privateDeviceFile(guardFile);
    guard = await guardFile.open(mode: FileMode.append);
    await guard.lock(FileLock.exclusive);
    if (!await input.moveNext() || input.current != 'start') {
      throw const FormatException();
    }
    guardian = _Guardian(
      file,
      record,
      AgentConnectionProfile.fromPrivateJson(
        Map<String, dynamic>.from(plan['profile'] as Map),
      ),
    );
    await guardian.run(
      plan.remove('sessionSecret') as String,
      Map<String, dynamic>.from(plan.remove('input') as Map),
    );
  } on Object {
    exitCode = 70;
  } finally {
    await guardian?.close();
    await guard?.close();
    await input.cancel();
  }
}

final class _Guardian {
  _Guardian(this.file, this.record, AgentConnectionProfile profile)
    : connection = AgentConnection(profile);
  final File file;
  Map<String, dynamic> record;
  final AgentConnection connection;
  final files = NativeInformationDeliveryFiles();
  final stopped = Completer<void>();
  HttpServer? server;
  Future<void> queue = Future.value();
  final elapsed = Stopwatch()..start();
  late final Duration lifetime = DateTime.parse(
    (record['manifest'] as Map)['expiresAt'] as String,
  ).difference(DateTime.now().toUtc());
  Map<String, dynamic> get manifest =>
      Map<String, dynamic>.from(record['manifest'] as Map);
  InformationDeliveryLease? get lease => record['lease'] is Map
      ? InformationDeliveryLease.fromPrivateJson(
          Map<String, dynamic>.from(record['lease'] as Map),
        )
      : null;
  Future<void> save(Map<String, dynamic> changes) async {
    record = {...record, ...changes};
    await writePrivateDeviceState(file, record);
  }

  Future<T> serialize<T>(Future<T> Function() action) {
    final next = queue.then((_) => action());
    queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> values = const {},
  ]) => connection.call('/information-file/$action', {
    'protocolVersion': 2,
    'command': 'file-$action',
    'deliveryId': manifest['deliveryId'],
    ...values,
  }, timeout: const Duration(seconds: 15));
  Future<Map<String, dynamic>> watch() =>
      call('watch', {'cleanupCapability': manifest['cleanupCapability']});

  Future<void> run(String session, Map<String, dynamic> input) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) {
      unawaited(_serve(request));
    });
    await save({'port': server!.port, 'phase': 'preparing'});
    await serialize(() async {
      try {
        if (lifetime <= Duration.zero) {
          throw const InformationFileFailure('grant_expired');
        }
        final extension = (manifest['fileName'] as String)
            .split('.')
            .last
            .toLowerCase();
        final reserved = await files.reserve(
          'attachment.${RegExp(r'^[a-z0-9]{1,12}$').hasMatch(extension) ? extension : 'bin'}',
        );
        try {
          await save({'lease': reserved.toPrivateJson()});
        } on Object {
          await files.cleanup(reserved);
          rethrow;
        }
        final downloaded = await call('download', {'sessionSecret': session});
        if (!_sameManifest(_manifest(downloaded), manifest) ||
            downloaded['bytes'] is! String) {
          throw const InformationFileFailure('attachment_integrity_failed');
        }
        final bytes = base64Decode(downloaded.remove('bytes') as String);
        if (bytes.length != manifest['byteLength'] ||
            sha256.convert(bytes).toString() != manifest['sha256']) {
          throw const InformationFileFailure('attachment_integrity_failed');
        }
        await files.write(reserved, bytes);
        await files.verify(
          reserved,
          manifest['byteLength'] as int,
          manifest['sha256'] as String,
        );
        final completed = await call('complete', {
          'sessionSecret': session,
          'byteLength': manifest['byteLength'],
          'sha256': manifest['sha256'],
        });
        if (!_sameManifest(_manifest(completed), manifest) ||
            (completed['delivery'] as Map)['state'] != 'ready') {
          throw const InformationFileFailure('delivery_unknown');
        }
        await save({'phase': 'ready'});
      } on Object {
        await cleanup();
      } finally {
        session = '';
        input.clear();
      }
    });
    while (!stopped.isCompleted) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await serialize(() async {
        if (stopped.isCompleted) return;
        final result = await watch();
        if (record['phase'] == 'cleanup_pending' ||
            elapsed.elapsed >= lifetime ||
            result['status'] != 'ok' ||
            !{
              'ready',
              'preparing',
            }.contains((result['delivery'] as Map?)?['state'])) {
          await cleanup();
        }
      });
    }
  }

  Future<Map<String, dynamic>> cleanup() async {
    await save({'phase': 'cleanup_pending'});
    final copy = lease;
    if (copy != null) await files.cleanup(copy);
    // A crash after unlink but before this write is recovered by idempotent
    // identity-checked cleanup, never a new original download.
    await save({'lease': null});
    final result = await call('discard', {
      'cleanupCapability': manifest['cleanupCapability'],
    });
    if (result['status'] == 'ok') {
      final state = (result['delivery'] as Map)['state'];
      await save({'phase': state == 'expired' ? 'expired' : 'released'});
      if (!stopped.isCompleted) stopped.complete();
    }
    return result;
  }

  Future<void> _serve(HttpRequest request) async {
    Map<String, dynamic> result;
    try {
      if (request.method != 'POST' ||
          request.headers.value('origin') != null ||
          request.headers.value('authorization') !=
              'Bearer ${record['controlCapability']}' ||
          request.headers.value('host') != '127.0.0.1:${server!.port}') {
        throw const FormatException();
      }
      final bytes = <int>[];
      await for (final chunk in request) {
        if (bytes.length + chunk.length > 16384) {
          throw const FormatException();
        }
        bytes.addAll(chunk);
      }
      final body = decodeProtocolObject(utf8.decode(bytes), maxBytes: 16384);
      result = await serialize(() async {
        if (request.uri.path == '/release' && body.isEmpty) return cleanup();
        if (request.uri.path != '/fetch' ||
            body.length != 2 ||
            body['sessionSecret'] is! String ||
            body['input'] is! Map ||
            record['phase'] != 'ready' ||
            lease == null ||
            elapsed.elapsed >= lifetime) {
          throw const InformationFileFailure('not_authorized');
        }
        final submitted = Map<String, dynamic>.from(body['input'] as Map);
        InformationFileFetchInput.fromJson(submitted);
        final fresh = await connection.call('/information-file/fetch', {
          ...submitted,
          'sessionSecret': body['sessionSecret'],
        });
        if (!_sameManifest(_manifest(fresh), manifest) ||
            (fresh['delivery'] as Map)['state'] != 'ready') {
          throw const InformationFileFailure('not_authorized');
        }
        try {
          await files.verify(
            lease!,
            manifest['byteLength'] as int,
            manifest['sha256'] as String,
          );
        } on Object {
          await cleanup();
          rethrow;
        }
        final checked = await watch();
        if (checked['status'] != 'ok' ||
            (checked['delivery'] as Map)['state'] != 'ready' ||
            elapsed.elapsed >= lifetime) {
          await cleanup();
          throw const InformationFileFailure('not_authorized');
        }
        return {
          'protocolVersion': 2,
          'status': 'ok',
          'delivery': {...manifest, 'state': 'ready', 'path': lease!.filePath},
        };
      });
    } on InformationFileFailure catch (error) {
      result = Map<String, dynamic>.from(error.toJson());
    } on Object {
      result = Map<String, dynamic>.from(
        const InformationFileFailure(
          'delivery_unknown',
          operationClaimed: true,
        ).toJson(),
      );
    }
    try {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(_public(result)));
      await request.response.close();
    } on Object {
      /* A lost reply never authorizes another physical copy. */
    }
  }

  Future<void> close() async {
    await server?.close(force: true);
    connection.close();
  }
}
