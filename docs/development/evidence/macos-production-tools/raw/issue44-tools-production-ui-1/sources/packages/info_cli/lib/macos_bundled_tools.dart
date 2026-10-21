import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/agent_server.dart';

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

  Future<List<CredentialToolLocation>> read() async {
    final rows = <CredentialToolLocation>[];
    final binary = File(_executable).absolute;
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
