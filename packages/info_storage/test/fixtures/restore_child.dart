import 'dart:convert';
import 'dart:io';
import 'package:info_storage/info_storage.dart';

/// Console-only crash-test recipient. Secrets arrive through private stdin,
/// never arguments, stdout or error diagnostics. Not an agent-facing CLI.
Future<void> main() async {
  EncryptedInformationRepository? repository;
  try {
    final line = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    final input = jsonDecode(line) as Map<String, dynamic>;
    final directory = input['directory'] as String;
    repository = await EncryptedInformationRepository.open(
      directory,
      WindowsDatabaseKeyStore('$directory/key.dpapi'),
    );
    final snapshot = await repository.backups.inspect(
      input['backup'] as String,
      input['key'] as String,
    );
    stdout.writeln('backup_ready:$pid');
    await stdout.flush();
    await repository.backups.restore(snapshot);
    stdout.writeln('backup_restored');
  } catch (error) {
    stdout.writeln(
      'backup_failed:${error is StorageFailure ? error.code : error.runtimeType}',
    );
    exitCode = 1;
  } finally {
    await repository?.close();
  }
}
