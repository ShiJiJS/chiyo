import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';

class RuntimeHarness {
  RuntimeHarness._(
    this.service,
    this.server,
    this.client,
    this.credential,
    this.executablePath,
  );
  final InformationService service;
  final AgentServer server;
  final AgentClient client;
  final ManagedCredential credential;
  final String executablePath;
  static Future<RuntimeHarness> create({
    CredentialProcessStarter? starter,
    String? executablePath,
    List<int>? fileBytes,
    bool inspectTool = false,
    InformationRepository? repository,
    bool enableReusableCredentialUse = false,
  }) async {
    final exe = File(executablePath ?? Platform.resolvedExecutable);
    final stat = await exe.stat();
    final digest = 'sha256:${sha256.convert(await exe.readAsBytes())}';
    final service = InformationService(
      repository: repository ?? MemoryInformationRepository(),
      credentialExecutableInspector: inspectTool
          ? inspectCredentialExecutable
          : (path, receiver) async => ExecutableIdentity(
              path,
              stat.size,
              stat.modified.microsecondsSinceEpoch,
              digest,
            ),
    );
    final server = await AgentServer.start(
      service.agent,
      port: 0,
      enableReusableCredentialUse: enableReusableCredentialUse,
    );
    final client = AgentClient(server.port, credentialProcessStarter: starter);
    var c = fileBytes == null
        ? await service.owner.createStringCredential(
            name: 'Synthetic',
            publicPurpose: '',
            secret: 'synthetic-token',
          )
        : await service.owner.createFileCredential(
            name: 'Synthetic file',
            publicPurpose: '',
            fileName: 'credentials.ini',
            bytes: fileBytes,
          );
    c = await service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: '',
      privateNote: '',
      suggestedBinding: 'GH_TOKEN',
      discoverable: true,
    );
    await client.execute({
      'command': 'session',
      'chatLabel': 'Controlled runtime',
    });
    return RuntimeHarness._(service, server, client, c, exe.path);
  }

  Future<String> approve({
    String? cwd,
    List<Object?> argv = const ['api', 'user'],
    String? receiver,
    int protocolVersion = 1,
  }) async {
    final selectedReceiver =
        receiver ??
        (credential.form == CredentialForm.file
            ? 'aws_shared_credentials'
            : 'gh_token');
    final r = await client.execute({
      'command': 'request-use',
      'protocolVersion': protocolVersion,
      'purpose': 'Controlled runtime test',
      'credentials': [
        {'alias': 'token', 'credentialId': credential.id, 'version': 1},
      ],
      'launch': {
        'receiver': selectedReceiver,
        'executable': executablePath,
        'argv': argv,
        'cwd': cwd ?? Directory.current.path,
        'env': {
          if (selectedReceiver == 'aws_shared_credentials')
            'AWS_SHARED_CREDENTIALS_FILE': {'file': 'token'}
          else if (selectedReceiver == 'gh_token')
            'GH_TOKEN': {'secret': 'token'},
        },
      },
    });
    if (r['status'] != 'pending') {
      throw StateError('Controlled plan was rejected');
    }
    final id = r['requestId'] as String;
    await service.owner.decideCredentialUse(id, approveCredential: true);
    return id;
  }

  Future<void> close() async {
    await client.drainCredentialExecutions();
    for (final execution in service.owner.credentialExecutions.where(
      (e) => e.materialLease != null && e.cleanupState != 'complete',
    )) {
      try {
        await service.owner.cleanupCredentialExecution(execution.id);
      } on CredentialUseFailure {
        /* Preserve any active or unknown test resource. */
      }
    }
    client.close();
    await server.close();
    await service.close();
  }

  /// A target exit is earlier than the end of its whole Windows Job. Poll the
  /// original operation and cleanup endpoint; never start a replacement task.
  Future<Map<String, dynamic>> waitForMaterialCleanup(
    String executionId,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final status = await client.execute({
        'command': 'execution-status',
        'executionId': executionId,
      });
      if (status['executionState'] != 'exited') {
        throw StateError('Receiver has no established exit: $status');
      }
      if ({'complete', 'not_needed'}.contains(status['cleanupState'])) {
        return status;
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw StateError('Receiver material did not settle: $status');
      }
      final result = await client.execute({
        'command': 'cleanup-use',
        'executionId': executionId,
      });
      if (result['errorCode'] != null &&
          !{'cleanup_busy', 'cleanup_failed'}.contains(result['errorCode'])) {
        throw StateError('Unexpected material identity failure: $result');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
