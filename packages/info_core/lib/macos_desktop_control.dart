import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'package:ffi/ffi.dart';
import 'runtime_process_identity.dart';

const _states = {
  'starting',
  'running',
  'exiting',
  'shutdown_failed',
  'startup_failed',
};
String _nonce() {
  final random = Random.secure();
  return List.generate(
    32,
    (_) => random.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// A separate owner-process lifetime entry. Never installed on AgentServer and
/// never accepts content commands, executable paths, signals or information IDs.
/// The private registry is machine-local and must not be backed up or exported.
class MacDesktopControlHost {
  MacDesktopControlHost._(
    this._directory,
    this._lock,
    this._server,
    this._record,
    this._state,
    this._quit,
  );
  final Directory _directory;
  final RandomAccessFile _lock;
  final ServerSocket _server;
  final Map<String, Object?> _record;
  final String Function() _state;
  final Future<void> Function() _quit;
  final _clients = <Socket>{};
  final _operations = <String>{};
  bool _quitting = false, _failed = false, _closed = false;
  Future<void> _writes = Future.value();

  static Future<MacDesktopControlHost> start({
    required Directory directory,
    required String Function() state,
    required Future<void> Function() quit,
  }) async {
    if (!Platform.isMacOS) throw UnsupportedError('Darwin control required');
    final native = _Native.instance;
    final own = native.process(pid);
    if (own == null) throw StateError('control_unavailable');
    final exists = await directory.exists();
    if (!exists) {
      await directory.create(recursive: true);
      native.chmodOwner(directory.path, 0x1c0); // 0700
    }
    native.checkOwner(directory.path, directory: true);
    final lockFile = File('${directory.path}/owner.lock');
    if (await FileSystemEntity.type(lockFile.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      native.checkOwner(lockFile.path);
    }
    final lock = await lockFile.open(mode: FileMode.append);
    ServerSocket? server;
    try {
      native.chmodOwner(lockFile.path, 0x180); // 0600, inside private directory
      native.checkOwner(lockFile.path);
      await lock.lock(
        FileLock.exclusive,
      ); // Nonblocking; another owner stays in control.
      final registry = File('${directory.path}/endpoint.json');
      if (await FileSystemEntity.type(registry.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        final old = await _readRecord(directory);
        if (CredentialProcessIdentity.isActive(
              old['processId'] as int,
              old['createdAt'] as String,
            ) !=
            false) {
          throw StateError('control_already_owned');
        }
      }
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final host = MacDesktopControlHost._(
        directory,
        lock,
        server,
        {
          'controlVersion': 1,
          'processId': pid,
          'createdAt': own.createdAt,
          'executable': own.executable,
          'port': server.port,
          'token': _nonce(),
          'exitCommitted': false,
        },
        state,
        quit,
      );
      await host._writeRecord();
      server.listen(host._accept);
      return host;
    } on Object {
      await server?.close();
      await lock.close();
      rethrow;
    }
  }

  String get _currentState {
    final actual = _state();
    if (_failed || actual == 'shutdown_failed') return 'shutdown_failed';
    if (_quitting) return 'exiting';
    return _states.contains(actual) ? actual : 'startup_failed';
  }

  void _accept(Socket socket) {
    _observeSocketCompletion(socket);
    if (_closed || _clients.length >= 8) {
      socket.destroy();
      return;
    }
    _clients.add(socket);
    unawaited(
      _serve(socket).whenComplete(() {
        _clients.remove(socket);
        socket.destroy();
      }),
    );
  }

  Future<void> _serve(Socket socket) async {
    try {
      final raw = await _readLine(socket).timeout(const Duration(seconds: 2));
      if (raw is! Map ||
          raw.length != 5 ||
          raw['controlVersion'] != 1 ||
          raw['processId'] != pid ||
          raw['token'] != _record['token'] ||
          !{'status', 'quit'}.contains(raw['command']) ||
          raw['operationId'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['operationId'] as String)) {
        return;
      }
      if (raw['command'] == 'quit' &&
          !_quitting &&
          !_operations.contains(raw['operationId'])) {
        // A lost reply never warrants resending this operation. A save failure
        // permits a later explicit CLI call with a new operation identity.
        if (_operations.length >= 64) _operations.remove(_operations.first);
        _operations.add(raw['operationId'] as String);
        _quitting = true;
        _failed = false;
        unawaited(_requestQuit());
      }
      socket.writeln(
        jsonEncode({
          'controlVersion': 1,
          'processId': pid,
          'status': _currentState,
        }),
      );
      await socket.flush().timeout(const Duration(seconds: 1));
    } on Object {
      // Do not log raw socket frames, registry tokens or arbitrary exceptions.
    }
  }

  Future<void> _requestQuit() async {
    try {
      await _quit();
      if (_state() == 'shutdown_failed') throw StateError('shutdown_failed');
    } on Object {
      _failed = true;
      _quitting = false;
    }
  }

  /// Called only after owned library/server/audit shutdown succeeded, just
  /// before native termination. Survives pipe/process teardown; it is NOT a
  /// native exit code and clients still wait on the pinned kernel identity.
  Future<void> commitExit() {
    _record['exitCommitted'] = true;
    return _writeRecord();
  }

  Future<void> _writeRecord() => _writes = _writes.then((_) async {
    final temporary = File('${_directory.path}/.endpoint-${_nonce()}');
    try {
      await temporary.create(exclusive: true);
      await temporary.writeAsString(jsonEncode(_record), flush: true);
      _Native.instance.chmodOwner(temporary.path, 0x180);
      await temporary.rename('${_directory.path}/endpoint.json');
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  });

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
    for (final socket in _clients.toList()) {
      socket.destroy();
    }
    try {
      await _writes;
      final current = await _readRecord(_directory);
      if (current['token'] == _record['token'] &&
          _record['exitCommitted'] != true) {
        await File('${_directory.path}/endpoint.json').delete();
      }
    } finally {
      await _lock.close();
    }
  }
}

/// The Mac CLI only controls the exact sibling application's canonical image,
/// including with --pid. No name-only matching or arbitrary process control.
class MacDesktopControl {
  static Directory? defaultDirectory() {
    final home = Platform.environment['HOME'];
    if (home == null || !home.startsWith('/')) return null;
    const container = '/Library/Containers/com.example.infoDesktop/Data';
    final base = home.endsWith(container) ? home : '$home$container';
    return Directory(
      '$base/Library/Application Support/AgentInfoManage/app-control',
    );
  }

  static Future<Map<String, Object?>> execute({
    required bool quit,
    required String executable,
    int? processId,
    Duration timeout = const Duration(seconds: 15),
    Directory? directory,
  }) async {
    Map<String, Object?> result(String status, [int? target]) => {
      'controlVersion': 1, 'status': status, 'processId': ?target,
      // Darwin cannot obtain a non-child's exit code. Never invent a zero.
      if (status == 'exited') 'exitCode': null,
    };
    if (!Platform.isMacOS) return result('unsupported_platform');
    if (processId != null && (processId < 1 || processId > 0x7fffffff) ||
        timeout < const Duration(milliseconds: 100) ||
        timeout > const Duration(minutes: 1)) {
      return result('invalid_request');
    }
    final clock = Stopwatch()..start();
    try {
      final native = _Native.instance;
      final expected = File(executable).absolute.path;
      // An explicit unrelated live PID is refused even if this bundle is not installed.
      if (processId != null) {
        final requested = native.process(processId);
        if (requested == null) return result('target_unavailable', processId);
        if (requested.executable != expected &&
            requested.executable != await _canonical(expected)) {
          return result('target_mismatch', processId);
        }
      }
      final canonical = await _canonical(expected);
      final registryDirectory = directory ?? defaultDirectory();
      if (registryDirectory == null) return result('control_unavailable');
      Map<String, dynamic>? record;
      try {
        record = await _readRecord(registryDirectory);
      } on FileSystemException catch (error) {
        // Missing is compatible with an old app. Permission/storage failures
        // remain unavailable, rather than being mislabeled as an old version.
        if (error.osError?.errorCode != 2) rethrow;
      }
      if (record != null &&
          record['executable'] == canonical &&
          CredentialProcessIdentity.isActive(
                record['processId'] as int,
                record['createdAt'] as String,
              ) !=
              false) {
        // In particular, a running image whose file was removed cannot be
        // silently reported as stopped just because proc_pidpath now fails.
        final bound = native.process(record['processId'] as int);
        if (bound == null ||
            bound.createdAt != record['createdAt'] ||
            bound.executable != canonical) {
          return result('target_unavailable', record['processId'] as int);
        }
      }
      final matches = processId == null
          ? native.find(canonical)
          : [
              if (native.process(processId) case final p?)
                if (p.executable == canonical) p,
            ];
      if (matches.length > 1 && processId == null) {
        return result('ambiguous_target');
      }
      final target = matches
          .where((p) => processId == null || p.pid == processId)
          .firstOrNull;
      if (target == null) {
        return result(
          processId == null ? 'not_running' : 'target_mismatch',
          processId,
        );
      }
      if (record == null) {
        return result('unsupported_version', target.pid);
      }
      if (record['processId'] != target.pid ||
          record['createdAt'] != target.createdAt ||
          record['executable'] != canonical) {
        return result('target_unavailable', target.pid);
      }
      final operation = _nonce();
      var requested = false;
      while (clock.elapsed < timeout) {
        final active = CredentialProcessIdentity.isActive(
          target.pid,
          target.createdAt,
        );
        if (active == false) {
          final last = await _readRecord(registryDirectory);
          final committed =
              last['token'] == record['token'] && last['exitCommitted'] == true;
          return result(
            requested && committed ? 'exited' : 'unexpected_exit',
            target.pid,
          );
        }
        if (active != true ||
            native.process(target.pid)?.executable != canonical) {
          return result('target_unavailable', target.pid);
        }
        Socket? socket;
        try {
          final budget = timeout - clock.elapsed;
          final wait = budget < const Duration(seconds: 1)
              ? budget
              : const Duration(seconds: 1);
          socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            record['port'] as int,
            timeout: wait,
          );
          _observeSocketCompletion(socket);
          final command = quit && !requested ? 'quit' : 'status';
          // Mark consumed BEFORE writing. A response/flush timeout only polls.
          if (command == 'quit') requested = true;
          socket.writeln(
            jsonEncode({
              'controlVersion': 1,
              'processId': target.pid,
              'token': record['token'],
              'command': command,
              'operationId': operation,
            }),
          );
          final reply = await _readLine(socket).timeout(wait);
          if (reply is! Map ||
              reply.length != 3 ||
              reply['controlVersion'] != 1 ||
              reply['processId'] != target.pid ||
              !_states.contains(reply['status'])) {
            return result('unsupported_version', target.pid);
          }
          if (!quit ||
              reply['status'] == 'shutdown_failed' ||
              reply['status'] == 'startup_failed') {
            // A quit on an error startup is still allowed to close its window.
            if (quit && reply['status'] == 'startup_failed' && requested) {
              // Wait for the already requested normal close, never resubmit.
            } else {
              return result(reply['status'] as String, target.pid);
            }
          }
        } on Object {
          if (!requested) return result('control_unavailable', target.pid);
          // The native app can disappear between its reply and pipe delivery.
          // Only the pinned identity plus commit record can confirm completion.
        } finally {
          socket?.destroy();
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      return result('timeout', target.pid);
    } on Object {
      return result('control_unavailable', processId);
    }
  }
}

void _observeSocketCompletion(Socket socket) {
  // The sink's completion can fail independently of the input stream/flush
  // when normal app termination resets the connection. Observe that future;
  // the caller still requires the pinned process and durable exit commitment.
  unawaited(
    socket.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
}

Future<String> _canonical(String path) async {
  try {
    return await File(path).resolveSymbolicLinks();
  } on FileSystemException {
    // macOS exposes /var through /private/var. Resolve the parent even when
    // the running image has been removed, so its registry identity still
    // matches and an unavailable proc_pidpath cannot masquerade as stopped.
    final file = File(path).absolute;
    try {
      final parent = await file.parent.resolveSymbolicLinks();
      return '$parent${Platform.pathSeparator}${file.uri.pathSegments.last}';
    } on FileSystemException {
      return file.path;
    }
  }
}

Future<Object?> _readLine(Socket socket) async {
  final bytes = <int>[];
  await for (final chunk in socket) {
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] == 10) {
        if (i != chunk.length - 1) throw const FormatException();
        return jsonDecode(utf8.decode(bytes));
      }
      if (bytes.length >= 2048) throw const FormatException();
      bytes.add(chunk[i]);
    }
  }
  throw const FormatException();
}

Future<Map<String, dynamic>> _readRecord(Directory directory) async {
  final file = File('${directory.path}/endpoint.json');
  _Native.instance.checkOwner(directory.path, directory: true);
  _Native.instance.checkOwner(file.path);
  if (await file.length() > 16384) throw const FormatException();
  final raw = jsonDecode(await file.readAsString());
  if (raw is! Map<String, dynamic> ||
      raw.length != 7 ||
      raw['controlVersion'] != 1 ||
      raw['processId'] is! int ||
      (raw['processId'] as int) < 1 ||
      raw['createdAt'] is! String ||
      !RegExp(r'^macos:[0-9]+:[0-9]+$').hasMatch(raw['createdAt'] as String) ||
      raw['executable'] is! String ||
      !(raw['executable'] as String).startsWith('/') ||
      raw['port'] is! int ||
      (raw['port'] as int) < 1 ||
      (raw['port'] as int) > 65535 ||
      raw['token'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['token'] as String) ||
      raw['exitCommitted'] is! bool) {
    throw const FormatException();
  }
  return raw;
}

class _Process {
  const _Process(this.pid, this.createdAt, this.executable);
  final int pid;
  final String createdAt, executable;
}

class _Native {
  static final instance = _Native();
  final _proc = DynamicLibrary.open('/usr/lib/libproc.dylib');
  final _sys = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
  late final _uid = _sys.lookupFunction<Uint32 Function(), int Function()>(
    'geteuid',
  );
  late final _errno = _sys
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );
  late final _info = _proc
      .lookupFunction<
        Int32 Function(Int32, Int32, Uint64, Pointer<Void>, Int32),
        int Function(int, int, int, Pointer<Void>, int)
      >('proc_pidinfo');
  late final _path = _proc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('proc_pidpath');
  late final _list = _proc
      .lookupFunction<
        Int32 Function(Uint32, Uint32, Pointer<Void>, Int32),
        int Function(int, int, Pointer<Void>, int)
      >('proc_listpids');
  late final _stat = _sys
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Uint8>),
        int Function(Pointer<Utf8>, Pointer<Uint8>)
      >('lstat${Abi.current() == Abi.macosX64 ? r'$INODE64' : ''}');
  late final _chmod = _sys
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint16),
        int Function(Pointer<Utf8>, int)
      >('chmod');

  _Process? process(int id, {void Function()? uncertain}) {
    if (id < 1) return null;
    final data = calloc<Uint8>(136), path = calloc<Uint8>(4096);
    try {
      _errno().value = 0;
      if (_info(id, 3, 0, data.cast(), 136) != 136) {
        if (_errno().value != 3) uncertain?.call(); // ESRCH is confirmed ended.
        return null;
      }
      if ((data + 12).cast<Uint32>().value != id ||
          (data + 20).cast<Uint32>().value != _uid() ||
          (data + 4).cast<Uint32>().value == 5) {
        return null;
      }
      final created =
          'macos:${(data + 120).cast<Uint64>().value}:${(data + 128).cast<Uint64>().value}';
      final count = _path(id, path.cast(), 4096);
      if (count <= 0 || count >= 4096) {
        // ENOENT means this image's path no longer resolves (e.g. an unrelated
        // unlinked old build). It cannot match the current linked executable.
        // The registry's bound process is independently checked before this
        // discovery pass; its missing path is never treated as a stopped app.
        if (_errno().value != 3 && _errno().value != 2) uncertain?.call();
        return null;
      }
      final active = CredentialProcessIdentity.isActive(id, created);
      if (active != true) {
        if (active == null) uncertain?.call();
        return null;
      }
      return _Process(id, created, path.cast<Utf8>().toDartString());
    } finally {
      calloc.free(data);
      calloc.free(path);
    }
  }

  List<_Process> find(String executable) {
    const bytes = 262144;
    final ids = calloc<Int32>(bytes ~/ 4);
    try {
      final count = _list(4, _uid(), ids.cast(), bytes); // PROC_UID_ONLY
      if (count <= 0 || count >= bytes) throw StateError('control_unavailable');
      var inconclusive = false;
      final matches = <_Process>[];
      for (var i = 0; i < count ~/ 4; i++) {
        final current = process(
          ids[i],
          uncertain: () {
            inconclusive = true;
          },
        );
        if (current?.executable == executable) matches.add(current!);
      }
      // A failed observation is not proof that no matching app exists, nor
      // proof that a single observed target is the only matching instance.
      if (inconclusive) throw StateError('control_unavailable');
      return matches;
    } finally {
      calloc.free(ids);
    }
  }

  void chmodOwner(String path, int mode) {
    final text = path.toNativeUtf8();
    try {
      if (_chmod(text, mode) != 0) throw StateError('control_unavailable');
    } finally {
      calloc.free(text);
    }
  }

  void checkOwner(String path, {bool directory = false}) {
    final text = path.toNativeUtf8(), data = calloc<Uint8>(144);
    try {
      if (_stat(text, data) != 0) {
        throw FileSystemException(
          'Control entry unavailable',
          '',
          OSError('', _errno().value),
        );
      }
      final mode = (data + 4).cast<Uint16>().value;
      if ((data + 16).cast<Uint32>().value != _uid() ||
          mode & 0x3f != 0 ||
          mode & 0xf000 != (directory ? 0x4000 : 0x8000) ||
          !directory && (data + 6).cast<Uint16>().value != 1) {
        throw StateError('control_unavailable');
      }
    } finally {
      calloc.free(text);
      calloc.free(data);
    }
  }
}
