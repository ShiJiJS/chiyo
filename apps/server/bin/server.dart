import 'package:info_server/agent_devices.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_server/owner_authentication.dart';

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
    final newLibrary =
        await FileSystemEntity.type(
          '${config.dataDirectory}/library.db',
          followLinks: false,
        ) ==
        FileSystemEntityType.notFound;
    final repository = await EncryptedInformationRepository.openOnline(
      config.dataDirectory,
      MountedDatabaseKeyStore(config.databaseKeyFile),
      readCacheMiB: config.readCacheMiB,
    );
    late final OwnerAuthentication ownerAuthentication;
    try {
      // Read login state only after acquiring the library's process lock, so a
      // waiting replacement process cannot retain stale pre-setup auth state.
      ownerAuthentication = await OwnerAuthentication.open(
        config.dataDirectory,
        config.ownerToken,
        newLibrary: newLibrary,
      );
    } on Object {
      await repository.close();
      rethrow;
    }
    final runtime = await OnlineInformationRuntime.open(repository: repository);
    OnlineServer? server;
    StreamSubscription<ProcessSignal>? interrupt, terminate;
    try {
      server = await OnlineServer.start(
        devices: AgentDeviceRegistry(repository),
        runtime: runtime,
        tls: config.tls,
        ownerToken: config.ownerToken,
        serverId: config.serverId,
        ownerAuthentication: ownerAuthentication,
        address: config.address,
        port: config.port,
        backups: repository.backups,
        backupDirectory: Directory('${config.dataDirectory}/backup-transfers'),
        policyState: repository,
        replication: LibraryReplication(repository),
        replicationDirectory: Directory(
          '${config.dataDirectory}/replication-transfers',
        ),
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
      await runtime.close();
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
