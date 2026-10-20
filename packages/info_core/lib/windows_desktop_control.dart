import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Narrow current-desktop control, independent of information grants and HTTP.
/// A pinned process handle confirms exit; no termination API is used. The peer
/// also checks its PID in the message, so reused HWNDs cannot redirect a quit.
class WindowsDesktopControl {
  static Future<Map<String, Object?>> execute({
    required bool quit,
    required String executable,
    int? processId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    Map<String, Object?> result(String state, [int? target]) => {
      'controlVersion': 1,
      'status': state,
      'processId': ?target,
    };
    if (!Platform.isWindows) return result('unsupported_platform');
    if (processId != null && (processId < 1 || processId > 0xffffffff) ||
        timeout < const Duration(milliseconds: 100) ||
        timeout > const Duration(minutes: 1)) {
      return result('invalid_request');
    }
    final clock = Stopwatch()..start();
    final native = _ControlNative();
    final targets = <_Target>[];
    try {
      final expected = _path(executable);
      var window = 0;
      for (var count = 0; count < 4096; count++) {
        window = native.next(window);
        if (window == 0) break;
        final id = native.process(window);
        if (processId != null && id != processId) continue;
        final handle = native.open(id);
        if (handle == 0) continue;
        final image = native.image(handle);
        final matches = processId == null
            ? image != null && _path(image) == expected
            : image != null && _path(image).endsWith(r'\info_desktop.exe');
        if (!matches) {
          native.close(handle);
          continue;
        }
        targets.add(_Target(window, id, handle));
      }
      if (targets.isEmpty) {
        // Explicit PID that exists but is not a matching app is never an
        // idempotent success. Do not probe, close or kill unrelated windows.
        if (processId != null) {
          final handle = native.open(processId);
          if (handle != 0) {
            try {
              return result(
                native.ended(handle) ? 'not_running' : 'target_mismatch',
                processId,
              );
            } finally {
              native.close(handle);
            }
          }
          return result('target_unavailable', processId);
        }
        return result('not_running');
      }
      if (targets.length != 1) return result('ambiguous_target');
      final target = targets.single;
      var requested = false;
      while (clock.elapsed < timeout) {
        if (native.ended(target.handle)) {
          return result(
            native.exitCode(target.handle) == 0 ? 'exited' : 'unexpected_exit',
            target.pid,
          );
        }
        if (native.process(target.window) != target.pid) {
          if (requested) {
            // Window destruction precedes process exit. Keep waiting on the
            // pinned handle; never send to a replacement window.
            await Future<void>.delayed(const Duration(milliseconds: 40));
            continue;
          }
          return result('target_unavailable', target.pid);
        }
        final state = native.send(
          target,
          quit && !requested,
          (timeout - clock.elapsed).inMilliseconds.clamp(1, 250),
        );
        if (state == 0 && requested) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          continue;
        }
        if (state == 0 || state == 5) {
          return result('unsupported_version', target.pid);
        }
        if (!quit && state != null) {
          return result(switch (state) {
            1 => 'running',
            2 => 'exiting',
            3 => 'shutdown_failed',
            4 => 'starting',
            _ => 'unsupported_version',
          }, target.pid);
        }
        // Only the response to our quit (or an already running quit) consumes
        // the request. A failed save is explicit; a retry is a new CLI call.
        if (state == 2) requested = true;
        if (state == 3) return result('shutdown_failed', target.pid);
        if (state != null && state != 1 && state != 2 && state != 4) {
          return result('unsupported_version', target.pid);
        }
        // A lost response is ambiguous: query rather than resending a quit.
        if (state == null) requested = true;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      return result('timeout', target.pid);
    } on Object {
      return result('control_unavailable', processId);
    } finally {
      for (final target in targets) {
        native.close(target.handle);
      }
    }
  }

  static String _path(String path) => File(
    path,
  ).absolute.path.replaceAll('/', r'\').replaceFirst(r'\\?\', '').toLowerCase();
}

class _Target {
  const _Target(this.window, this.pid, this.handle);
  final int window, pid, handle;
}

class _ControlNative {
  final _user = DynamicLibrary.open('user32.dll');
  final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _find = _user
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
  late final _pid = _user
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  late final _open = _kernel
      .lookupFunction<
        IntPtr Function(Uint32, Int32, Uint32),
        int Function(int, int, int)
      >('OpenProcess');
  late final _image = _kernel
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>),
        int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)
      >('QueryFullProcessImageNameW');
  late final _wait = _kernel
      .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
        'WaitForSingleObject',
      );
  late final close = _kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  late final _exit = _kernel
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetExitCodeProcess');
  late final _register = _user
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('RegisterWindowMessageW');
  late final _send = _user
      .lookupFunction<
        IntPtr Function(
          IntPtr,
          Uint32,
          UintPtr,
          IntPtr,
          Uint32,
          Uint32,
          Pointer<UintPtr>,
        ),
        int Function(int, int, int, int, int, int, Pointer<UintPtr>)
      >('SendMessageTimeoutW');
  late final int message = _message();

  int _message() {
    final text = 'AgentInfoManage.LocalControl.v1'.toNativeUtf16();
    try {
      final id = _register(text);
      if (id == 0) throw StateError('control_unavailable');
      return id;
    } finally {
      calloc.free(text);
    }
  }

  int next(int previous) {
    final type = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      return _find(0, previous, type, nullptr);
    } finally {
      calloc.free(type);
    }
  }

  int process(int window) {
    final id = calloc<Uint32>();
    try {
      return _pid(window, id) == 0 ? 0 : id.value;
    } finally {
      calloc.free(id);
    }
  }

  int open(int id) => _open(0x1000 | 0x100000, 0, id);
  bool ended(int handle) => _wait(handle, 0) == 0;
  int? exitCode(int handle) {
    final code = calloc<Uint32>();
    try {
      return _exit(handle, code) == 0 ? null : code.value;
    } finally {
      calloc.free(code);
    }
  }

  String? image(int handle) {
    final text = calloc<Uint16>(32768).cast<Utf16>();
    final length = calloc<Uint32>()..value = 32768;
    try {
      return _image(handle, 0, text, length) == 0
          ? null
          : text.toDartString(length: length.value);
    } finally {
      calloc.free(text);
      calloc.free(length);
    }
  }

  int? send(_Target target, bool quit, int timeoutMs) {
    final state = calloc<UintPtr>();
    try {
      return _send(
                target.window,
                message,
                target.pid,
                quit ? 1 : 0,
                0x1 | 0x2 | 0x20,
                timeoutMs,
                state,
              ) ==
              0
          ? null
          : state.value;
    } finally {
      calloc.free(state);
    }
  }
}
