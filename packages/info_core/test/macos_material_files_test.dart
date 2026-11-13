import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  group('Darwin managed material files', () {
    test(
      'program slots use private fixed names and reject out-of-range or arbitrary paths',
      () async {
        var lease = ManagedCredentialFiles.create();
        addTearDown(() => ManagedCredentialFiles.cleanup(lease));
        for (final name in [
          'credential-b0.bin',
          'credential-b21.bin',
          '../credential-b1.bin',
          'credential-unknown.bin',
        ]) {
          expect(
            () => ManagedCredentialFiles.reserve(lease, [name]),
            throwsA(isA<RuntimeMaterialFailure>()),
          );
        }
        lease = ManagedCredentialFiles.reserve(lease, [
          'credential-b1.bin',
          'credential-b20.bin',
        ]);
        ManagedCredentialFiles.write(lease, 'credential-b1.bin', [1, 0, 255]);
        ManagedCredentialFiles.verify(lease);
        expect(await File('${lease.path}/credential-b1.bin').readAsBytes(), [
          1,
          0,
          255,
        ]);
        expect(
          FileStat.statSync('${lease.path}/credential-b20.bin').mode & 0x1ff,
          0x180,
        );
      },
    );

    test(
      'owner-only files retain identity and allow only the first body write',
      () async {
        var lease = ManagedCredentialFiles.create();
        addTearDown(() => ManagedCredentialFiles.cleanup(lease));
        expect(FileStat.statSync(lease.path).mode & 0x1ff, 0x1c0);
        lease = ManagedCredentialFiles.reserve(lease, [
          'credential.bin',
          'aws-config',
        ]);
        final path = '${lease.path}/credential.bin';
        expect(FileStat.statSync(path).mode & 0x1ff, 0x180);
        ManagedCredentialFiles.write(lease, 'credential.bin', [0, 255, 10]);
        ManagedCredentialFiles.verify(lease);
        expect(await File(path).readAsBytes(), [0, 255, 10]);
        expect(
          () => ManagedCredentialFiles.write(lease, 'credential.bin', [3]),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        // A prior partial cleanup is retryable without replacing missing objects.
        await File('${lease.path}/aws-config').delete();
        ManagedCredentialFiles.cleanup(lease);
        ManagedCredentialFiles.cleanup(lease);
        expect(await Directory(lease.path).exists(), isFalse);
      },
    );

    test(
      'symlink substitution never writes or deletes an outside file',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'macos-material-test-',
        );
        addTearDown(() => root.delete(recursive: true));
        final outside = File('${root.path}/original')
          ..writeAsStringSync('SYNTHETIC');
        var lease = ManagedCredentialFiles.create();
        lease = ManagedCredentialFiles.reserve(lease, ['credential.bin']);
        final path = '${lease.path}/credential.bin';
        await File(path).delete();
        await Link(path).create(outside.path);
        expect(
          () => ManagedCredentialFiles.write(lease, 'credential.bin', [1]),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(
          () => ManagedCredentialFiles.verify(lease),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(
          () => ManagedCredentialFiles.cleanup(lease),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(await outside.readAsString(), 'SYNTHETIC');
        await Link(path).delete();
        ManagedCredentialFiles.cleanup(lease);
      },
    );

    test(
      'hard links, changed permissions and unknown children stop cleanup',
      () async {
        var lease = ManagedCredentialFiles.create();
        lease = ManagedCredentialFiles.reserve(lease, ['credential.bin']);
        final root = await Directory.systemTemp.createTemp(
          'macos-material-link-',
        );
        addTearDown(() => root.delete(recursive: true));
        final file = '${lease.path}/credential.bin';
        final link = '${root.path}/hardlink';
        expect((await Process.run('/bin/ln', [file, link])).exitCode, 0);
        expect(
          () => ManagedCredentialFiles.verify(lease),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(
          () => ManagedCredentialFiles.cleanup(lease),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        await File(link).delete();
        expect((await Process.run('/bin/chmod', ['644', file])).exitCode, 0);
        expect(
          () => ManagedCredentialFiles.verify(lease),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect((await Process.run('/bin/chmod', ['600', file])).exitCode, 0);
        final unknown = File('${lease.path}/unexpected')
          ..writeAsStringSync('SYNTHETIC');
        expect(
          () => ManagedCredentialFiles.cleanup(lease),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(await unknown.exists(), isTrue);
        await unknown.delete();
        ManagedCredentialFiles.cleanup(lease);
      },
    );

    test(
      'directory substitution retains both original and replacement',
      () async {
        final lease = ManagedCredentialFiles.create();
        final original = await Directory(
          lease.path,
        ).rename('${lease.path}-original');
        await Directory(lease.path).create();
        await Process.run('/bin/chmod', ['700', lease.path]);
        expect(
          () => ManagedCredentialFiles.reserve(lease, ['credential.bin']),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(
          () => ManagedCredentialFiles.cleanup(lease),
          throwsA(isA<RuntimeMaterialFailure>()),
        );
        expect(await original.exists(), isTrue);
        expect(await Directory(lease.path).exists(), isTrue);
        await Directory(lease.path).delete();
        await original.rename(lease.path);
        ManagedCredentialFiles.cleanup(lease);
      },
    );

    test(
      'extended access rules are refused even when mode remains 0600',
      () async {
        var lease = ManagedCredentialFiles.create();
        lease = ManagedCredentialFiles.reserve(lease, ['credential.bin']);
        final path = '${lease.path}/credential.bin';
        try {
          expect(
            (await Process.run('/bin/chmod', [
              '+a',
              'everyone allow read',
              path,
            ])).exitCode,
            0,
          );
          expect(FileStat.statSync(path).mode & 0x1ff, 0x180);
          expect(
            () => ManagedCredentialFiles.write(lease, 'credential.bin', [1]),
            throwsA(isA<RuntimeMaterialFailure>()),
          );
          expect(
            () => ManagedCredentialFiles.cleanup(lease),
            throwsA(isA<RuntimeMaterialFailure>()),
          );
        } finally {
          await Process.run('/bin/chmod', ['-N', path]);
          ManagedCredentialFiles.cleanup(lease);
        }
      },
    );

    test(
      'unlink removes the managed name while an existing reader keeps its bytes',
      () async {
        var lease = ManagedCredentialFiles.create();
        lease = ManagedCredentialFiles.reserve(lease, ['credential.bin']);
        ManagedCredentialFiles.write(lease, 'credential.bin', [1, 2, 3]);
        final reader = await File('${lease.path}/credential.bin').open();
        try {
          ManagedCredentialFiles.cleanup(lease);
          expect(await Directory(lease.path).exists(), isFalse);
          expect(await reader.read(3), [1, 2, 3]);
        } finally {
          await reader.close();
        }
      },
    );
  }, skip: !Platform.isMacOS);
}
