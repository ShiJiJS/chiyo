import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A key-only loopback SSH container. Its account, home and both SSH keys are
/// synthetic; no local account shell, SSH configuration or personal key is used.
final class DeviceSshFixture {
  DeviceSshFixture(this.root, this.name, this.port);
  final Directory root;
  final String name;
  final int port;
  static const docker = '/usr/local/bin/docker';
  static Future<DeviceSshFixture> start() async {
    final created = await Directory.systemTemp.createTemp(
      'device-ssh-fixture-',
    );
    final root = Directory(await created.resolveSymbolicLinks());
    final name = 'chiyo-a09-ssh-$pid-${Random.secure().nextInt(1 << 30)}';
    final launched = await Process.run(docker, [
      'run',
      '--detach',
      '--rm',
      '--name',
      name,
      '--publish',
      '127.0.0.1::2222',
      '--mount',
      'type=bind,src=${root.path},dst=/output',
      'chiyo-synthetic-ssh:a09',
    ]);
    if (launched.exitCode != 0) {
      await root.delete(recursive: true);
      throw StateError(
        'Build scripts/qa/ssh-fixture as chiyo-synthetic-ssh:a09 before native SSH tests',
      );
    }
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!await File('${root.path}/ready').exists()) {
        final state = await Process.run(docker, [
          'inspect',
          '--format',
          '{{.State.Running}}',
          name,
        ]);
        if (state.exitCode != 0 ||
            '${state.stdout}'.trim() != 'true' ||
            DateTime.now().isAfter(deadline)) {
          throw StateError('Synthetic SSH fixture did not start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final published = await Process.run(docker, ['port', name, '2222/tcp']);
      final port = int.parse('${published.stdout}'.trim().split(':').last);
      while (true) {
        try {
          (await Socket.connect(
            '127.0.0.1',
            port,
            timeout: const Duration(milliseconds: 200),
          )).destroy();
          break;
        } on SocketException {
          if (DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
      return DeviceSshFixture(root, name, port);
    } on Object {
      await Process.run(docker, ['rm', '--force', name]);
      await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<List<int>> get key => File('${root.path}/client').readAsBytes();
  Future<List<int>> get trust async {
    final public = (await File(
      '${root.path}/host.pub',
    ).readAsString()).split(' ').take(2).join(' ');
    return utf8.encode('[127.0.0.1]:$port $public\n');
  }

  List<Object?> argv({bool slow = false}) => [
    '-T',
    '-o',
    'BatchMode=yes',
    '-i',
    {'file': 'identity'},
    '-p',
    '$port',
    'fixture@127.0.0.1',
    if (slow) ...[
      '/bin/sleep',
      '1',
    ] else ...[
      '/usr/bin/printf',
      'SYNTHETIC_SSH_OK',
    ],
  ];
  Future<void> close() async {
    final removed = await Process.run(docker, ['rm', '--force', name]);
    if (removed.exitCode != 0)
      throw StateError('Synthetic SSH fixture cleanup failed');
    await root.delete(recursive: true);
  }
}
