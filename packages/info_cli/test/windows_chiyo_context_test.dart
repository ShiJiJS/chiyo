@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

Future<Map<String, dynamic>> _acl(
  Directory directory, {
  bool shared = false,
}) async {
  final result = await Process.run(
    '${Platform.environment['SystemRoot']}/System32/WindowsPowerShell/v1.0/powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$path = $env:CHIYO_TEST_DIRECTORY
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
if ($env:CHIYO_TEST_SHARED -eq '1') {
  $acl = New-Object System.Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($user,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
  $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
  $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
  [IO.Directory]::SetAccessControl($path,$acl)
}
$actual = [IO.Directory]::GetAccessControl($path)
$sharedAllows = @($actual.Access | Where-Object {
  $_.AccessControlType -eq 'Allow' -and
  $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -in @('S-1-1-0','S-1-5-11','S-1-5-32-545')
}).Count
@{ protected=$actual.AreAccessRulesProtected; ownerIsCurrentUser=($actual.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq $user.Value); sharedAllows=$sharedAllows; sddl=$actual.GetSecurityDescriptorSddlForm('All') } | ConvertTo-Json -Compress
''',
    ],
    environment: {
      'CHIYO_TEST_DIRECTORY': directory.path,
      'CHIYO_TEST_SHARED': shared ? '1' : '0',
    },
    stdoutEncoding: utf8,
    stderrEncoding: systemEncoding,
  );
  expect(result.exitCode, 0, reason: result.stderr as String);
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}

void main() {
  late Directory root;
  setUp(() async {
    final base = Directory(
      '../../build/cli-redesign-windows/contexts',
    ).absolute;
    await base.create(recursive: true);
    root = await Directory(
      await base.resolveSymbolicLinks(),
    ).createTemp('Windows 私有 chat ');
  });
  tearDown(() async {
    final base = Directory(
      '../../build/cli-redesign-windows/contexts',
    ).absolute;
    final resolved = await root.resolveSymbolicLinks();
    if (!resolved.startsWith('${await base.resolveSymbolicLinks()}\\')) {
      throw StateError('Context fixture escaped its build directory');
    }
    await root.delete(recursive: true);
  });
  ChiyoContext context({
    String secret = 'SYNTHETIC-CONTEXT-SECRET-012345678901234567890123456789',
  }) => ChiyoContext(
    chatId: 'windows-synthetic-chat',
    agentName: 'Windows synthetic agent',
    secret: secret,
    port: 43123,
    endCapability: 'E' * 64,
    connection: AgentConnectionProfile.local(
      port: 43123,
      deviceToken: '${'A' * 22}.${'B' * 43}',
      libraryId: 'windows-synthetic-library',
    ),
  );

  test(
    'new Unicode/space context uses DPAPI and private Windows ACLs',
    () async {
      final original = context();
      final file = File('${root.path}/new private/聊天 配置.json');
      await original.saveNew(file);
      final bytes = await file.readAsBytes();
      for (final value in [original.secret, original.endCapability!]) {
        expect(latin1.decode(bytes), isNot(contains(value)));
      }
      final loaded = await ChiyoContext.load(file, environment: {});
      expect(loaded.secret, original.secret);
      expect(loaded.endCapability, original.endCapability);
      expect(loaded.publicStatus['libraryId'], original.connection!.serverId);
      final permissions = await _acl(file.parent);
      expect(permissions['protected'], true);
      expect(permissions['ownerIsCurrentUser'], true);
      expect(permissions['sharedAllows'], 0);
    },
  );

  test('an existing context is not overwritten or re-keyed', () async {
    final file = File('${root.path}/new private/聊天 配置.json');
    await context().saveNew(file);
    final original = await file.readAsBytes();
    await expectLater(
      context(secret: 'X' * 64).saveNew(file),
      throwsA(isA<FormatException>()),
    );
    expect(await file.readAsBytes(), original);
    await expectLater(
      ChiyoContext.load(file, environment: {'CHIYO_CHAT_ID': 'different-chat'}),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'a general Windows directory is refused without changing its ACL',
    () async {
      final general = await Directory(
        '${root.path}/general documents',
      ).create();
      final marker = File('${general.path}/keep.txt');
      await marker.writeAsString('synthetic existing document');
      final before = await _acl(general, shared: true);
      expect(before['sharedAllows'], 1);
      final target = File('${general.path}/chat.json');
      var refused = false;
      try {
        await context().saveNew(target);
      } on Object {
        refused = true;
      }
      final after = await _acl(general);
      expect(
        {
          'refused': refused,
          'aclUnchanged': after['sddl'] == before['sddl'],
          'newFileAbsent': !await target.exists(),
          'documentPreserved':
              await marker.readAsString() == 'synthetic existing document',
        },
        {
          'refused': true,
          'aclUnchanged': true,
          'newFileAbsent': true,
          'documentPreserved': true,
        },
      );
    },
  );
}
