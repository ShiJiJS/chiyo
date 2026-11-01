import 'dart:io';
import 'package:info_storage/macos_backup_publication.dart';

// Invoked by an isolated signed native panel probe. Only synthetic bytes are
// written; the caller owns the selected destination and native staging token.
void main(List<String> args) {
  if (!Platform.isMacOS || args.length != 2) {
    throw StateError('Native macOS staging and selection required');
  }
  final stage = MacBackupPublicationFiles.captureStaging(args[0]);
  final prepared = '${args[0]}/prepared';
  const bytes = [83, 89, 78, 84, 72, 69, 84, 73, 67];
  MacBackupPublicationFiles.writeRecoveryKey(prepared, bytes);
  final value = MacBackupPublicationFiles.prepare(prepared, args[1]);
  MacBackupPublicationFiles.publish(value);
  if (MacBackupPublicationFiles.confirmPublished(value) !=
      BackupPublicationObservation.matching) {
    throw StateError('Publication not confirmed');
  }
  // A repeated publication must not replace even the previously selected file.
  var refused = false;
  try {
    MacBackupPublicationFiles.publish(value);
  } on BackupPublicationFailure {
    refused = true;
  }
  if (!refused ||
      File(args[1]).readAsBytesSync().join(',') != bytes.join(',')) {
    throw StateError('Existing output changed');
  }
  MacBackupPublicationFiles.cleanup(value);
  MacBackupPublicationFiles.cleanupStaging(stage);
  print('SELECTED_OUTPUT_PUBLICATION_PASS');
}
