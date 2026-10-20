import 'dart:io';

import 'package:info_cli/codex_bundle.dart';

/// SDK-free preparation from the delivered CLI folder. No user configuration
/// or state directory is touched: all output goes into a new chosen directory.
Future<void> main(List<String> args) async {
  if (!Platform.isWindows ||
      !(args.length == 1 ||
          (args.length == 3 && args.first == '--source-bundle'))) {
    stderr.writeln(
      'Usage: info-prepare-codex.exe [--source-bundle <cli-folder>] <new-stable-bundle-directory>',
    );
    exitCode = 64;
    return;
  }
  final source = args.length == 3
      ? Directory(args[1]).absolute
      : File(Platform.resolvedExecutable).parent;
  final output = Directory(args.last).absolute;
  try {
    if (await FileSystemEntity.type(output.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      stderr.writeln('Destination exists; choose a new bundle directory.');
      exitCode = 64;
      return;
    }
    final skill = await File('${source.path}/template/SKILL.md').readAsString();
    final credentialUseReference = await File(
      '${source.path}/template/references/credential-use.md',
    ).readAsString();
    final informationFilesReference = await File(
      '${source.path}/template/references/information-files.md',
    ).readAsString();
    const binaries = [
      'info-codex.exe',
      'info-codex-hook.exe',
      'info-runtime-worker.exe',
    ];
    for (final name in binaries) {
      if (!await File('${source.path}/$name').exists()) {
        throw const FileSystemException();
      }
    }
    await output.parent.create(recursive: true);
    final staging = await output.parent.createTemp('.agent-info-prepare-');
    try {
      for (final name in binaries) {
        await File('${source.path}/$name').copy('${staging.path}/$name');
      }
      // Render using the final directory, not the temporary staging directory.
      await writeCodexConfiguration(
        staging,
        skill,
        finalDirectory: output,
        credentialUseReference: credentialUseReference,
        informationFilesReference: informationFilesReference,
      );
      if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FileSystemException();
      }
      await staging.rename(output.path);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
    stdout.writeln('Prepared bundle: ${output.path}');
    stdout.writeln(
      'Review hooks.json and Skill before installing or trusting.',
    );
  } on Object {
    stderr.writeln(
      'Preparation failed; existing configuration was not changed.',
    );
    exitCode = 1;
  }
}
