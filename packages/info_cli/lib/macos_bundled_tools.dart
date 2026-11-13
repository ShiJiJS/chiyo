import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/agent_server.dart';
import 'macos_agent_bundle.dart';

/// Discovers this running app's tools, independent of its installation path.
/// Entry hashes are checked without executing tools or reading user settings.
/// Actual credential operations still inspect identity/version and need approval.
class MacBundledTools {
  MacBundledTools({String? executable})
    : _executable = executable ?? Platform.resolvedExecutable;
  final String _executable;
  static const _entries = {
    'gh_token': ('gh/bin/gh', '2.102.0'),
    'aws_shared_credentials': ('aws-cli/aws', '2.38.1'),
  };
  static const sourceFile = 'macos-tools-source.json';

  /// Prepared CLI bundles retain a public pointer to their matching App, not
  /// another copy of its large tools or any user's connection credentials.
  Future<Map<String, Object?>?> sourceReference() async {
    final app = await _application();
    if (app == null) return null;
    final observed = await MacAgentBundle(executable: app).read(rehash: true);
    if (!observed.verified) return null;
    return {
      'version': 1,
      'application': app,
      'sourceCommit': observed.sourceCommit,
    };
  }

  Future<String?> _application() async {
    final binary = File(_executable).absolute;
    if (binary.parent.path.endsWith('.app/Contents/MacOS')) return binary.path;
    try {
      String app;
      String? expectedCommit;
      const embedded = '/Contents/Resources/AgentIntegration/cli';
      if (binary.parent.path.endsWith(embedded)) {
        app =
            '${binary.parent.path.substring(0, binary.parent.path.length - embedded.length)}/Contents/MacOS/info_desktop';
      } else if (binary.parent.uri.pathSegments
                  .where((s) => s.isNotEmpty)
                  .last ==
              'cli' &&
          await File(
            '${binary.parent.parent.path}/${MacAgentBundle.appExecutable}',
          ).exists()) {
        app = '${binary.parent.parent.path}/${MacAgentBundle.appExecutable}';
      } else {
        final file = File('${binary.parent.path}/$sourceFile');
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
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
      final observed = await MacAgentBundle(executable: app).read(rehash: true);
      if (!observed.verified ||
          expectedCommit != null && observed.sourceCommit != expectedCommit) {
        return null;
      }
      final name = binary.uri.pathSegments.last;
      if (!const {
        'chiyo',
        'info',
        'info-codex',
        'info-codex-hook',
        'info-runtime-worker',
      }.contains(name)) {
        return null;
      }
      final matching = File('${observed.directory}/cli/$name');
      if ((await sha256.bind(binary.openRead()).first).toString() !=
          (await sha256.bind(matching.openRead()).first).toString()) {
        return null;
      }
      return app;
    } on Object {
      return null;
    }
  }

  Future<List<CredentialToolLocation>> read() async {
    final rows = <CredentialToolLocation>[];
    final binary = File(await _application() ?? _executable).absolute;
    final macos = binary.parent;
    final contents = macos.parent;
    final bundled = macos.path.endsWith('.app/Contents/MacOS');
    final root = Directory('${contents.path}/Resources/ThirdParty');
    Map<String, dynamic>? manifest;
    if (bundled) {
      try {
        final appRoot = await contents.parent.resolveSymbolicLinks();
        if (await root.resolveSymbolicLinks() !=
            '$appRoot/Contents/Resources/ThirdParty') {
          throw const FormatException('Redirected tool bundle');
        }
        final file = File('${root.path}/manifest.json');
        if (await file.length() > 4 * 1024 * 1024) {
          throw const FormatException('Oversized manifest');
        }
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic> ||
            decoded['format'] != 1 ||
            decoded['platform'] != 'macos-arm64' ||
            decoded['tools'] is! List) {
          throw const FormatException('Invalid bundle manifest');
        }
        manifest = decoded;
      } on Object {
        // Information/SSH remain usable when a tool bundle is absent or damaged.
      }
    }
    for (final entry in _entries.entries) {
      String? path;
      var reason = 'bundle_missing';
      if (manifest != null) {
        reason = 'bundle_invalid';
        try {
          final matches = (manifest['tools'] as List).where(
            (row) => row is Map && row['receiver'] == entry.key,
          );
          if (matches.length != 1) throw const FormatException('Tool entry');
          final row = matches.single as Map;
          final expected = row['executableSha256'];
          if (row['executable'] != entry.value.$1 ||
              row['version'] != entry.value.$2 ||
              expected is! String ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
            throw const FormatException('Tool declaration');
          }
          final file = File('${root.path}/${entry.value.$1}');
          if ((await file.stat()).mode & 0x49 == 0) {
            throw const FormatException('Entry is not executable');
          }
          final resolved = await file.resolveSymbolicLinks();
          final base = await root.resolveSymbolicLinks();
          if (!resolved.startsWith('$base/')) {
            throw const FormatException('Tool outside bundle');
          }
          if ((await sha256.bind(file.openRead()).first).toString() !=
              expected) {
            throw const FormatException('Entry hash mismatch');
          }
          path = file.path;
        } on Object {
          // No fallback to PATH, Homebrew, user auth, or an external bookmark.
        }
      }
      rows.add(
        CredentialToolLocation(
          receiver: entry.key,
          source: 'app_bundle',
          available: path != null,
          version: entry.value.$2,
          executable: path,
          unavailableReason: path == null ? reason : null,
        ),
      );
    }
    final sshExists = await File('/usr/bin/ssh').exists();
    rows.add(
      CredentialToolLocation(
        receiver: 'ssh_identity',
        source: 'system',
        available: sshExists,
        executable: sshExists ? '/usr/bin/ssh' : null,
        unavailableReason: sshExists ? null : 'system_tool_missing',
      ),
    );
    return List.unmodifiable(rows);
  }
}
