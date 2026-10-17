import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Holds a Windows process handle so PID reuse cannot change this identity while
/// the executor drains pipes and reports the final result. No capability or
/// credential is stored here.
class CredentialProcessIdentity {
  CredentialProcessIdentity._(this.value, this._handle);
  final String value;
  int? _handle;
  static CredentialProcessIdentity? capture(int processId) {
    if (Platform.isWindows) {
      final handle = _openProcess(0x1000, 0, processId);
      if (handle == 0) return null;
      final times = calloc<Uint64>(4);
      try {
        if (_getProcessTimes(handle, times, times + 1, times + 2, times + 3) ==
            0) {
          _closeHandle(handle);
          return null;
        }
        return CredentialProcessIdentity._('windows:${times.value}', handle);
      } finally {
        calloc.free(times);
      }
    }
    if (Platform.isLinux) {
      try {
        final stat = File('/proc/$processId/stat').readAsStringSync();
        final fields = stat
            .substring(stat.lastIndexOf(')') + 2)
            .trim()
            .split(RegExp(r'\s+'));
        final boot = File(
          '/proc/sys/kernel/random/boot_id',
        ).readAsStringSync().trim();
        return CredentialProcessIdentity._('linux:$boot:${fields[19]}', null);
      } on Object {
        return null;
      }
    }
    return null;
  }

  void close() {
    final handle = _handle;
    _handle = null;
    if (handle != null) _closeHandle(handle);
  }

  @override
  String toString() => 'CredentialProcessIdentity($value)';
}

final _kernel = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;
final _openProcess =
    _kernel?.lookupFunction<
      IntPtr Function(Uint32, Int32, Uint32),
      int Function(int, int, int)
    >('OpenProcess') ??
    _unavailableOpen;
int _unavailableOpen(int _, int _, int _) => 0;
final _getProcessTimes =
    _kernel?.lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
      ),
      int Function(
        int,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
        Pointer<Uint64>,
      )
    >('GetProcessTimes') ??
    _unavailableTimes;
int _unavailableTimes(
  int _,
  Pointer<Uint64> _,
  Pointer<Uint64> _,
  Pointer<Uint64> _,
  Pointer<Uint64> _,
) => 0;
final _closeHandle =
    _kernel?.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'CloseHandle',
    ) ??
    _unavailableClose;
int _unavailableClose(int _) => 0;

/// A worker joins this job before creating the approved program. Windows then
/// associates its descendants with the same job, including detached children.
/// No breakaway or kill-on-close flags are enabled: revocation/CLI death must
/// not silently terminate an already started command.
class CredentialProcessJob {
  CredentialProcessJob._(this.name, this._handle);
  final String name;
  int? _handle;
  static CredentialProcessJob observe(String name, int processId) {
    final nativeName = name.toNativeUtf16();
    int jobHandle = 0, processHandle = 0;
    final membership = calloc<Int32>();
    try {
      jobHandle = _openJob(4, 0, nativeName);
      processHandle = _openProcess(0x1000, 0, processId);
      if (jobHandle == 0 ||
          processHandle == 0 ||
          _isInJob(processHandle, jobHandle, membership) == 0 ||
          membership.value == 0) {
        throw StateError('job_identity_mismatch');
      }
      return CredentialProcessJob._(name, jobHandle);
    } on Object {
      if (jobHandle != 0) _closeHandle(jobHandle);
      rethrow;
    } finally {
      if (processHandle != 0) _closeHandle(processHandle);
      calloc.free(membership);
      calloc.free(nativeName);
    }
  }

  static CredentialProcessJob createForCurrentWorker(String name) {
    if (!Platform.isWindows) throw UnsupportedError('Windows job required');
    final nativeName = name.toNativeUtf16();
    try {
      final handle = _createJob(nullptr, nativeName);
      if (handle == 0) throw StateError('job_create_failed');
      if (_lastError() == 183 || _assignJob(handle, -1) == 0) {
        _closeHandle(handle);
        throw StateError('job_assignment_failed');
      }
      return CredentialProcessJob._(name, handle);
    } finally {
      calloc.free(nativeName);
    }
  }

  int get activeProcesses {
    final handle = _handle;
    if (handle == null) throw StateError('job_closed');
    final accounting = calloc<Uint8>(48);
    try {
      if (_queryJob(handle, 1, accounting.cast(), 48, nullptr) == 0) {
        throw StateError('job_query_failed');
      }
      return (accounting + 40).cast<Uint32>().value;
    } finally {
      calloc.free(accounting);
    }
  }

  Future<void> waitForDescendants() async {
    // The worker itself remains in the job until this method returns.
    while (activeProcesses > 1) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<void> waitUntilEmpty() async {
    while (activeProcesses != 0) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  void close() {
    final handle = _handle;
    _handle = null;
    if (handle != null) _closeHandle(handle);
  }
}

final _createJob =
    _kernel?.lookupFunction<
      IntPtr Function(Pointer<Void>, Pointer<Utf16>),
      int Function(Pointer<Void>, Pointer<Utf16>)
    >('CreateJobObjectW') ??
    _noCreateJob;
int _noCreateJob(Pointer<Void> _, Pointer<Utf16> _) => 0;
final _assignJob =
    _kernel?.lookupFunction<
      Int32 Function(IntPtr, IntPtr),
      int Function(int, int)
    >('AssignProcessToJobObject') ??
    _noAssignJob;
int _noAssignJob(int _, int _) => 0;
final _lastError =
    _kernel?.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    ) ??
    _noLastError;
int _noLastError() => 0;
final _queryJob =
    _kernel?.lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
      int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
    >('QueryInformationJobObject') ??
    _noQueryJob;
int _noQueryJob(int _, int _, Pointer<Void> _, int _, Pointer<Uint32> _) => 0;
final _openJob =
    _kernel?.lookupFunction<
      IntPtr Function(Uint32, Int32, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>)
    >('OpenJobObjectW') ??
    _noOpenJob;
int _noOpenJob(int _, int _, Pointer<Utf16> _) => 0;
final _isInJob =
    _kernel?.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Pointer<Int32>),
      int Function(int, int, Pointer<Int32>)
    >('IsProcessInJob') ??
    _noIsInJob;
int _noIsInJob(int _, int _, Pointer<Int32> _) => 0;
