@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

Future<Map<String, dynamic>> aclCommand(String script, Directory root) async {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes.addAll([unit & 255, unit >> 8]);
  }
  final result = await Process.run(
    '${Platform.environment['SystemRoot']}/System32/WindowsPowerShell/v1.0/powershell.exe',
    ['-NoProfile', '-NonInteractive', '-EncodedCommand', base64Encode(bytes)],
    environment: {'INFO_PRIVATE_DIR': root.absolute.path},
    stdoutEncoding: null,
    stderrEncoding: null,
  );
  expect(
    result.exitCode,
    0,
    reason: utf8.decode(result.stderr as List<int>, allowMalformed: true),
  );
  return jsonDecode(utf8.decode(result.stdout as List<int>))
      as Map<String, dynamic>;
}

Future<Directory> ownedModifyDirectory() async {
  final container = await Directory.systemTemp.createTemp('codex-owned-');
  addTearDown(() => container.delete(recursive: true));
  final root = await Directory('${container.path}/中文 关联').create();
  final before = await aclCommand(r'''
$ErrorActionPreference = 'Stop'
$directory = $env:INFO_PRIVATE_DIR
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$existing = [System.IO.Directory]::GetAccessControl($directory)
if ($existing.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) { throw 'Fixture must belong to the current user' }
# Owners can update their DACL without WRITE_OWNER. Do not grant that extra
# right in the fixture: it is the real Windows failure this test reproduces.
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
[System.IO.Directory]::SetAccessControl($directory, $acl)
$actual = [System.IO.Directory]::GetAccessControl($directory)
$writeOwner = @($actual.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::TakeOwnership) -ne 0 }).Count
@{ ownerIsCurrentUser=($actual.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq $sid.Value); writeOwnerRules=$writeOwner } | ConvertTo-Json -Compress
''', root);
  expect(before, {'ownerIsCurrentUser': true, 'writeOwnerRules': 0});
  return root;
}

void main() {
  test(
    'owned Modify-only association directory becomes private without requiring ownership transfer',
    () async {
      final root = await ownedModifyDirectory();
      final marker = File('${root.path}/keep.txt');
      await marker.writeAsString('synthetic pre-existing file');
      final original = CodexAssociation(
        'windows-owned-modify',
        12345,
        's' * 64,
      );
      final reference = await original.save(root);
      final loaded = await CodexAssociation.load(reference, original.chatId);
      expect(loaded.secret, original.secret);
      expect(loaded.port, original.port);
      expect(await marker.readAsString(), 'synthetic pre-existing file');
      final after = await aclCommand(r'''
$ErrorActionPreference = 'Stop'
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$actual = [System.IO.Directory]::GetAccessControl($env:INFO_PRIVATE_DIR)
$others = @($actual.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -ne $sid.Value }).Count
$filesWithOtherAllows = 0
foreach ($file in [System.IO.Directory]::GetFiles($env:INFO_PRIVATE_DIR, '*.json')) {
  $fileAcl = [System.IO.File]::GetAccessControl($file)
  $filesWithOtherAllows += @($fileAcl.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -ne $sid.Value }).Count
}
@{ protected=$actual.AreAccessRulesProtected; ownerIsCurrentUser=($actual.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq $sid.Value); otherAllows=$others; fileOtherAllows=$filesWithOtherAllows } | ConvertTo-Json -Compress
''', root);
      expect(after, {
        'protected': true,
        'ownerIsCurrentUser': true,
        'otherAllows': 0,
        'fileOtherAllows': 0,
      });
    },
  );
  final compiled = Platform.environment['D6_COMPILED_CLI'];
  test(
    'compiled lifecycle startup creates a usable association in an owned Modify-only directory',
    () async {
      final root = await ownedModifyDirectory();
      final service = InformationService.fictional();
      final server = await AgentServer.start(service.agent, port: 0);
      addTearDown(() async {
        await server.close();
        await service.close();
      });
      final hook = File('${File(compiled!).parent.path}/info-codex-hook.exe');
      expect(await hook.exists(), isTrue);
      final process = await Process.start(hook.path, [
        '--port',
        '${server.port}',
        '--state-root',
        root.path,
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      process.stdin.writeln(
        jsonEncode({
          'hook_event_name': 'SessionStart',
          'source': 'startup',
          'session_id': 'owned-modify-hook-fixture',
        }),
      );
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 8)), 0);
      expect(await errors, isEmpty);
      final reply = jsonDecode(await output) as Map<String, dynamic>;
      expect(reply['hookSpecificOutput'], isA<Map>());
      // Only this newly created synthetic fixture is inspected. This never
      // discovers or recovers the current Codex chat's association.
      final references = await root
          .list(followLinks: false)
          .where(
            (e) =>
                e is File &&
                RegExp(r'[/\\][0-9a-f]{64}\.json$').hasMatch(e.path),
          )
          .toList();
      expect(references, hasLength(1));
      final association = await CodexAssociation.load(
        references.single.path,
        'owned-modify-hook-fixture',
      );
      final client = AgentClient(
        server.port,
        sessionSecret: association.secret,
      );
      addTearDown(client.close);
      expect(
        (await client.execute({'command': 'session-check'}))['status'],
        'ok',
      );
      expect(service.owner.sessions, hasLength(1));
    },
    skip: compiled == null,
  );
}
