import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  final native = WindowsInformationDeliveryFiles();
  final data = Uint8List.fromList([
    0,
    255,
    ...utf8.encode('SYNTHETIC-ORDINARY-DELIVERY'),
  ]);
  test(
    'protected native file accepts an ordinary concurrent reader and defers occupied cleanup',
    () async {
      final lease = await native.reserve('attachment.pdf');
      addTearDown(() => native.cleanup(lease));
      await native.write(lease, data);
      await native.verify(lease, data.length, sha256.convert(data).toString());
      final reading = await File(lease.filePath).open();
      try {
        await native.verify(
          lease,
          data.length,
          sha256.convert(data).toString(),
        );
        expect(await reading.read(data.length), data);
        await expectLater(
          native.cleanup(lease),
          throwsA(
            isA<RuntimeMaterialFailure>().having(
              (e) => e.code,
              'code',
              'cleanup_failed',
            ),
          ),
        );
        expect(await File(lease.filePath).exists(), isTrue);
      } finally {
        await reading.close();
      }
      await native.cleanup(lease);
      expect(await Directory(lease.path).exists(), isFalse);
    },
    skip: !Platform.isWindows,
  );
  test(
    'native safe basenames reject traversal and changed file content fails integrity verification',
    () async {
      for (final name in [
        '../resume.pdf',
        'attachment../x',
        'attachment.pdf:stream',
        'resume.pdf',
        'attachment.PDF',
      ]) {
        await expectLater(
          native.reserve(name),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
      }
      final lease = await native.reserve('attachment.docx');
      addTearDown(() => native.cleanup(lease));
      await native.write(lease, data);
      await File(lease.filePath).writeAsBytes(List.filled(data.length, 31));
      await expectLater(
        native.verify(lease, data.length, sha256.convert(data).toString()),
        throwsA(
          isA<RuntimeMaterialFailure>().having(
            (e) => e.code,
            'code',
            'integrity_failed',
          ),
        ),
      );
      await expectLater(
        native.write(lease, data),
        throwsA(isA<RuntimeMaterialFailure>()),
      );
    },
    skip: !Platform.isWindows,
  );
  test(
    'native empty original is a protected existing file with the empty digest',
    () async {
      final lease = await native.reserve('attachment.bin');
      addTearDown(() => native.cleanup(lease));
      await native.write(lease, Uint8List(0));
      await native.verify(lease, 0, sha256.convert(const <int>[]).toString());
      expect(await File(lease.filePath).length(), 0);
      expect(lease.toString(), isNot(contains(lease.path)));
    },
    skip: !Platform.isWindows,
  );
}
