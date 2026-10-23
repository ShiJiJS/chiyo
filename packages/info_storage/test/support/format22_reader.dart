// Compiled against pinned, genuine pre-portable-format source by the QA script.
// Existing synthetic profiles only; no OS key store, production path or secret
// argument. The constant below is a public fixture key, never a user's key.
import 'dart:convert';
import 'dart:io';
import 'package:info_storage/info_storage.dart';

class _FixtureKeys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 61);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Existing fixture required');
}

Future<void> main(List<String> args) async {
  if (args.length != (args.firstOrNull == 'backup' ? 5 : 3) ||
      !{'library', 'backup'}.contains(args.firstOrNull)) {
    throw StateError('Explicit synthetic reader action required');
  }
  final root = await Directory(args[1]).resolveSymbolicLinks();
  final temporary = await Directory.systemTemp.resolveSymbolicLinks();
  if (root != Directory(args[1]).absolute.path ||
      !root.startsWith('$temporary${Platform.pathSeparator}') ||
      !Directory(root).uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('focused-fill-storage-')) {
    throw StateError('Not an owned synthetic profile');
  }
  final profile = await Directory(args[2]).resolveSymbolicLinks();
  if (!profile.startsWith('$root${Platform.pathSeparator}') ||
      await FileSystemEntity.type('$profile/library.db', followLinks: false) !=
          FileSystemEntityType.file) {
    throw StateError('Existing synthetic library required');
  }
  Future<String> ownedFile(String path) async {
    final resolved = await File(path).resolveSymbolicLinks();
    if (!resolved.startsWith('$root${Platform.pathSeparator}'))
      throw StateError('Not an owned file');
    return resolved;
  }

  EncryptedInformationRepository? repository;
  Map<String, Object?> result;
  try {
    repository = await EncryptedInformationRepository.open(
      profile,
      _FixtureKeys(),
      clock: () => DateTime.utc(2026, 10, 19),
    );
    if (args.first == 'backup') {
      final backup = await ownedFile(args[3]);
      final recovery = File(await ownedFile(args[4]));
      if (await recovery.length() > 256)
        throw StateError('Invalid synthetic recovery file');
      final preview = await repository.backups.inspect(
        backup,
        (await recovery.readAsString()).trim(),
      );
      result = {'status': 'accepted', 'backupFormat': preview.formatVersion};
    } else {
      result = {'status': 'opened', 'cipherVersion': repository.cipherVersion};
    }
  } on StorageFailure catch (error) {
    result = {'status': 'rejected', 'errorCode': error.code};
  } finally {
    await repository?.close();
  }
  print(jsonEncode(result));
}
