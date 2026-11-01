import 'dart:convert';
import 'dart:io';
import 'package:info_storage/macos_backup_publication.dart';

// A standalone process verifies Swift's allocation identity equals the exact
// Dart identity persisted by the production SQLCipher staging registration.
Future<void> main(List<String> args) async {
  final file = File(args.single);
  final swift = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final dart = MacBackupPublicationFiles.captureStaging(
    swift['path'] as String,
  );
  if (jsonEncode(dart.toPrivateJson()) != jsonEncode(swift)) {
    // JSON dictionary order differs between Swift and Dart; compare fields.
    if (swift.length != 3 ||
        dart.toPrivateJson().entries.any((e) => swift[e.key] != e.value)) {
      throw StateError('Native and Dart staging identity differ');
    }
  }
  MacBackupPublicationFiles.cleanupStaging(dart);
  await file.writeAsString(jsonEncode(dart.toPrivateJson()));
  stdout.writeln(
    'PASS: Dart captured native identity and removed exact empty child',
  );
}
