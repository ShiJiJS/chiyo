import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'ssh_session_remote_source.dart';
import 'ssh_session_transport.dart';

/// A short command keeps Windows CreateProcess safely below its argv limit.
/// os.read requests only the remaining source bytes; protocol data is never
/// prefetched into a Python buffered reader and lost. No secret is in the source.
const sshSessionBootstrap = '''import os,sys
n=int(sys.argv[1])
if not 1 <= n <= 262144: raise SystemExit(78)
b=bytearray()
while len(b)<n:
 c=os.read(0,n-len(b))
 if not c: raise SystemExit(78)
 b.extend(c)
CHIYO_SOURCE=b.decode('utf-8')
exec(compile(CHIYO_SOURCE,'<chiyo-session>','exec'))''';
List<int> get sshSessionRemoteSource =>
    base64Decode(sshSessionRemoteSourceBase64);
String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

// -o values pass through OpenSSH's config parser after native argv parsing.
// Keep each path one config value. Only UserKnownHostsFile expands tokens.
String _configPath(String value, {bool expandTokens = false}) {
  var path = Platform.isWindows ? value.replaceAll('\\', '/') : value;
  if (expandTokens) path = path.replaceAll('%', '%%');
  return '"${path.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
}

/// Config and target arguments are constructed here, never appended by Agents.
/// OpenSSH's first-value-wins options cannot be overridden by user config.
SshTransportLaunch sshSessionLaunch({
  required SshSessionTarget target,
  required String executable,
  required String knownHostsPath,
  required String emptyConfigPath,
  String? privateKeyPath,
  Future<void> Function(int processId, String processIdentity)?
  onProcessCreated,
  required SshLoginChallengeHandler onLoginChallenge,
}) {
  if (!File(executable).isAbsolute ||
      !File(knownHostsPath).isAbsolute ||
      !File(emptyConfigPath).isAbsolute ||
      (target.authentication == 'publickey') != (privateKeyPath != null)) {
    throw const SshTransportFailure('invalid_ssh_launch');
  }
  final source = sshSessionRemoteSource;
  final system = Platform.environment['SystemRoot'];
  final environment = Platform.isWindows
      ? <String, String>{
          'SystemRoot': ?system,
          'WINDIR': ?system,
          'PATH': '$system\\System32',
          'TEMP': Directory.systemTemp.path,
          'TMP': Directory.systemTemp.path,
        }
      : <String, String>{
          'PATH': '/usr/bin:/bin',
          'HOME': File(knownHostsPath).parent.path,
          'LANG': 'C.UTF-8',
          'TMPDIR': Directory.systemTemp.path,
        };
  return SshTransportLaunch(
    executable: executable,
    arguments: [
      '-F',
      emptyConfigPath,
      '-T',
      '-p',
      '${target.port}',
      '-oStrictHostKeyChecking=yes',
      '-oUserKnownHostsFile=${_configPath(knownHostsPath, expandTokens: true)}',
      '-oGlobalKnownHostsFile=${_configPath(emptyConfigPath)}',
      '-oIdentitiesOnly=yes',
      '-oIdentityAgent=none',
      '-oKbdInteractiveAuthentication=no',
      '-oNumberOfPasswordPrompts=1',
      '-oControlMaster=no',
      '-oControlPath=none',
      '-oClearAllForwardings=yes',
      '-oForwardAgent=no',
      '-oForwardX11=no',
      '-oPermitLocalCommand=no',
      '-oProxyCommand=none',
      '-oProxyJump=none',
      '-oConnectTimeout=15',
      '-oServerAliveInterval=15',
      '-oServerAliveCountMax=2',
      if (target.authentication == 'password') ...[
        '-oPreferredAuthentications=password',
        '-oPubkeyAuthentication=no',
        '-oPasswordAuthentication=yes',
      ] else ...[
        '-oPreferredAuthentications=publickey',
        '-oPasswordAuthentication=no',
        '-oPubkeyAuthentication=yes',
        '-i',
        privateKeyPath!,
      ],
      '--',
      '${target.user}@${target.host}',
      'python3 -u -c ${_quote(sshSessionBootstrap)} ${source.length}',
    ],
    environment: environment,
    onProcessCreated: onProcessCreated,
    onLoginChallenge: onLoginChallenge,
  );
}
