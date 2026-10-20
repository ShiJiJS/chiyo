import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';

/// Trusted test-owner stdin is separate from the untrusted JSON-lines CLI.
Future<void> main() async {
  final executable = File(Platform.resolvedExecutable);
  final stat = await executable.stat();
  final identity = ExecutableIdentity(
    executable.path,
    stat.size,
    stat.modified.microsecondsSinceEpoch,
    'sha256:${sha256.convert(await executable.readAsBytes())}',
  );
  final service = InformationService(
    repository: MemoryInformationRepository(),
    credentialExecutableInspector: (path, receiver) async => identity,
  );
  final server = await AgentServer.start(service.agent, port: 0);
  var credential = await service.owner.createFileCredential(
    name: 'Synthetic fixture file',
    publicPurpose: 'Local receiver only',
    fileName: 'credentials.ini',
    bytes: utf8.encode(
      '[default]\naws_access_key_id = TEST_ACCESS_ONLY\naws_secret_access_key = SYNTHETIC_NOT_A_REAL_SECRET\n',
    ),
  );
  credential = await service.owner.updateCredentialMetadata(
    credential.id,
    credential.revision,
    name: credential.name,
    publicPurpose: credential.publicPurpose,
    privateNote: '',
    suggestedBinding: 'token',
    discoverable: true,
  );
  stdout.writeln(
    jsonEncode({
      'port': server.port,
      'credentialId': credential.id,
      'version': credential.version,
      'executable': executable.path,
    }),
  );
  await stdout.flush();
  try {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final command = jsonDecode(line) as Map<String, dynamic>;
      if (command['command'] == 'approve') {
        await service.owner.decideCredentialUse(
          command['requestId'] as String,
          approveCredential: true,
        );
        stdout.writeln('{"status":"ok"}');
        await stdout.flush();
      }
    }
  } finally {
    for (final record in service.owner.credentialExecutions.where(
      (e) => e.materialLease != null,
    )) {
      try {
        await service.owner.cleanupCredentialExecution(record.id);
      } on Object {
        /* Unknown fixture material remains registered. */
      }
    }
    await server.close();
    await service.close();
  }
}
