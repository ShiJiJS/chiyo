import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

final class _Hash implements Sink<crypto.Digest> {
  String? result;
  @override
  void add(crypto.Digest digest) => result = digest.toString();
  @override
  void close() {}
}

/// Isolated synthetic benchmark; no user vault, key, directory or Agent grant.
Future<void> main(List<String> args) async {
  final textMiB = args.length == 1 && args.single.startsWith('--text-mib=')
      ? int.tryParse(args.single.substring(11))
      : null;
  if (textMiB != 0 && textMiB != 48)
    throw ArgumentError('Choose --text-mib=0 or --text-mib=48');
  final root = await Directory.systemTemp.createTemp(
    'attachment-backup8-measure-',
  );
  final path = '${root.path}/synthetic.aimbackup';
  final baseline = ProcessInfo.currentRss;
  final key = 'aim-recovery-v1:${base64Url.encode(List<int>.filled(32, 43))}';
  final chunk = Uint8List(AttachmentBackupContainer.chunkBytes);
  final digest = _Hash();
  final sink = crypto.sha256.startChunkedConversion(digest);
  for (var i = 0; i < 10; i++) {
    sink.add(chunk);
  }
  sink.close();
  var reads = 0, maxRead = 0;
  final sources = [
    for (var i = 0; i < 10; i++)
      AttachmentBackupSource(
        InformationAttachmentVersion(
          reference: InformationAttachmentRef('synthetic-$i', 1),
          originalName: 'synthetic-$i.bin',
          mediaType: 'application/octet-stream',
          byteLength: informationFileByteLimit,
          sha256: digest.result!,
          createdAt: DateTime.utc(2026, 10, 19),
        ),
        read: (offset, length) async {
          if (length > chunk.length || offset % chunk.length != 0)
            throw StateError('Unbounded source read');
          reads++;
          if (length > maxRead) maxRead = length;
          return Uint8List.sublistView(chunk, 0, length);
        },
      ),
  ];
  final text = 'x' * (textMiB! * 1024 * 1024);
  final timer = Stopwatch()..start();
  var readBytes = 0, allZero = true;
  AttachmentBackupReader? reader;
  var cleanup = false;
  late Map<String, Object?> result;
  try {
    final probe = sqlite.sqlite3.openInMemory();
    final cipher = probe.select('PRAGMA cipher_version').single.values.single;
    probe.close();
    await AttachmentBackupContainer.write(
      path: path,
      recoveryKey: key,
      createdAt: DateTime.utc(2026, 10, 19),
      tables: {
        'synthetic_records': [
          {'text': text},
        ],
      },
      attachments: sources,
    );
    final exportMs = timer.elapsedMilliseconds;
    reader = await AttachmentBackupContainer.openValidated(path, key);
    for (final file in reader.versions) {
      var fileBytes = 0;
      await for (final bytes in reader.readAttachment(file.reference)) {
        fileBytes += bytes.length;
        allZero = allZero && bytes.every((b) => b == 0);
      }
      if (fileBytes != informationFileByteLimit)
        throw StateError('Incomplete synthetic file');
      readBytes += fileBytes;
    }
    if (readBytes != AttachmentBackupContainer.maxRetainedBytes ||
        !allZero ||
        reads != 100) {
      throw StateError('Incomplete synthetic backup');
    }
    result = {
      'execution': 'dart run (JIT), isolated synthetic codec only',
      'dart': Platform.version.split('\n').first,
      'sqlCipher': cipher,
      'textBytes': text.length,
      'attachmentBytes': readBytes,
      'fileCount': reader.versions.length,
      'sourceReads': reads,
      'maxSourceRead': maxRead,
      'backupFileBytes': await File(path).length(),
      'baselineRss': baseline,
      'currentRss': ProcessInfo.currentRss,
      'maxRss': ProcessInfo.maxRss,
      'exportAndSelfVerifyMs': exportMs,
      'totalMs': timer.elapsedMilliseconds,
      'everyByteZero': allZero,
    };
  } finally {
    reader?.close();
    if (await File(path).exists()) await File(path).delete();
    await root.delete(); // empty owned directory only
    cleanup = !await root.exists();
  }
  stdout.writeln(jsonEncode({...result, 'temporaryOutputRemoved': cleanup}));
}
