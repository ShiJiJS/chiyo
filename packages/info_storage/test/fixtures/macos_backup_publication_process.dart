import 'dart:convert';
import 'dart:io';
import 'package:info_storage/macos_backup_publication.dart';

// Only called with a parent test's isolated directories and synthetic material.
// This is a private-journal fixture, not a production persistence implementation.
void main(List<String> args) {
  if (args.length != 3) throw StateError('Expected fixture arguments');
  final [action, staging, output] = args;
  final journal = File('$staging/fixture-journal.json');
  if (action == 'publish') {
    final source = '$staging/material';
    MacBackupPublicationFiles.writeRecoveryKey(
      source,
      utf8.encode('synthetic process fixture'),
    );
    final value = MacBackupPublicationFiles.prepare(
      source,
      '$output/result.txt',
    );
    journal.writeAsStringSync(jsonEncode(value.toPrivateJson()), flush: true);
    MacBackupPublicationFiles.publish(value);
    // Exit without a receipt or cleanup: next process must only observe.
    stdout.writeln('published');
  } else if (action == 'reconcile') {
    final value = MacBackupPublication.fromPrivateJson(
      jsonDecode(journal.readAsStringSync()) as Map<String, dynamic>,
    );
    if (MacBackupPublicationFiles.observe(value) !=
        BackupPublicationObservation.matching) {
      throw StateError('Publication not proven');
    }
    MacBackupPublicationFiles.cleanup(value);
    journal.deleteSync();
    stdout.writeln('reconciled');
  } else {
    throw StateError('Unknown fixture action');
  }
}
