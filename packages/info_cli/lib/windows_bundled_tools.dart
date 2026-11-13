import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/agent_server.dart';
import 'windows_agent_bundle.dart';

/// Observes shipped tools and Windows OpenSSH without inheriting user auth or
/// searching PATH. Execution still requires approval and identity/version checks.
class WindowsBundledTools {
  WindowsBundledTools({String? executable})
    : _executable = executable ?? Platform.resolvedExecutable;
  final String _executable;
  static const sourceFile = 'windows-tools-source.json';
  static const _entries = {
    'gh_token': ('gh/bin/gh.exe', '2.102.0'),
    'aws_shared_credentials': ('aws-cli/aws.exe', '2.38.1'),
  };
  String _path(String value) => value.replaceAll('\\', '/').toLowerCase();

  Future<({String app, String root, String commit, String digest})?>
  _application() async {
    try {
      final binary = File(_executable).absolute;
      String app;
      String? expectedCommit;
      final isApp = _path(
        binary.path,
      ).endsWith('/${WindowsAgentBundle.appExecutable}');
      if (isApp) {
        app = binary.path;
      } else if (_path(binary.parent.path).endsWith('/cli') &&
          await File(
            '${binary.parent.parent.path}/${WindowsAgentBundle.appExecutable}',
          ).exists()) {
        app =
            '${binary.parent.parent.path}/${WindowsAgentBundle.appExecutable}';
      } else {
        final file = File('${binary.parent.path}/$sourceFile');
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            _path(await file.resolveSymbolicLinks()) != _path(file.path) ||
            await file.length() > 2048) {
          return null;
        }
        final raw = jsonDecode(await file.readAsString());
        if (raw is! Map ||
            raw.length != 3 ||
            raw['version'] != 1 ||
            raw['application'] is! String ||
            raw['sourceCommit'] is! String) {
          return null;
        }
        app = raw['application'] as String;
        expectedCommit = raw['sourceCommit'] as String;
      }
      if (!File(app).isAbsolute) return null;
      final observed = await WindowsAgentBundle(
        executable: app,
      ).read(rehash: true);
      if (!observed.verified ||
          expectedCommit != null && observed.sourceCommit != expectedCommit) {
        return null;
      }
      if (!isApp) {
        final name = binary.uri.pathSegments.last.toLowerCase();
        if (!const {
              'chiyo.exe',
              'info.exe',
              'info-codex.exe',
              'info-codex-hook.exe',
              'info-runtime-worker.exe',
              'info-prepare-codex.exe',
            }.contains(name) ||
            _path(await binary.resolveSymbolicLinks()) != _path(binary.path)) {
          return null;
        }
        final matching = File('${observed.directory}/cli/$name');
        if ((await sha256.bind(binary.openRead()).first).toString() !=
            (await sha256.bind(matching.openRead()).first).toString()) {
          return null;
        }
      }
      return (
        app: app,
        root: observed.directory!,
        commit: observed.sourceCommit!,
        digest: observed.manifestDigest!,
      );
    } on Object {
      return null;
    }
  }

  /// A public pointer to the verified matching package; contains no profile.
  Future<Map<String, Object?>?> sourceReference() async {
    final source = await _application();
    return source == null
        ? null
        : {
            'version': 1,
            'application': source.app,
            'sourceCommit': source.commit,
          };
  }

  Future<List<CredentialToolLocation>> read() async {
    final source = await _application();
    Map? manifest;
    if (source != null) {
      try {
        // The package manifest must declare this manifest and every tool file;
        // WindowsAgentBundle checked their bytes before we trust the entry.
        final manifestFile = File('${source.root}/manifest.json');
        if (await manifestFile.length() > 8 * 1024 * 1024) {
          throw const FormatException();
        }
        final packageBytes = await manifestFile.readAsBytes();
        if (sha256.convert(packageBytes).toString() != source.digest) {
          throw const FormatException();
        }
        final packageManifest = jsonDecode(utf8.decode(packageBytes)) as Map;
        final declared = {
          for (final row in (packageManifest['files'] as List).cast<Map>())
            row['path']: row,
        };
        if (!declared.containsKey('tools/manifest.json')) {
          throw const FormatException();
        }
        final file = File('${source.root}/tools/manifest.json');
        if (await file.length() > 4 * 1024 * 1024) {
          throw const FormatException();
        }
        final toolBytes = await file.readAsBytes();
        if (sha256.convert(toolBytes).toString() !=
            declared['tools/manifest.json']!['sha256']) {
          throw const FormatException();
        }
        final raw = jsonDecode(utf8.decode(toolBytes));
        if (raw is! Map ||
            raw['format'] != 1 ||
            raw['platform'] != 'windows-x64' ||
            raw['tools'] is! List ||
            raw['files'] is! List ||
            (raw['files'] as List).isEmpty ||
            (raw['files'] as List).length > 10000) {
          throw const FormatException();
        }
        final inventory = <String>{};
        for (final row in raw['files'] as List) {
          if (row is! Map ||
              row['path'] is! String ||
              !inventory.add('tools/${row['path']}') ||
              !declared.containsKey('tools/${row['path']}')) {
            throw const FormatException();
          }
          final outer = declared['tools/${row['path']}']!;
          if (outer['sha256'] != row['sha256'] ||
              outer['bytes'] != row['bytes']) {
            throw const FormatException();
          }
        }
        final expected = declared.keys
            .whereType<String>()
            .where((p) => p.startsWith('tools/') && p != 'tools/manifest.json')
            .toSet();
        if (inventory.length != expected.length ||
            !inventory.containsAll(expected)) {
          throw const FormatException();
        }
        final actual = <String>{};
        var entryCount = 0;
        await for (final entry in Directory(
          '${source.root}/tools',
        ).list(recursive: true, followLinks: false)) {
          if (++entryCount > 20000 ||
              entry is Link ||
              entry is Directory &&
                  _path(await entry.resolveSymbolicLinks()) !=
                      _path(entry.absolute.path)) {
            throw const FormatException();
          }
          if (entry is File) {
            final relative = entry.path
                .substring(source.root.length + 1)
                .replaceAll('\\', '/');
            if (relative != 'tools/manifest.json' &&
                !inventory.contains(relative)) {
              throw const FormatException();
            }
            actual.add(relative);
          }
          if (actual.length > 10001) throw const FormatException();
        }
        if (actual.length != inventory.length + 1) {
          throw const FormatException();
        }
        manifest = raw;
      } on Object {
        // Keep unavailable tools observable rather than borrowing PATH/auth.
      }
    }
    final rows = <CredentialToolLocation>[];
    for (final entry in _entries.entries) {
      String? path;
      if (manifest != null) {
        try {
          final matches = (manifest['tools'] as List).where(
            (r) => r is Map && r['receiver'] == entry.key,
          );
          final row = matches.single as Map;
          if (row['executable'] != entry.value.$1 ||
              row['version'] != entry.value.$2) {
            throw const FormatException();
          }
          final file = File('${source!.root}/tools/${entry.value.$1}');
          final recorded = (manifest['files'] as List).cast<Map>().singleWhere(
            (r) => r['path'] == entry.value.$1,
          );
          if (row['executableSha256'] != recorded['sha256']) {
            throw const FormatException();
          }
          path = file.path;
        } on Object {
          // Missing or duplicate declaration is not a usable tool.
        }
      }
      rows.add(
        CredentialToolLocation(
          receiver: entry.key,
          source: 'app_bundle',
          available: path != null,
          version: entry.value.$2,
          executable: path,
          unavailableReason: path == null
              ? (source == null ? 'bundle_missing' : 'bundle_invalid')
              : null,
        ),
      );
    }
    final system = Platform.environment['SystemRoot'];
    final ssh = system == null
        ? null
        : File('$system/System32/OpenSSH/ssh.exe');
    final sshExists = ssh != null && await ssh.exists();
    rows.add(
      CredentialToolLocation(
        receiver: 'ssh_identity',
        source: 'system',
        available: sshExists,
        executable: sshExists ? ssh.path : null,
        unavailableReason: sshExists ? null : 'system_tool_missing',
      ),
    );
    return List.unmodifiable(rows);
  }
}
