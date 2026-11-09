import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

String codexRegistrationPath() {
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const FormatException('Missing home');
    }
    return '$home/Library/Application Support/AgentInfo/codex/integration.json';
  }
  if (Platform.isWindows) {
    final base = Platform.environment['LOCALAPPDATA'];
    if (base == null || base.isEmpty) {
      throw const FormatException('Missing local data');
    }
    return '$base/AgentInfo/Codex/integration.json';
  }
  throw const FormatException('Unsupported platform');
}

/// Register only public paths and hashes. This does not install a Skill,
/// create an association, edit Codex configuration or grant hook trust.
Future<Map<String, Object?>> registerCodexRuntime(
  Directory bundle, {
  File? descriptor,
}) async {
  final root = Directory(await bundle.resolveSymbolicLinks());
  final suffix = Platform.isWindows ? '.exe' : '';
  final binaries = [
    'info-codex$suffix',
    'info-codex-hook$suffix',
    'info-runtime-worker$suffix',
  ];
  final skillRoots = [
    Directory.fromUri(root.uri.resolve('template')),
    Directory.fromUri(root.uri.resolve('skills/agent-info-access')),
  ];
  final candidates = <Directory>[];
  for (final candidate in skillRoots) {
    if (await candidate.exists()) candidates.add(candidate);
  }
  if (candidates.length != 1) {
    throw const FormatException('Ambiguous or missing Skill');
  }
  final skill = candidates.single;
  final expectedSkillPath = skill.path;
  if (await skill.resolveSymbolicLinks() != expectedSkillPath) {
    throw const FormatException('Redirected Skill');
  }
  final files = <String>[...binaries];
  if (await File('${root.path}/macos-tools-source.json').exists()) {
    files.add('macos-tools-source.json');
  }
  final prefix = '${root.path}${Platform.pathSeparator}';
  await for (final entry in skill.list(recursive: true, followLinks: false)) {
    final type = await FileSystemEntity.type(entry.path, followLinks: false);
    final relative = entry.path.substring(prefix.length).replaceAll('\\', '/');
    final local = entry.path
        .substring(skill.path.length + 1)
        .replaceAll('\\', '/');
    if (type == FileSystemEntityType.directory && local == 'references') {
      continue;
    }
    if (type != FileSystemEntityType.file ||
        !(local == 'SKILL.md' ||
            RegExp(r'^references/[A-Za-z0-9._-]+\.md$').hasMatch(local))) {
      throw const FormatException('Unexpected Skill material');
    }
    files.add(relative);
  }
  final skillRelative =
      '${skill.path.substring(prefix.length).replaceAll('\\', '/')}/SKILL.md';
  if (!files.contains(skillRelative)) {
    throw const FormatException('Missing Skill');
  }
  final rows = <Map<String, Object?>>[];
  for (final relative in files..sort()) {
    final file = File('${root.path}/$relative');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !(await file.resolveSymbolicLinks()).startsWith(prefix)) {
      throw const FormatException('Missing or redirected program');
    }
    final size = await file.length();
    if (size < 1 || size > 128 * 1024 * 1024) {
      throw const FormatException('Invalid program size');
    }
    rows.add({
      'path': relative,
      'bytes': size,
      'sha256': (await sha256.bind(file.openRead()).first).toString(),
    });
  }
  final registration = <String, Object?>{
    'schemaVersion': 1,
    'bundleDirectory': root.path,
    'cliPath': '${root.path}/${binaries[0]}',
    'hookPath': '${root.path}/${binaries[1]}',
    'workerPath': '${root.path}/${binaries[2]}',
    'skillPath': '${root.path}/$skillRelative',
    'files': rows,
  };
  final target = descriptor ?? File(codexRegistrationPath());
  if (target.uri.pathSegments.last != 'integration.json') {
    throw const FormatException('Not a runtime descriptor');
  }
  final targetType = await FileSystemEntity.type(
    target.path,
    followLinks: false,
  );
  if (targetType != FileSystemEntityType.notFound) {
    if (targetType != FileSystemEntityType.file ||
        await target.length() > 262144) {
      throw const FormatException('Unsafe existing descriptor');
    }
    final old = jsonDecode(await target.readAsString());
    if (old is! Map ||
        old['schemaVersion'] != 1 ||
        old['files'] is! List ||
        old['cliPath'] is! String) {
      throw const FormatException('Not an existing runtime descriptor');
    }
  }
  await target.parent.create(recursive: true);
  if (!Platform.isWindows) {
    final permission = await Process.run('/bin/chmod', [
      '700',
      target.parent.path,
    ]);
    if (permission.exitCode != 0) {
      throw const FileSystemException('Cannot protect descriptor directory');
    }
  }
  final stage = await target.parent.createTemp('.runtime-registration-');
  try {
    final pending = File('${stage.path}/integration.json');
    await pending.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(registration)}\n',
      flush: true,
    );
    if (Platform.isWindows && await target.exists()) {
      // Windows registration is additive to the existing installer contract.
      // Keep its prior contents if replacement cannot be completed.
      final old = await target.readAsBytes();
      await target.delete();
      try {
        await pending.rename(target.path);
      } on Object {
        await target.writeAsBytes(old, flush: true);
        rethrow;
      }
    } else {
      await pending.rename(target.path);
    }
  } finally {
    if (await stage.exists()) await stage.delete(recursive: true);
  }
  return registration;
}
