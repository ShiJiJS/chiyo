import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';

Future<void> main(List<String> args) async {
  try {
    if (args.length == 2 && args.first == 'init-secrets') {
      await initializeServerSecrets(args.last);
      stdout.writeln(jsonEncode({'state': 'initialized'}));
      return;
    }
    if (args.length != 2 || args.first != 'serve') {
      stderr.writeln(
        'Usage: server init-secrets DIRECTORY | serve CONFIG.json',
      );
      exitCode = 64;
      return;
    }
    final config = await ServerConfiguration.read(args.last);
    final repository = await EncryptedInformationRepository.open(
      config.dataDirectory,
      MountedDatabaseKeyStore(config.databaseKeyFile),
    );
    final service = InformationService(repository: repository);
    OnlineServer? server;
    StreamSubscription<ProcessSignal>? interrupt, terminate;
    try {
      server = await OnlineServer.start(
        service: service,
        tls: config.tls,
        ownerToken: config.ownerToken,
        serverId: config.serverId,
        address: config.address,
        port: config.port,
      );
      final stopped = Completer<void>();
      void stop(ProcessSignal _) {
        if (!stopped.isCompleted) stopped.complete();
      }

      interrupt = ProcessSignal.sigint.watch().listen(stop);
      terminate = ProcessSignal.sigterm.watch().listen(stop);
      stdout.writeln(
        jsonEncode({
          'state': 'ready',
          'port': server.port,
          'serverId': config.serverId,
          'protocolVersion': 1,
        }),
      );
      await stopped.future;
    } finally {
      await interrupt?.cancel();
      await terminate?.cancel();
      await server?.close();
      await service.close();
      await repository.close();
    }
  } on StorageFailure catch (error) {
    stderr.writeln(jsonEncode({'error': error.code}));
    exitCode = 1;
  } on Object {
    // Config values, TLS secrets and filesystem paths never enter diagnostics.
    stderr.writeln(jsonEncode({'error': 'server_start_failed'}));
    exitCode = 1;
  }
}
