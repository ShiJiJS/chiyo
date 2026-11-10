import 'dart:io';
import 'package:test/test.dart';

/// Windows byte-range locks prevent a second handle reading library.lock.
/// Its OS-reported zero length still proves it contains no plaintext. Every
/// non-lock artifact continues through the original full byte scan.
List<int> encryptedArtifactBytes(File file) {
  if (Platform.isWindows && file.uri.pathSegments.last == 'library.lock') {
    expect(
      file.statSync().size,
      0,
      reason: 'A held library lock must be empty',
    );
    return const [];
  }
  return file.readAsBytesSync();
}
