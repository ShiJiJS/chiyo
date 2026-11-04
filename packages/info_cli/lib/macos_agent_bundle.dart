import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Package consistency, not code signing, host trust or CLI connectivity.
class MacAgentBundleObservation {
  const MacAgentBundleObservation({
    required this.status,
    this.directory,
    this.sourceCommit,
    this.manifestDigest,
    this.embedded = false,
  });
  final String status;
  final String? directory, sourceCommit, manifestDigest;

  /// Checks the signed app's integration resources, not its external siblings.
  final bool embedded;
  bool get verified => status == 'verified';
}

/// Reads only known siblings of this running app; never searches personal
/// settings, associations, PATH or another installed application.
class MacAgentBundle {
  MacAgentBundle({String? executable})
    : _executable = executable ?? Platform.resolvedExecutable;
  final String _executable;
  final _hashes = <String, (String, String)>{};
  static const appExecutable = 'app/chiyo.app/Contents/MacOS/info_desktop';
  static const legacyAppExecutable =
      'app/info_desktop.app/Contents/MacOS/info_desktop';
  static const requiredFiles = [
    appExecutable,
    'app/chiyo.app/Contents/Info.plist',
    'cli/info',
    'cli/info-codex',
    'cli/info-codex-hook',
    'cli/info-runtime-worker',
    'cli/info-prepare-codex',
    'cli/template/SKILL.md',
    'cli/template/references/credential-use.md',
    'cli/template/references/information-files.md',
    'CODEX-INTEGRATION.md',
  ];
  static const embeddedDirectory = 'Resources/AgentIntegration';
  static final embeddedFiles = requiredFiles
      .where((p) => !p.startsWith('app/'))
      .toList(growable: false);
  String _stamp(FileStat s) =>
      '${s.type}:${s.size}:${s.mode}:'
      '${s.modified.microsecondsSinceEpoch}:${s.changed.microsecondsSinceEpoch}';
  Future<File> _file(String root, String relative) async {
    final file = File('$root/$relative');
    if (await file.resolveSymbolicLinks() != file.path ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const FormatException('redirected package entry');
    }
    return file;
  }

  Future<MacAgentBundleObservation> read({bool rehash = false}) async {
    final binary = File(_executable).absolute;
    const suffix = '/Contents/MacOS/info_desktop';
    if (!binary.path.endsWith(suffix)) {
      return const MacAgentBundleObservation(status: 'not_packaged');
    }
    try {
      final contents = binary.parent.parent.path;
      final embeddedRoot = '$contents/$embeddedDirectory';
      // Production resources are inside the sandbox-readable signed app. Do
      // not fall back to external files when an embedded tree is damaged.
      final embedded =
          await FileSystemEntity.type(embeddedRoot, followLinks: false) !=
          FileSystemEntityType.notFound;
      final legacy = binary.path.endsWith('/$legacyAppExecutable');
      final packageExecutable = legacy ? legacyAppExecutable : appExecutable;
      if (!embedded && !binary.path.endsWith('/$packageExecutable')) {
        return const MacAgentBundleObservation(status: 'not_packaged');
      }
      final rootPath = embedded
          ? embeddedRoot
          : binary.path.substring(
              0,
              binary.path.length - packageExecutable.length - 1,
            );
      final root = await Directory(rootPath).resolveSymbolicLinks();
      if (embedded && root != embeddedRoot) {
        throw const FormatException('redirected integration root');
      }
      final manifestFile = File('$root/manifest.json');
      if (!await manifestFile.exists()) {
        return const MacAgentBundleObservation(status: 'manifest_missing');
      }
      await _file(root, 'manifest.json');
      const maxManifest = 4 * 1024 * 1024;
      if (await manifestFile.length() > maxManifest) {
        throw const FormatException('manifest size');
      }
      final bytes = await manifestFile
          .openRead(0, maxManifest + 1)
          .fold<List<int>>([], (a, b) => a..addAll(b));
      if (bytes.length > maxManifest) {
        throw const FormatException('manifest size');
      }
      final manifest = jsonDecode(utf8.decode(bytes));
      if (manifest is! Map ||
          manifest['format'] != (embedded ? 2 : 1) ||
          (embedded && manifest['scope'] != 'app_integration') ||
          manifest['architecture'] != 'macos-arm64' ||
          manifest['appIdentity'] != 'com.example.infoDesktop' ||
          manifest['sourceDirty'] != false ||
          manifest['sourceCommit'] is! String ||
          !RegExp(
            r'^[0-9a-f]{40}$',
          ).hasMatch(manifest['sourceCommit'] as String) ||
          manifest['files'] is! List) {
        throw const FormatException('manifest identity');
      }
      final rows = manifest['files'] as List;
      if (embedded) {
        final identity = await _file(contents, 'Resources/agent-source.json');
        if (await identity.length() > 1024) {
          throw const FormatException('app source size');
        }
        final source = jsonDecode(await identity.readAsString());
        if (source is! Map ||
            source['appIdentity'] != manifest['appIdentity'] ||
            source['sourceCommit'] != manifest['sourceCommit']) {
          throw const FormatException('app source differs');
        }
      }
      final required = embedded
          ? embeddedFiles
          : legacy
          ? requiredFiles
                .map(
                  (path) => path.replaceFirst(
                    'app/chiyo.app/',
                    'app/info_desktop.app/',
                  ),
                )
                .toList(growable: false)
          : requiredFiles;
      final expectedTemplate = required
          .where((p) => p.startsWith('cli/template/'))
          .toSet();
      final actualTemplate = <String>{};
      final template = Directory('$root/cli/template');
      if (await template.resolveSymbolicLinks() != template.path) {
        throw const FormatException('redirected template root');
      }
      var entries = 0;
      await for (final entry in template.list(
        recursive: true,
        followLinks: false,
      )) {
        if (++entries > 32 ||
            entry is Link ||
            (entry is Directory &&
                entry.path != '${template.path}/references')) {
          throw const FormatException('unexpected template tree');
        }
        if (entry is File) {
          actualTemplate.add(entry.path.substring(root.length + 1));
        }
      }
      if (actualTemplate.length != expectedTemplate.length ||
          !actualTemplate.containsAll(expectedTemplate)) {
        throw const FormatException('unexpected template files');
      }
      for (final relative in required) {
        final matches = rows.where((r) => r is Map && r['path'] == relative);
        if (matches.length != 1) throw const FormatException('entry count');
        final row = matches.single as Map, expected = row['sha256'];
        if (row.containsKey('link') ||
            expected is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected) ||
            row['bytes'] is! int ||
            row['mode'] is! int) {
          throw const FormatException('entry declaration');
        }
        final file = await _file(root, relative), before = await file.stat();
        final executable =
            relative == packageExecutable ||
            (relative.startsWith('cli/') &&
                !relative.startsWith('cli/template/'));
        if (before.size > 256 * 1024 * 1024 ||
            before.size != row['bytes'] ||
            before.mode & 0xfff != row['mode'] ||
            (executable && before.mode & 0x49 == 0)) {
          throw const FormatException('entry size or mode');
        }
        final stamp = _stamp(before), cached = _hashes[file.path];
        final hash = !rehash && cached?.$1 == stamp
            ? cached!.$2
            : (await sha256.bind(file.openRead(0, before.size + 1)).first)
                  .toString();
        if (_stamp(await file.stat()) != stamp ||
            await file.resolveSymbolicLinks() != file.path ||
            hash != expected) {
          throw const FormatException('entry changed');
        }
        _hashes[file.path] = (stamp, hash);
      }
      if (await manifestFile.length() != bytes.length ||
          (await sha256.bind(manifestFile.openRead(0, maxManifest + 1)).first)
                  .toString() !=
              sha256.convert(bytes).toString()) {
        throw const FormatException('manifest changed');
      }
      return MacAgentBundleObservation(
        status: 'verified',
        directory: root,
        sourceCommit: manifest['sourceCommit'] as String,
        manifestDigest: sha256.convert(bytes).toString(),
        embedded: embedded,
      );
    } on Object {
      _hashes.clear();
      return const MacAgentBundleObservation(status: 'bundle_invalid');
    }
  }
}
