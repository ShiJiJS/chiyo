import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'agent_bundle_observation.dart';

/// Checks the existing format-2 Windows package next to this running App.
/// This observation never launches a program or grants host integration trust.
class WindowsAgentBundle {
  WindowsAgentBundle({String? executable})
    : _executable = executable ?? Platform.resolvedExecutable;
  final String _executable;
  final _hashes = <String, (String, String)>{};
  static const appExecutable = 'app/info_desktop.exe';
  static const requiredFiles = {
    appExecutable,
    'app/info-runtime-worker.exe',
    'app/info-focus-broker.exe',
    'cli/info.exe',
    'cli/info-codex.exe',
    'cli/info-codex-hook.exe',
    'cli/info-runtime-worker.exe',
    'cli/info-prepare-codex.exe',
    'cli/template/SKILL.md',
    'cli/template/references/credential-use.md',
    'cli/template/references/information-files.md',
    'cli/template/references/information-file-intake.md',
    'cli/template/references/remote-connection.md',
    'CODEX-INTEGRATION.md',
  };
  String _path(String path) => path.replaceAll('\\', '/').toLowerCase();
  Future<File> _file(String root, String relative) async {
    final file = File('$root/$relative').absolute;
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        _path(await file.resolveSymbolicLinks()) != _path(file.path)) {
      throw const FormatException('Missing or redirected package file');
    }
    return file;
  }

  String _stamp(FileStat stat) =>
      '${stat.size}:${stat.mode}:${stat.modified.microsecondsSinceEpoch}:'
      '${stat.changed.microsecondsSinceEpoch}';

  Future<AgentBundleObservation> read({bool rehash = false}) async {
    final binary = File(_executable).absolute;
    if (!_path(binary.path).endsWith('/$appExecutable')) {
      return const AgentBundleObservation(status: 'not_packaged');
    }
    try {
      final package = binary.parent.parent;
      final root = await package.resolveSymbolicLinks();
      if (_path(root) != _path(package.path)) {
        throw const FormatException('Redirected package root');
      }
      if (!await File('$root/manifest.json').exists()) {
        return const AgentBundleObservation(status: 'manifest_missing');
      }
      final manifestFile = await _file(root, 'manifest.json');
      // The fixed AWS distribution contains ~7,600 regular files.
      const maxManifest = 8 * 1024 * 1024;
      if (await manifestFile.length() > maxManifest) {
        throw const FormatException('Manifest size');
      }
      final bytes = await manifestFile
          .openRead(0, maxManifest + 1)
          .fold<List<int>>([], (buffer, part) => buffer..addAll(part));
      if (bytes.length > maxManifest) {
        throw const FormatException('Manifest size');
      }
      final manifest = jsonDecode(utf8.decode(bytes));
      if (manifest is! Map ||
          manifest['format'] != 2 ||
          manifest['product'] != 'Agent Info Manage' ||
          manifest['architecture'] != 'windows-x64' ||
          manifest['sourceDirty'] != false ||
          manifest['sourceCommit'] is! String ||
          !RegExp(
            r'^[0-9a-f]{40}$',
          ).hasMatch(manifest['sourceCommit'] as String) ||
          manifest['files'] is! List) {
        throw const FormatException('Manifest identity');
      }
      final rows = manifest['files'] as List;
      if (rows.isEmpty || rows.length > 12000) {
        throw const FormatException('Manifest entry count');
      }
      final declared = <String, Map>{};
      final normalized = <String>{};
      for (final row in rows) {
        if (row is! Map ||
            row['path'] is! String ||
            row.containsKey('link') ||
            row['bytes'] is! int ||
            row['bytes'] < 0 ||
            row['bytes'] > 256 * 1024 * 1024 ||
            row['sha256'] is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(row['sha256'] as String)) {
          throw const FormatException('Manifest entry');
        }
        final relative = row['path'] as String;
        if (relative.length > 512 ||
            relative.contains('\\') ||
            relative.contains(':') ||
            relative
                .split('/')
                .any(
                  (segment) =>
                      segment.isEmpty ||
                      segment == '.' ||
                      segment == '..' ||
                      segment.endsWith('.') ||
                      segment.endsWith(' '),
                ) ||
            !RegExp(r'^[A-Za-z0-9_./+ -]+$').hasMatch(relative) ||
            !normalized.add(_path(relative))) {
          throw const FormatException('Unsafe or duplicate package path');
        }
        declared[relative] = row;
      }
      if (!declared.keys.toSet().containsAll(requiredFiles) ||
          declared['app/info-runtime-worker.exe']!['sha256'] !=
              declared['cli/info-runtime-worker.exe']!['sha256']) {
        throw const FormatException('Incomplete or mismatched tools');
      }
      final template = Directory('$root/cli/template');
      final expectedTemplate = declared.keys
          .where((p) => p.startsWith('cli/template/'))
          .toSet();
      final actualTemplate = <String>{};
      var count = 0;
      await for (final entry in template.list(
        recursive: true,
        followLinks: false,
      )) {
        if (++count > 32 ||
            entry is Link ||
            entry is Directory &&
                _path(entry.path) != _path('${template.path}/references')) {
          throw const FormatException('Unexpected Skill tree');
        }
        if (entry is File) {
          final relative = entry.path
              .substring(root.length + 1)
              .replaceAll('\\', '/');
          if (relative != 'cli/template/SKILL.md' &&
              !RegExp(
                r'^cli/template/references/[A-Za-z0-9._-]+\.md$',
              ).hasMatch(relative)) {
            throw const FormatException('Unexpected Skill entry');
          }
          actualTemplate.add(relative);
        }
      }
      if (actualTemplate.length != expectedTemplate.length ||
          !actualTemplate.containsAll(expectedTemplate)) {
        throw const FormatException('Undeclared or missing Skill references');
      }
      for (final entry in declared.entries) {
        final file = await _file(root, entry.key), before = await file.stat();
        if (before.size != entry.value['bytes']) {
          throw const FormatException('Package size');
        }
        final stamp = _stamp(before), cached = _hashes[file.path];
        final hash = !rehash && cached?.$1 == stamp
            ? cached!.$2
            : (await sha256.bind(file.openRead(0, before.size + 1)).first)
                  .toString();
        if (hash != entry.value['sha256'] ||
            _stamp(await file.stat()) != stamp) {
          throw const FormatException('Package hash or identity changed');
        }
        _hashes[file.path] = (stamp, hash);
      }
      return AgentBundleObservation(
        status: 'verified',
        directory: root,
        sourceCommit: manifest['sourceCommit'] as String,
        manifestDigest: sha256.convert(bytes).toString(),
      );
    } on Object {
      _hashes.clear();
      return const AgentBundleObservation(status: 'bundle_invalid');
    }
  }
}
