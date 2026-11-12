import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Internal Darwin worker primitive. The executable is loaded suspended so the
/// supervisor can verify its real kernel identity before a short target exits.
/// stdout/stderr inherit only the worker's bounded-output pipes. Optional stdin
/// uses a separate anonymous pipe, never the worker's control descriptor.
/// The caller is already in the approved working directory and process group.
class MacOsRuntimeTarget {
  MacOsRuntimeTarget._(this.pid, this._queue, this._stdinFd);
  int? _stdinFd;
  final int pid;
  final int _queue;
  bool _resumed = false;
  Future<int>? _result;
  static final _lib = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
  static final _attrInit = _lib
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>),
        int Function(Pointer<Pointer<Void>>)
      >('posix_spawnattr_init');
  static final _attrDestroy = _lib
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>),
        int Function(Pointer<Pointer<Void>>)
      >('posix_spawnattr_destroy');
  static final _flags = _lib
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>, Int16),
        int Function(Pointer<Pointer<Void>>, int)
      >('posix_spawnattr_setflags');
  static final _actionsInit = _lib
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>),
        int Function(Pointer<Pointer<Void>>)
      >('posix_spawn_file_actions_init');
  static final _actionsDestroy = _lib
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>),
        int Function(Pointer<Pointer<Void>>)
      >('posix_spawn_file_actions_destroy');
  static final _dup = _lib
      .lookupFunction<
        Int32 Function(Pointer<Pointer<Void>>, Int32, Int32),
        int Function(Pointer<Pointer<Void>>, int, int)
      >('posix_spawn_file_actions_adddup2');
  static final _open = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Pointer<Void>>,
          Int32,
          Pointer<Utf8>,
          Int32,
          Uint16,
        ),
        int Function(Pointer<Pointer<Void>>, int, Pointer<Utf8>, int, int)
      >('posix_spawn_file_actions_addopen');
  static final _spawn = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Int32>,
          Pointer<Utf8>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Utf8>>,
          Pointer<Pointer<Utf8>>,
        ),
        int Function(
          Pointer<Int32>,
          Pointer<Utf8>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Utf8>>,
          Pointer<Pointer<Utf8>>,
        )
      >('posix_spawn');
  static final _kill = _lib
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'kill',
      );
  static final _wait = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Int32>, Int32),
        int Function(int, Pointer<Int32>, int)
      >('waitpid');
  static final _errno = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );
  static final _kqueue = _lib.lookupFunction<Int32 Function(), int Function()>(
    'kqueue',
  );
  static final _close = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _pipe = _lib
      .lookupFunction<
        Int32 Function(Pointer<Int32>),
        int Function(Pointer<Int32>)
      >('pipe');
  static final _fcntl = _lib
      .lookupFunction<
        Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
        int Function(int, int, int)
      >('fcntl');
  static final _write = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  static final _events = _lib
      .lookupFunction<
        Int32 Function(
          Int32,
          Pointer<_DarwinProcessEvent>,
          Int32,
          Pointer<_DarwinProcessEvent>,
          Int32,
          Uint32,
          Pointer<Int64>,
        ),
        int Function(
          int,
          Pointer<_DarwinProcessEvent>,
          int,
          Pointer<_DarwinProcessEvent>,
          int,
          int,
          Pointer<Int64>,
        )
      >('kevent64');

  static MacOsRuntimeTarget spawn(
    String executable,
    List<String> argv,
    Map<String, String> environment, {
    bool pipeStdin = false,
  }) {
    if (!Platform.isMacOS) throw UnsupportedError('Darwin target required');
    if (!executable.startsWith('/') ||
        [
          executable,
          ...argv,
          ...environment.keys,
          ...environment.values,
        ].any((v) => v.contains('\x00')) ||
        environment.keys.any((v) => v.isEmpty || v.contains('='))) {
      throw const FormatException('Invalid native launch');
    }
    final attrs = calloc<Pointer<Void>>(), actions = calloc<Pointer<Void>>();
    final process = calloc<Int32>();
    final arguments = _NativeStrings([executable, ...argv]);
    final env = _NativeStrings(
      environment.entries.map((e) => '${e.key}=${e.value}').toList(),
    );
    final devNull = '/dev/null'.toNativeUtf8();
    var attrsReady = false, actionsReady = false;
    int? inputRead, inputWrite;
    try {
      if (_attrInit(attrs) != 0) throw StateError('spawn_init_failed');
      attrsReady = true;
      if (_actionsInit(actions) != 0) throw StateError('spawn_init_failed');
      actionsReady = true;
      if (pipeStdin) {
        final pair = calloc<Int32>(2);
        try {
          if (_pipe(pair) != 0) throw StateError('stdin_pipe_failed');
          inputRead = pair[0];
          inputWrite = pair[1];
          // Nonblocking writes keep the Dart worker responsive while a target
          // consumes large input. F_SETNOSIGPIPE turns early close into EPIPE.
          if (_fcntl(inputWrite, 4, 4) != 0 || _fcntl(inputWrite, 73, 1) != 0) {
            throw StateError('stdin_pipe_failed');
          }
        } finally {
          calloc.free(pair);
        }
      }
      // POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT.
      if (_flags(attrs, 0x4080) != 0 ||
          (inputRead == null
                  ? _open(actions, 0, devNull, 0, 0)
                  : _dup(actions, inputRead, 0)) !=
              0 ||
          _dup(actions, 1, 1) != 0 ||
          _dup(actions, 2, 2) != 0 ||
          _spawn(
                process,
                arguments.pointer[0],
                actions,
                attrs,
                arguments.pointer,
                env.pointer,
              ) !=
              0 ||
          process.value < 1) {
        throw StateError('process_start_failed');
      }
      final queue = _kqueue();
      final change = calloc<_DarwinProcessEvent>();
      try {
        change.ref
          ..ident = process.value
          ..filter =
              -5 // EVFILT_PROC
          ..flags =
              0x15 // EV_ADD | EV_ENABLE | EV_ONESHOT
          ..notes = 0x84000000; // NOTE_EXIT | NOTE_EXITSTATUS
        if (queue < 0 ||
            _events(queue, change, 1, nullptr, 0, 0, nullptr) < 0) {
          // No target instructions ran; fail closed if lifetime observation
          // could not be registered while the executable was suspended.
          _kill(process.value, 9);
          if (queue >= 0) _close(queue);
          throw StateError('process_start_failed');
        }
        final target = MacOsRuntimeTarget._(process.value, queue, inputWrite);
        inputWrite = null;
        return target;
      } finally {
        calloc.free(change);
      }
    } finally {
      if (inputRead != null) _close(inputRead);
      if (inputWrite != null) _close(inputWrite);
      if (actionsReady) _actionsDestroy(actions);
      if (attrsReady) _attrDestroy(attrs);
      calloc.free(attrs);
      calloc.free(actions);
      calloc.free(process);
      calloc.free(devNull);
      arguments.close();
      env.close();
    }
  }

  void closeStdin() {
    final fd = _stdinFd;
    _stdinFd = null;
    if (fd != null) _close(fd);
  }

  Future<void> sendStdin(List<int> bytes) async {
    final fd = _stdinFd;
    if (fd == null) return;
    final buffer = calloc<Uint8>(4096);
    var offset = 0;
    try {
      while (offset < bytes.length && _stdinFd == fd) {
        final length = (bytes.length - offset).clamp(0, 4096);
        buffer.asTypedList(length).setRange(0, length, bytes, offset);
        final written = _write(fd, buffer, length);
        if (written > 0) {
          offset += written;
        } else if (written < 0 && _errno().value == 32) {
          return; // Target intentionally closed stdin (EPIPE).
        } else if (written < 0 && {4, 35}.contains(_errno().value)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        } else {
          throw StateError('stdin_delivery_failed');
        }
      }
    } finally {
      buffer.asTypedList(4096).fillRange(0, 4096, 0);
      calloc.free(buffer);
      closeStdin();
    }
  }

  void resume() {
    if (_resumed) return;
    // Dart's ProcessSignal numbers are normalized; Darwin libc SIGCONT is 19.
    if (_kill(pid, 19) != 0) {
      throw StateError('process_start_failed');
    }
    _resumed = true;
  }

  Future<int> get exitCode => _result ??= _waitForExit();
  Future<int> _waitForExit() async {
    final event = calloc<_DarwinProcessEvent>();
    final timeout = calloc<Int64>(2);
    final status = calloc<Int32>();
    try {
      while (true) {
        // A Dart VM can also reap SIGCHLD. NOTE_EXITSTATUS preserves the kernel
        // result after that reap; ECHILD alone never invents an exit code.
        final result = _events(_queue, nullptr, 0, event, 1, 0, timeout);
        if (result > 0) {
          if (event.ref.ident != pid ||
              event.ref.flags & 0x4000 != 0 ||
              event.ref.notes & 0x80000000 == 0) {
            throw StateError('execution_unknown');
          }
          _wait(pid, status, 1); // Reap if the VM has not already done so.
          final signal = event.ref.data & 0x7f;
          if (signal == 0) return (event.ref.data >> 8) & 0xff;
          if (signal != 0x7f) return -signal;
        } else if (result < 0 && _errno().value != 4) {
          throw StateError('execution_unknown');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      _close(_queue);
      calloc.free(event);
      calloc.free(timeout);
      calloc.free(status);
    }
  }
}

final class _DarwinProcessEvent extends Struct {
  @Uint64()
  external int ident;
  @Int16()
  external int filter;
  @Uint16()
  external int flags;
  @Uint32()
  external int notes;
  @Int64()
  external int data;
  @Uint64()
  external int userData;
  @Array(2)
  external Array<Uint64> extensions;
}

class _NativeStrings {
  _NativeStrings(List<String> values)
    : pointer = calloc<Pointer<Utf8>>(values.length + 1) {
    for (var i = 0; i < values.length; i++) {
      pointer[i] = values[i].toNativeUtf8();
      _lengths.add(utf8.encode(values[i]).length + 1);
    }
  }
  final Pointer<Pointer<Utf8>> pointer;
  final _lengths = <int>[];
  void close() {
    for (var i = 0; i < _lengths.length; i++) {
      pointer[i]
          .cast<Uint8>()
          .asTypedList(_lengths[i])
          .fillRange(0, _lengths[i], 0);
      calloc.free(pointer[i]);
    }
    calloc.free(pointer);
  }
}
