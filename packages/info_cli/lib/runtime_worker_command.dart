import 'dart:io';
import 'dart:isolate';
import 'package:info_core/info_core.dart';

/// Resolve the same internal worker for SDK runs and standalone delivery.
/// A .dart worker is always invoked by the current VM, never as a shell script.
final class RuntimeWorkerCommand {
  RuntimeWorkerCommand._(this.executable, this.arguments, this.worker);
  final String executable, worker;
  final List<String> arguments;
  static Future<RuntimeWorkerCommand> resolve({
    String? workerExecutable,
  }) async {
    final runtime = Platform.resolvedExecutable;
    final vm = Platform.isWindows
        ? runtime.toLowerCase().endsWith('dart.exe') ||
              runtime.toLowerCase().endsWith('dartvm.exe')
        : RegExp(r'/(dart|dartvm)$').hasMatch(runtime);
    final interpreted =
        vm && (workerExecutable == null || workerExecutable.endsWith('.dart'));
    final worker =
        workerExecutable ??
        (interpreted
            ? (await Isolate.resolvePackageUri(
                Uri.parse('package:info_cli/runtime_worker.dart'),
              ))!.toFilePath()
            : '${File(runtime).parent.path}/info-runtime-worker${Platform.isWindows ? '.exe' : ''}');
    final program = interpreted
        ? (Platform.isWindows
              ? '${File(runtime).parent.path}/dartvm.exe'
              : runtime)
        : worker;
    if (!await File(worker).exists() || !await File(program).exists()) {
      throw const CredentialUseFailure('service_unavailable');
    }
    return RuntimeWorkerCommand._(program, [
      if (interpreted) ...[
        '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
        worker,
      ],
    ], worker);
  }
}
