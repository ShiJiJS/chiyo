part of 'runtime_process_identity.dart';

/// Uses the kernel's process start timeval, never a formatted ps timestamp or
/// PID alone. Failed/forbidden observations remain inconclusive. The supported
/// arm64/x86_64 SDKs use a 136-byte proc_bsdinfo with timeval at offset 120.
class _MacOsProcessIdentity {
  const _MacOsProcessIdentity(this.identity, this.status, this.group);
  final String identity;
  final int status, group;
  static final _lib = DynamicLibrary.open('/usr/lib/libproc.dylib');
  static final _system = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
  static final _info = _lib
      .lookupFunction<
        Int32 Function(Int32, Int32, Uint64, Pointer<Void>, Int32),
        int Function(int, int, int, Pointer<Void>, int)
      >('proc_pidinfo');
  static final _errno = _system
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );

  static _MacOsProcessIdentity? read(int processId) {
    if (processId < 1 || processId > 0x7fffffff) return null;
    final buffer = calloc<Uint8>(136);
    try {
      _errno().value = 0;
      if (_info(processId, 3, 0, buffer.cast(), 136) != 136 ||
          (buffer + 12).cast<Uint32>().value != processId) {
        return null;
      }
      final seconds = (buffer + 120).cast<Uint64>().value;
      final micros = (buffer + 128).cast<Uint64>().value;
      if (seconds <= 0 || micros >= 1000000) return null;
      return _MacOsProcessIdentity(
        'macos:$seconds:$micros',
        (buffer + 4).cast<Uint32>().value,
        (buffer + 100).cast<Uint32>().value,
      );
    } finally {
      calloc.free(buffer);
    }
  }

  static bool? isActive(int processId, String expected) {
    if (processId < 1 ||
        processId > 0x7fffffff ||
        !RegExp(r'^macos:[0-9]+:[0-9]+$').hasMatch(expected)) {
      return null;
    }
    final current = read(processId);
    if (current == null) return _errno().value == 3 ? false : null;
    return current.identity == expected && current.status != 5;
  }
}

/// A Darwin worker starts a separate session/process group before the launch
/// gate. Its identity is recorded separately from the numeric group ID; a
/// reused leader or forbidden observation is never treated as an empty group.
/// This is POSIX process-group observation, not a Windows kernel Job or a
/// security sandbox for arbitrary programs which deliberately escape groups.
class _MacOsProcessGroup {
  _MacOsProcessGroup(this.workerPid, this.workerCreatedAt);
  final int workerPid;
  final String workerCreatedAt;
  static final _list = _MacOsProcessIdentity._lib
      .lookupFunction<
        Int32 Function(Uint32, Uint32, Pointer<Void>, Int32),
        int Function(int, int, Pointer<Void>, int)
      >('proc_listpids');
  static final _session = _MacOsProcessIdentity._system
      .lookupFunction<Int32 Function(), int Function()>('setsid');
  static final _kill = _MacOsProcessIdentity._system
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'kill',
      );

  static _MacOsProcessGroup create() {
    if (_session() < 0) throw StateError('job_assignment_failed');
    final info = _MacOsProcessIdentity.read(pid);
    if (info == null || info.group != pid) {
      throw StateError('job_assignment_failed');
    }
    return _MacOsProcessGroup(pid, info.identity);
  }

  int get activeProcesses {
    if (workerPid < 1 ||
        !RegExp(r'^macos:[0-9]+:[0-9]+$').hasMatch(workerCreatedAt)) {
      throw StateError('job_identity_mismatch');
    }
    final worker = _MacOsProcessIdentity.read(workerPid);
    if (worker != null &&
        (worker.identity != workerCreatedAt || worker.group != workerPid)) {
      throw StateError('job_identity_mismatch');
    }
    if (worker == null && _MacOsProcessIdentity._errno().value != 3) {
      throw StateError('job_query_failed');
    }
    var capacity = _list(2, workerPid, nullptr, 0) + 1024;
    if (capacity < 1024 || capacity > 4 * 1024 * 1024) {
      throw StateError('job_query_failed');
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      final buffer = calloc<Uint8>(capacity);
      try {
        final used = _list(2, workerPid, buffer.cast(), capacity);
        if (used < 0 || used % 4 != 0) throw StateError('job_query_failed');
        if (used >= capacity) {
          capacity *= 2;
          continue;
        }
        var count = 0;
        for (var i = 0; i < used ~/ 4; i++) {
          final id = buffer.cast<Int32>()[i];
          if (id <= 0) continue;
          final info = _MacOsProcessIdentity.read(id);
          if (info == null) {
            if (_MacOsProcessIdentity._errno().value != 3) {
              throw StateError('job_query_failed');
            }
          } else if (info.group == workerPid && info.status != 5) {
            count++;
          }
        }
        if (count > 0) return count;
        // A separate kernel group query closes the list/read disappearance
        // race: signal zero observes existence without delivering a signal.
        _MacOsProcessIdentity._errno().value = 0;
        if (_kill(-workerPid, 0) == 0) return 1;
        if (_MacOsProcessIdentity._errno().value == 3) return 0;
        throw StateError('job_query_failed');
      } finally {
        calloc.free(buffer);
      }
    }
    throw StateError('job_query_failed');
  }
}
