import 'dart:io';
import 'package:info_cli/codex_bundle.dart';

/// Creates a reviewable bundle only. Does not install or trust any hooks.
Future<void> main(List<String> args) async {
  if (args.length != 1 || (!Platform.isWindows && !Platform.isMacOS)) {
    stderr.writeln(
      'Usage: dart run tool/prepare_codex.dart <new-bundle-directory>',
    );
    exitCode = 64;
    return;
  }
  final output = Directory(args.single).absolute;
  if (await output.exists()) {
    stderr.writeln('Destination exists; choose a new bundle directory.');
    exitCode = 64;
    return;
  }
  final package = File.fromUri(Platform.script).parent.parent;
  final repository = package.parent.parent;
  await output.create(recursive: true);
  final suffix = Platform.isWindows ? '.exe' : '';
  for (final entry in {
    'chiyo': 'chiyo',
    'codex_hook': 'info-codex-hook',
    'codex_info': 'info-codex',
    'runtime_worker': 'info-runtime-worker',
  }.entries) {
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '${package.path}/bin/${entry.key}.dart',
      '-o',
      '${output.path}/${entry.value}$suffix',
    ], workingDirectory: package.path);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      exitCode = result.exitCode;
      return;
    }
  }
  // The resident worker resolves its platform SSH transport beside itself.
  // A source-built stable bundle needs the same dependency as a delivered one.
  final ssh = await Process.run(
    Platform.isWindows ? 'powershell.exe' : '/bin/bash',
    Platform.isWindows
        ? [
            '-NoProfile',
            '-NonInteractive',
            '-File',
            '${repository.path}/scripts/package-windows-ssh-session.ps1',
            '-DestinationDirectory',
            output.path,
          ]
        : [
            '${repository.path}/scripts/build-macos-ssh-session.sh',
            '${output.path}/info-ssh-session',
          ],
    workingDirectory: repository.path,
  );
  if (ssh.exitCode != 0) {
    stderr.write(ssh.stderr);
    exitCode = ssh.exitCode;
    return;
  }
  final source = await File(
    '${repository.path}/integrations/codex/skills/agent-info-access/SKILL.md',
  ).readAsString();
  final references = await readCodexReferences(
    Directory(
      '${repository.path}/integrations/codex/skills/agent-info-access/references',
    ),
  );
  await writeCodexConfiguration(
    output,
    source,
    additionalReferences: references,
  );
  stdout.writeln('Prepared bundle: ${output.path}');
  stdout.writeln(
    'No hooks installed or trusted. Follow integrations/codex/README.md.',
  );
}
