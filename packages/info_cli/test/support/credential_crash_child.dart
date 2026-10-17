import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  // Only terminate the worker that just created this synthetic test process.
  if (Platform.environment['GH_TOKEN'] != 'synthetic-token') exit(71);
  final path = '${Platform.environment['TEMP']}/worker-state.json';
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  Future<void> waitFor(String name) async {
    while (!await File(name).exists()) {
      if (DateTime.now().isAfter(deadline)) exit(70);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  await File('target-ready').writeAsString('ready');
  await waitFor('kill-worker');
  final state = jsonDecode(await File(path).readAsString()) as Map;
  // dart.exe may use a dartvm.exe child: the recorded target PID is its OS
  // launcher, while pid here is the VM. The private synthetic TEMP state names
  // the worker that created both; never accept this process as the victim.
  if (state['pid'] is! int ||
      state['state'] != 'started' ||
      state['workerPid'] is! int ||
      state['workerPid'] == pid) {
    exit(72);
  }
  if (!Process.killPid(state['workerPid'] as int)) exit(73);
  await File('worker-killed').writeAsString('killed');
  await waitFor('release');
  exit(7);
}
