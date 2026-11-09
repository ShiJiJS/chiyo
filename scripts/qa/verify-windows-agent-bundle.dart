import 'dart:convert';
import 'dart:io';

import 'package:info_cli/agent_bundle.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length != 2) {
    stderr.writeln('Expected Windows App executable and source commit');
    exitCode = 64;
    return;
  }
  final observation = await AgentBundle(executable: args[0]).read(rehash: true);
  stdout.writeln(
    jsonEncode({
      'status': observation.status,
      'sourceCommit': observation.sourceCommit,
      'manifestDigest': observation.manifestDigest,
    }),
  );
  if (!observation.verified || observation.sourceCommit != args[1]) {
    exitCode = 1;
  }
}
