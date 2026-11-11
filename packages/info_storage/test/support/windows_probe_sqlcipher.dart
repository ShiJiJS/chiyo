import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqlite3/src/hook/asset_hashes.dart' as pinned;

/// Independent crash workers need their own DLL so Dart's hook runner never
/// rewrites a library loaded by the test VM. Reuse the pinned bytes already
/// prepared for this test invocation instead of downloading them again inside
/// the worker's startup deadline. This remains the real SQLCipher build.
Future<File> copyPinnedWindowsProbeSqlcipher(Directory probe) async {
  if (!Platform.isWindows) throw StateError('Windows SQLCipher probe required');
  final source = File('.dart_tool/lib/sqlcipher.dll');
  final bytes = await source.readAsBytes();
  final expected = pinned.assetNameToSha256Hash['sqlcipher.x64.windows.dll'];
  if (expected == null || crypto.sha256.convert(bytes).toString() != expected) {
    throw StateError('Probe SQLCipher differs from the locked native asset');
  }
  final copy = await File('${probe.path}/sqlcipher.dll')
      .create(exclusive: true);
  await copy.writeAsBytes(bytes, flush: true);
  return copy;
}
