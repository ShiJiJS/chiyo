import 'dart:convert';
import 'dart:io';
import 'dart:math';

bool validChatId(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,149}$').hasMatch(value);

/// Immutable private association. The random file reference is a bearer
/// capability, not an identity lookup. Never index or discover it by chat ID.
class CodexAssociation {
  CodexAssociation(this.chatId, this.port, this.secret, {String? rootChatId})
    : rootChatId = rootChatId ?? chatId;
  final String chatId;
  final int port;
  final String secret;
  final String rootChatId;

  Future<String> save(Directory root) async {
    if (!validChatId(chatId) || !validChatId(rootChatId)) {
      throw const FormatException();
    }
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException();
    }
    await _protect(root);
    final random = Random.secure();
    final name = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final file = File(
      '${root.absolute.path}${Platform.pathSeparator}$name.json',
    );
    await file.create(exclusive: true);
    await file.writeAsString(
      jsonEncode({
        'version': 2,
        'chatId': chatId,
        'rootChatId': rootChatId,
        'port': port,
        'secret': secret,
      }),
      flush: true,
    );
    return file.path;
  }

  static Future<CodexAssociation> load(String reference, String chatId) async {
    final file = File(reference);
    if (!validChatId(chatId) ||
        !file.isAbsolute ||
        !RegExp(r'[/\\][0-9a-f]{64}\.json$').hasMatch(reference) ||
        await FileSystemEntity.type(reference, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 4096) {
      throw const FormatException();
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if ((data['version'] != 1 && data['version'] != 2) ||
        data['chatId'] != chatId ||
        (data['version'] == 2 &&
            (data['rootChatId'] is! String ||
                !validChatId(data['rootChatId'] as String))) ||
        data['port'] is! int ||
        data['port'] < 1 ||
        data['port'] > 65535 ||
        data['secret'] is! String ||
        (data['secret'] as String).length < 40) {
      throw const FormatException();
    }
    return CodexAssociation(
      chatId,
      data['port'] as int,
      data['secret'] as String,
      rootChatId: data['rootChatId'] as String? ?? chatId,
    );
  }

  static Directory defaultRoot() {
    final base = Platform.isWindows
        ? Platform.environment['LOCALAPPDATA']
        : Platform.environment['HOME'];
    if (base == null || base.isEmpty) throw const FormatException();
    return Directory(
      Platform.isWindows
          ? '$base/AgentInfo/codex'
          : '$base/Library/Application Support/AgentInfo/codex',
    );
  }

  static Future<void> _protect(Directory root) async {
    if (Platform.isWindows) {
      // Path enters as an environment value, never PowerShell source. This
      // process has no UI and cannot access the association contents.
      const script = r'''
$ErrorActionPreference = 'Stop'
$directory = $env:INFO_PRIVATE_DIR
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
[System.IO.Directory]::SetAccessControl($directory, $acl)
$actual = [System.IO.Directory]::GetAccessControl($directory)
if (-not $actual.AreAccessRulesProtected) { throw 'Private storage unavailable' }
foreach ($entry in $actual.Access) {
  if ($entry.AccessControlType -eq 'Allow' -and $entry.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) { throw 'Private storage unavailable' }
}
''';
      final bytes = <int>[];
      for (final unit in script.codeUnits) {
        bytes.add(unit & 255);
        bytes.add(unit >> 8);
      }
      final systemRoot = Platform.environment['SystemRoot'];
      if (systemRoot == null) throw const FormatException();
      final result = await Process.run(
        '$systemRoot/System32/WindowsPowerShell/v1.0/powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          base64Encode(bytes),
        ],
        environment: {'INFO_PRIVATE_DIR': root.absolute.path},
      );

      if (result.exitCode != 0) {
        throw const FileSystemException('private_storage_unavailable');
      }
    } else if (Platform.isMacOS || Platform.isLinux) {
      final result = await Process.run('/bin/chmod', [
        '700',
        root.absolute.path,
      ]);
      if (result.exitCode != 0 || (await root.stat()).mode & 0x3f != 0) {
        throw const FileSystemException('private_storage_unavailable');
      }
    } else {
      throw const FileSystemException('private_storage_unavailable');
    }
  }
}
