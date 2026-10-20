// Isolated AOT crash-test recipient. No production profile or OS key store.
// Synthetic database/recovery keys arrive only through private stdin.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_storage/info_storage.dart';

class _ExistingKey implements DatabaseKeyStore {
  _ExistingKey(this.value);
  final List<int> value;
  @override
  Future<List<int>?> read() async => List.of(value);
  @override
  Future<void> create(List<int> value) async =>
      throw StateError('Expected existing synthetic target key');
}

Future<void> main() async {
  EncryptedInformationRepository? repository;
  var stage = 'input';
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  try {
    if (!Platform.isMacOS || !await input.moveNext()) {
      throw StateError('Mac fixture input required');
    }
    final config = jsonDecode(input.current) as Map<String, dynamic>;
    stage = 'path-validation';
    final directory = Directory(config['directory'] as String);
    final actual = await directory.resolveSymbolicLinks();
    final base = await Directory.systemTemp.resolveSymbolicLinks();
    if (actual != directory.absolute.path ||
        !actual.startsWith('$base/aim-macos-restore-')) {
      throw StateError('Expected owned synthetic target');
    }
    final key = (config['databaseKey'] as List).cast<int>();
    if (key.length != 32 || key.any((v) => v < 0 || v > 255)) {
      throw StateError('Invalid synthetic key');
    }
    stage = 'open-database';
    repository = await EncryptedInformationRepository.open(
      directory.path,
      _ExistingKey(key),
    );
    stage = 'inspect-backup';
    final preview = await repository.backups.inspect(
      config['backup'] as String,
      config['recoveryKey'] as String,
    );
    stdout.writeln(jsonEncode({'phase': 'ready', 'pid': pid}));
    await stdout.flush();
    if (!await input.moveNext() || input.current != 'restore') {
      throw StateError('Explicit restore command required');
    }
    stage = 'restore';
    await repository.backups.restore(preview);
    stdout.writeln(jsonEncode({'phase': 'restored'}));
  } catch (error) {
    stdout.writeln(
      jsonEncode({
        'phase': 'failed',
        'stage': stage,
        'code': error is StorageFailure
            ? error.code
            : error.runtimeType.toString(),
      }),
    );
    exitCode = 1;
  } finally {
    await repository?.close();
    await input.cancel();
  }
}
