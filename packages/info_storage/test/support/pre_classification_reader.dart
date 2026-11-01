import 'dart:io';
import 'dart:convert';
import 'package:info_storage/info_storage.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 73);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Fixture key exists');
}

// Compiled against genuine 77dc8b66 source, not a simulated version comparison.
Future<void> main(List<String> args) async {
  if (args.length != 2 || !{'library', 'backup'}.contains(args[1]))
    throw StateError('Explicit reader action required');
  final root = await Directory(args[0]).resolveSymbolicLinks();
  if (root != Directory(args[0]).absolute.path ||
      !root.startsWith(
        '${await Directory.systemTemp.resolveSymbolicLinks()}/',
      ) ||
      !root.split('/').last.startsWith('credential-classification-process-') ||
      await File('$root/fixture-marker').readAsString() !=
          'synthetic-classification-v1')
    throw StateError('Owned synthetic root required');
  EncryptedInformationRepository? repo;
  String? outcome;
  try {
    repo = await EncryptedInformationRepository.open(
      '$root/${args[1] == 'library' ? 'source' : 'old-reader-recipient'}',
      _Keys(),
    );
    if (args[1] == 'backup') {
      final key = (await File(
        '$root/synthetic-recovery.txt',
      ).readAsString()).trim();
      await repo.backups.inspect('$root/synthetic.aimbackup', key);
    }
  } on StorageFailure catch (e) {
    outcome = e.code;
  } finally {
    await repo?.close();
  }
  final expected = args[1] == 'library'
      ? 'unsupported_schema'
      : 'unsupported_backup';
  if (outcome != expected)
    throw StateError('Old reader did not reject unsupported content');
  stdout.writeln(
    jsonEncode({
      'phase': 'old-${args[1]}',
      'pid': pid,
      'passed': true,
      'outcome': outcome,
    }),
  );
}
