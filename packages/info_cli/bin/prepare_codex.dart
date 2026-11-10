import 'dart:io';
import 'dart:convert';

import 'package:info_cli/codex_bundle.dart';
import 'package:info_cli/codex_registration.dart';
import 'package:info_core/new_file_publish.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_cli/macos_bundled_tools.dart';
import 'package:info_cli/windows_bundled_tools.dart';

/// SDK-free preparation from the delivered CLI folder. No user configuration
/// or state directory is touched: all output goes into a new chosen directory.
Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == '--register-existing') {
    try {
      await registerCodexRuntime(Directory(args[1]).absolute);
      stdout.writeln(
        'Registered public Codex runtime descriptor; configuration and hook trust were not changed.',
      );
    } on Object {
      stderr.writeln(
        'Registration failed; use a reviewed complete bundle and keep existing configuration.',
      );
      exitCode = 1;
    }
    return;
  }
  if ((!Platform.isWindows && !Platform.isMacOS) ||
      args.isEmpty ||
      args.length.isEven) {
    stderr.writeln(
      'Usage: info-prepare-codex [--source-bundle <cli-folder>] [--connection <private-profile>] [--state-root <private-state-directory>] <new-stable-bundle-directory>\n       info-prepare-codex --register-existing <reviewed-bundle-directory>',
    );
    exitCode = 64;
    return;
  }
  try {
    final options = <String, String>{};
    for (var i = 0; i < args.length - 1; i += 2) {
      if (!const {
            '--source-bundle',
            '--connection',
            '--state-root',
          }.contains(args[i]) ||
          options.containsKey(args[i])) {
        throw const FormatException();
      }
      options[args[i]] = args[i + 1];
    }
    final source = options['--source-bundle'] == null
        ? File(Platform.resolvedExecutable).parent
        : Directory(options['--source-bundle']!).absolute;
    final output = Directory(args.last).absolute;
    final connectionFile = options['--connection'] == null
        ? null
        : File(options['--connection']!).absolute.path;
    final stateRoot = options['--state-root'] == null
        ? null
        : Directory(options['--state-root']!).absolute.path;
    if (connectionFile != null) {
      await AgentConnectionProfile.read(File(connectionFile));
    }
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
    final additionalReferences = <String, String>{};
    await for (final entity in Directory(
      '${source.path}/template/references',
    ).list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final name = entity.uri.pathSegments.last;
      if (const {'credential-use.md', 'information-files.md'}.contains(name)) {
        continue;
      }
      if (await entity.length() > 131072 || additionalReferences.length >= 32) {
        throw const FormatException('Invalid reference files');
      }
      additionalReferences[name] = await entity.readAsString();
    }
    final suffix = Platform.isWindows ? '.exe' : '';
    final binaries = [
      'info-codex$suffix',
      'info-codex-hook$suffix',
      'info-runtime-worker$suffix',
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
      if (Platform.isMacOS) {
        final reference = await MacBundledTools(
          executable: '${source.path}/info-codex',
        ).sourceReference();
        if (reference != null) {
          await File(
            '${staging.path}/${MacBundledTools.sourceFile}',
          ).writeAsString(jsonEncode(reference));
        }
      }
      if (Platform.isWindows) {
        final reference = await WindowsBundledTools(
          executable: '${source.path}/info-codex.exe',
        ).sourceReference();
        if (reference != null) {
          await File(
            '${staging.path}/${WindowsBundledTools.sourceFile}',
          ).writeAsString(jsonEncode(reference));
        }
      }
      // Render using the final directory, not the temporary staging directory.
      await writeCodexConfiguration(
        staging,
        skill,
        finalDirectory: output,
        credentialUseReference: credentialUseReference,
        informationFilesReference: informationFilesReference,
        connectionFile: connectionFile,
        stateRoot: stateRoot,
        additionalReferences: additionalReferences,
      );
      if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FileSystemException();
      }
      if (Platform.isMacOS) {
        publishNewDirectory(staging.path, output.path);
      } else {
        await staging.rename(output.path);
      }
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
