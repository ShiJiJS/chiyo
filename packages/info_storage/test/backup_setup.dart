import 'dart:io';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

/// Existing backup scenarios also perform the newly required independent save.
Future<String> enableTestBackups(InformationBackups backups) async {
  final key = await backups.enable();
  final folder = await Directory.systemTemp.createTemp(
    'independent-test-recovery-',
  );
  addTearDown(() => folder.delete(recursive: true));
  await backups.saveRecoveryKeyTo('${folder.path}/recovery.txt');
  return key;
}
