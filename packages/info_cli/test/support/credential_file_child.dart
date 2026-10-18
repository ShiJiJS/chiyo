import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final file = File(env['AWS_SHARED_CREDENTIALS_FILE']!);
  final config = File(env['AWS_CONFIG_FILE']!);
  final system = env['SystemRoot']!;
  final check = await Process.start(
    '$system/System32/WindowsPowerShell/v1.0/powershell.exe',
    const [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'''
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
$paths=[Console]::In.ReadToEnd() | ConvertFrom-Json
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$valid=$true
foreach($path in $paths){
 $acl=Get-Acl -LiteralPath $path
 $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 if(-not $acl.AreAccessRulesProtected -or $rules.Count -ne 2){$valid=$false}
 foreach($rule in $rules){if($rule.IdentityReference.Value -notin @($sid,'S-1-5-18') -or $rule.IsInherited -or $rule.AccessControlType -ne 'Allow'){$valid=$false}}
}
if($valid){[Console]::Out.Write('private')}else{[Console]::Out.Write('invalid')}
''',
    ],
    environment: {'SystemRoot': system, 'WINDIR': system},
    includeParentEnvironment: false,
    runInShell: false,
  );
  final aclOutput = utf8.decoder.bind(check.stdout).join();
  final aclError = check.stderr.drain<void>();
  check.stdin.write(jsonEncode([file.path, file.parent.path, config.path]));
  await check.stdin.close();
  final aclCode = await check.exitCode;
  await aclError;
  stdout.writeln(
    jsonEncode({
      'materialMatches':
          await file.readAsString() ==
          '[default]\naws_access_key_id = TEST_ACCESS_ONLY\naws_secret_access_key = SYNTHETIC_NOT_A_REAL_SECRET\n',
      'configEmpty': await config.readAsString() == '',
      'privateAcl': aclCode == 0 && await aclOutput == 'private',
      'literalPreserved': args.contains('{{file:token}}'),
      'otherAuthAbsent':
          !env.containsKey('AWS_ACCESS_KEY_ID') &&
          !env.containsKey('INFO_SESSION_SECRET'),
    }),
  );
  await stdout.flush();
  await Future<void>.delayed(const Duration(milliseconds: 200));
}
