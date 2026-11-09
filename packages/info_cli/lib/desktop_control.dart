import 'dart:io';
import 'macos_agent_bundle.dart';
import 'package:info_core/windows_desktop_control.dart';
import 'package:info_core/macos_desktop_control.dart';

/// Separate from JSON-lines content/session commands. No grant can approve or
/// manage the library through this narrow native lifetime entry.
Future<({Map<String, Object?> output, int exitCode})> desktopControlCommand(
  List<String> args,
) async {
  ({Map<String, Object?> output, int exitCode}) invalid() => (
    output: const {'controlVersion': 1, 'status': 'invalid_request'},
    exitCode: 64,
  );
  if (args.length < 2 ||
      args.first != 'app' ||
      !{'status', 'quit'}.contains(args[1])) {
    return invalid();
  }
  int? processId;
  String? profile;
  var timeoutMs = 15000;
  final seen = <String>{};
  for (var i = 2; i < args.length; i += 2) {
    if (i + 1 == args.length ||
        !{'--pid', '--timeout-ms', '--connection-profile'}.contains(args[i]) ||
        !seen.add(args[i])) {
      return invalid();
    }
    if (args[i] == '--connection-profile') {
      if (!Platform.isMacOS ||
          !MacDesktopControl.validProfileName(args[i + 1])) {
        return invalid();
      }
      profile = args[i + 1];
      continue;
    }
    final value = int.tryParse(args[i + 1]);
    if (value == null) return invalid();
    if (args[i] == '--pid') {
      if (value < 1 || value > 0xffffffff) return invalid();
      processId = value;
    } else {
      if (value < 100 || value > 60000) return invalid();
      timeoutMs = value;
    }
  }
  final root = File(Platform.resolvedExecutable).parent.parent.path;
  var relative = 'app/info_desktop.exe';
  if (Platform.isMacOS) {
    final current = File('$root/${MacAgentBundle.appExecutable}');
    relative = await current.exists()
        ? MacAgentBundle.appExecutable
        : MacAgentBundle.legacyAppExecutable;
  }
  const embeddedRoot = '/Contents/Resources/AgentIntegration';
  final executable = Platform.isMacOS && root.endsWith(embeddedRoot)
      ? '${root.substring(0, root.length - embeddedRoot.length)}/Contents/MacOS/info_desktop'
      : File('$root/$relative').absolute.path;
  final result = Platform.isMacOS
      ? await MacDesktopControl.execute(
          quit: args[1] == 'quit',
          executable: executable,
          processId: processId,
          timeout: Duration(milliseconds: timeoutMs),
          directory: profile == null
              ? null
              : MacDesktopControl.defaultDirectory(profile: profile),
        )
      : await WindowsDesktopControl.execute(
          quit: args[1] == 'quit',
          executable: executable,
          processId: processId,
          timeout: Duration(milliseconds: timeoutMs),
        );
  return (
    output: result,
    exitCode: switch (result['status']) {
      'running' || 'starting' || 'exiting' || 'exited' || 'not_running' => 0,
      'invalid_request' => 64,
      'unsupported_platform' || 'unsupported_version' => 69,
      'shutdown_failed' || 'startup_failed' || 'unexpected_exit' => 1,
      _ => 75,
    },
  );
}
