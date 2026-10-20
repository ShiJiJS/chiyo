// Only synthetic archived-source libraries under the owned QA root are used.
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

Future<void> main(List<String> args) async {
  if (args.length != 3 ||
      !{'wrap', 'inspect'}.contains(args[0]) ||
      !{'upgraded', 'restored', 'old-reader-copy'}.contains(args[2])) {
    throw StateError('Explicit synthetic upgrade action required');
  }
  final root = Directory(args[1]);
  final canonical = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  if (root.absolute.path.toLowerCase() != canonical.toLowerCase() ||
      !canonical.toLowerCase().startsWith(
        '$temp${Platform.pathSeparator}'.toLowerCase(),
      ) ||
      !root.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('aim-packaged-upgrade-')) {
    throw StateError('Not an owned synthetic upgrade fixture');
  }
  final directory = '${root.path}/${args[2]}/AgentInfoManage';
  final keys = WindowsDatabaseKeyStore('$directory/database-key.dpapi');
  if (args.first == 'wrap') {
    // The archived helper's fixed synthetic key. This does not open/migrate DB.
    final key = List<int>.filled(32, 61);
    try {
      await keys.create(key);
    } finally {
      key.fillRange(0, key.length, 0);
    }
    stdout.writeln('{"status":"wrapped"}');
    return;
  }
  final key = await keys.read();
  if (key == null) throw StateError('Missing synthetic key');
  final raw = sqlite.sqlite3.open('$directory/library.db');
  late final int schemaBeforeOpen;
  try {
    final hex = key.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
    raw.execute('PRAGMA key = "x\'$hex\'"');
    schemaBeforeOpen =
        raw.select('PRAGMA user_version').single.values.single as int;
  } finally {
    raw.close();
  }
  final independentKey = key.any((n) => n != 61);
  key.fillRange(0, key.length, 0);
  final repo = await EncryptedInformationRepository.open(directory, keys);
  final service = InformationService(repository: repo);
  try {
    stdout.writeln(
      jsonEncode({
        'status': 'inspected',
        'schemaBeforeOpen': schemaBeforeOpen,
        'informationMatches':
            repo.items.length == 1 &&
            repo.items.single.name == 'Legacy fixture' &&
            repo.items.single.fields.single.value == 'LEGACY_VALUE_ONLY',
        'credentialMatches':
            repo.managedCredentials.length == 1 &&
            repo.credentialMaterials.length == 1 &&
            utf8.decode(repo.credentialMaterials.single.bytes) ==
                'LEGACY_SECRET_ONLY',
        'requests': repo.credentialUseRequests.length,
        'onlyV1Facts': repo.credentialUseRequests.every(
          (r) => r.protocolVersion == 1,
        ),
        'attemptsConsumed': repo.credentialUseRequests
            .where((r) => r.attemptConsumed)
            .length,
        'unusedInvalidation': repo.credentialUseRequests
            .singleWhere((r) => !r.attemptConsumed)
            .invalidatedCode,
        'executionFacts': repo.credentialExecutions.length,
        'independentKey': independentKey,
      }),
    );
  } finally {
    await service.close();
    await repo.close();
  }
}
