import 'dart:convert';
import 'dart:io';
import 'package:info_storage/macos_backup_publication.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory root, staging, target;
  late String source, output;
  final bytes = utf8.encode('synthetic recovery material\n');
  Matcher failure([String? code]) => throwsA(
    isA<BackupPublicationFailure>().having(
      (e) => e.code,
      'code',
      code == null ? isNotEmpty : equals(code),
    ),
  );
  MacBackupPublication prepare() {
    MacBackupPublicationFiles.writeRecoveryKey(source, bytes);
    return MacBackupPublicationFiles.prepare(source, output);
  }

  group('native macOS retained-inode publication', () {
    setUp(() async {
      final temp = await Directory.systemTemp.createTemp(
        'mac-backup-publication-',
      );
      root = Directory(temp.resolveSymbolicLinksSync());
      staging = await root.createTemp('staging-');
      target = await root.createTemp('target-');
      source = '${staging.path}/prepared';
      output = '${target.path}/恢复 密钥.txt';
    });
    tearDown(() async => root.delete(recursive: true));

    test(
      'private file, durable identity round-trip, publish and cleanup leave owner output',
      () {
        final value = prepare();
        expect(File(source).statSync().mode & 0x1ff, 0x180);
        expect(File(source).readAsBytesSync(), bytes);
        expect(value.toString(), isNot(contains(source)));
        expect(
          jsonEncode(value.toPrivateJson()),
          isNot(contains(utf8.decode(bytes).trim())),
        );
        final reopened = MacBackupPublication.fromPrivateJson(
          jsonDecode(jsonEncode(value.toPrivateJson())) as Map<String, dynamic>,
        );
        expect(
          MacBackupPublicationFiles.observe(reopened),
          BackupPublicationObservation.absent,
        );
        MacBackupPublicationFiles.publish(reopened);
        expect(FileSystemEntity.identicalSync(source, output), isTrue);
        expect(
          MacBackupPublicationFiles.observe(reopened),
          BackupPublicationObservation.matching,
        );
        MacBackupPublicationFiles.cleanup(reopened);
        MacBackupPublicationFiles.cleanup(reopened);
        expect(File(source).existsSync(), isFalse);
        expect(File(output).readAsBytesSync(), bytes);
        expect(File(output).statSync().mode & 0x1ff, 0x180);
      },
    );

    test(
      'identical pre-existing bytes are not evidence of this operation and cannot be replaced',
      () {
        final value = prepare();
        File(output).writeAsBytesSync(bytes);
        expect(
          () => MacBackupPublicationFiles.publish(value),
          failure('publish_failed'),
        );
        expect(
          MacBackupPublicationFiles.observe(value),
          BackupPublicationObservation.different,
        );
        expect(FileSystemEntity.identicalSync(source, output), isFalse);
        MacBackupPublicationFiles.cleanup(value);
        expect(File('$source.publish').existsSync(), isFalse);
        expect(File(output).readAsBytesSync(), bytes);
      },
    );

    test(
      'a repeated publish cannot overwrite; original successful identity remains observable',
      () {
        final value = prepare();
        MacBackupPublicationFiles.publish(value);
        expect(
          () => MacBackupPublicationFiles.publish(value),
          failure('publish_failed'),
        );
        expect(
          MacBackupPublicationFiles.observe(value),
          BackupPublicationObservation.matching,
        );
        MacBackupPublicationFiles.cleanup(value);
        expect(File(output).readAsBytesSync(), bytes);
      },
    );

    test(
      'changed prepared bytes refuse publication even with unchanged inode',
      () {
        final value = prepare();
        File(source).writeAsStringSync('changed', flush: true);
        expect(
          () => MacBackupPublicationFiles.publish(value),
          failure('prepared_file_changed'),
        );
        expect(File(output).existsSync(), isFalse);
        expect(
          () => MacBackupPublicationFiles.observe(value),
          failure('prepared_file_changed'),
        );
      },
    );

    test(
      'replacement source with identical bytes is neither published nor deleted',
      () {
        final value = prepare();
        File(source).renameSync('$source.original');
        MacBackupPublicationFiles.writeRecoveryKey(source, bytes);
        expect(
          () => MacBackupPublicationFiles.publish(value),
          failure('prepared_file_changed'),
        );
        expect(
          () => MacBackupPublicationFiles.cleanup(value),
          failure('identity_changed'),
        );
        expect(File(source).readAsBytesSync(), bytes);
        expect(File(output).existsSync(), isFalse);
      },
    );

    test('replacement directory identities reject publication and cleanup', () {
      final value = prepare();
      staging.renameSync('${staging.path}.original');
      Directory(staging.path).createSync();
      Process.runSync('/bin/chmod', ['700', staging.path]);
      MacBackupPublicationFiles.writeRecoveryKey(source, bytes);
      expect(
        () => MacBackupPublicationFiles.publish(value),
        failure('identity_changed'),
      );
      expect(
        () => MacBackupPublicationFiles.cleanup(value),
        failure('identity_changed'),
      );
      expect(File(source).readAsBytesSync(), bytes);
    });

    test(
      'destination directory replacement rejects publication and never receives material',
      () {
        final value = prepare();
        target.renameSync('${target.path}.original');
        Directory(target.path).createSync();
        expect(
          () => MacBackupPublicationFiles.publish(value),
          failure('identity_changed'),
        );
        expect(File(output).existsSync(), isFalse);
        MacBackupPublicationFiles.cleanup(value);
      },
    );

    test(
      'symlink source and existing symlink destination are never followed',
      () {
        final value = prepare();
        final other = '${root.path}/unrelated';
        File(other).writeAsStringSync('owner file');
        Link(output).createSync(other);
        expect(
          () => MacBackupPublicationFiles.publish(value),
          failure('publish_failed'),
        );
        expect(
          () => MacBackupPublicationFiles.observe(value),
          failure('file_unavailable'),
        );
        MacBackupPublicationFiles.cleanup(value);
        expect(File(other).readAsStringSync(), 'owner file');
        Link(source).createSync(other);
        expect(
          () => MacBackupPublicationFiles.prepare(source, output),
          failure('file_unavailable'),
        );
      },
    );

    test(
      'unknown staging publication name makes cleanup fail without deleting prepared anchor',
      () {
        final value = prepare();
        File('$source.publish').writeAsStringSync('unrelated');
        expect(
          () => MacBackupPublicationFiles.publish(value),
          failure('link_failed'),
        );
        expect(
          () => MacBackupPublicationFiles.cleanup(value),
          failure('identity_changed'),
        );
        expect(File(source).readAsBytesSync(), bytes);
        expect(File('$source.publish').readAsStringSync(), 'unrelated');
      },
    );

    test(
      'deletion or replacement after publication is observable, never replayed',
      () {
        final value = prepare();
        MacBackupPublicationFiles.publish(value);
        File(output).deleteSync();
        expect(
          MacBackupPublicationFiles.observe(value),
          BackupPublicationObservation.absent,
        );
        expect(File(output).existsSync(), isFalse);
        File(output).writeAsStringSync('owner replacement');
        expect(
          MacBackupPublicationFiles.observe(value),
          BackupPublicationObservation.different,
        );
        MacBackupPublicationFiles.cleanup(value);
        expect(File(output).readAsStringSync(), 'owner replacement');
      },
    );

    test(
      'non-private staging, inherited ACL and symlink parent are refused',
      () {
        Process.runSync('/bin/chmod', ['755', staging.path]);
        expect(() => prepare(), failure('identity_changed'));
        Process.runSync('/bin/chmod', ['700', staging.path]);
        final acl = Process.runSync('/bin/chmod', [
          '+a',
          'everyone allow read',
          staging.path,
        ]);
        expect(acl.exitCode, 0);
        expect(() => prepare(), failure('permissions'));
        Process.runSync('/bin/chmod', ['-N', staging.path]);
        final link = '${root.path}/linked';
        Link(link).createSync(staging.path);
        expect(
          () => MacBackupPublicationFiles.writeRecoveryKey('$link/file', bytes),
          failure('identity_changed'),
        );
      },
    );

    test('invalid journal data and file types fail without side effects', () {
      final value = prepare();
      for (final bad in <Map<String, dynamic>>[
        {...value.toPrivateJson(), 'bytes': -1},
        {...value.toPrivateJson(), 'digest': 'bad'},
        {...value.toPrivateJson(), 'source': 'relative'},
        {...value.toPrivateJson(), 'sourceIdentity': 'guess'},
        {...value.toPrivateJson(), 'destination': source},
        {...value.toPrivateJson(), 'destination': '$source.publish'},
        {...value.toPrivateJson(), 'extra': 1},
      ]) {
        expect(() => MacBackupPublication.fromPrivateJson(bad), failure());
      }
      expect(
        () => MacBackupPublicationFiles.writeRecoveryKey(source, bytes),
        failure('file_unavailable'),
      );
      expect(
        () => MacBackupPublicationFiles.writeRecoveryKey(
          '${staging.path}/oversize',
          List.filled(257, 1),
        ),
        failure('invalid_recovery_key'),
      );
      final fifo = '${staging.path}/pipe';
      expect(Process.runSync('/usr/bin/mkfifo', [fifo]).exitCode, 0);
      expect(
        () => MacBackupPublicationFiles.prepare(fifo, output),
        failure('identity_changed'),
      );
      expect(File(output).existsSync(), isFalse);
    });

    test('a prepared source with pre-existing hard links is rejected', () {
      MacBackupPublicationFiles.writeRecoveryKey(source, bytes);
      expect(Process.runSync('/bin/ln', [source, output]).exitCode, 0);
      expect(
        () => MacBackupPublicationFiles.prepare(source, output),
        failure('identity_changed'),
      );
      expect(File(output).readAsBytesSync(), bytes);
    });

    test(
      'prepared recovery-key permissions cannot become broader before publication',
      () {
        final value = prepare();
        expect(Process.runSync('/bin/chmod', ['644', source]).exitCode, 0);
        expect(
          () => MacBackupPublicationFiles.publish(value),
          failure('prepared_file_changed'),
        );
        expect(File(output).existsSync(), isFalse);
        expect(Process.runSync('/bin/chmod', ['600', source]).exitCode, 0);
        MacBackupPublicationFiles.publish(value);
        expect(File(output).statSync().mode & 0x1ff, 0x180);
        MacBackupPublicationFiles.cleanup(value);
      },
    );
    test(
      'independent process reconciles published inode without rewriting output',
      () async {
        final fixture = File(
          'test/fixtures/macos_backup_publication_process.dart',
        ).absolute.path;
        final packages = File('.dart_tool/package_config.json').absolute.path;
        Future<ProcessResult> run(String action) => Process.run(
          Platform.resolvedExecutable,
          ['--packages=$packages', fixture, action, staging.path, target.path],
        );
        final writer = await run('publish');
        expect(writer.exitCode, 0, reason: '${writer.stderr}');
        expect(writer.stdout.toString().trim(), 'published');
        final result = File('${target.path}/result.txt');
        final before = result.statSync();
        final reader = await run('reconcile');
        expect(reader.exitCode, 0, reason: '${reader.stderr}');
        expect(reader.stdout.toString().trim(), 'reconciled');
        expect(result.statSync().modified, before.modified);
        expect(result.readAsStringSync(), 'synthetic process fixture');
        expect(File('${staging.path}/material').existsSync(), isFalse);
      },
    );

    test(
      'real encrypted export remains independently restorable after anchor cleanup and source close',
      () async {
        final repo = await EncryptedInformationRepository.open(
          '${root.path}/library',
          TestKeyStore(),
        );
        final service = InformationService(repository: repo);
        late String recovery;
        try {
          await service.owner.createInformation('合成记录', '', [
            const FieldInput('字段', '', 'synthetic content'),
          ]);
          recovery = await repo.backups.enable();
          await repo.backups.saveRecoveryKeyTo('${root.path}/test-key.txt');
          await service.owner.exportLibrary(
            () => repo.backups.exportTo(source),
          );
          final value = MacBackupPublicationFiles.prepare(source, output);
          MacBackupPublicationFiles.publish(value);
          expect(
            MacBackupPublicationFiles.observe(value),
            BackupPublicationObservation.matching,
          );
          MacBackupPublicationFiles.cleanup(value);
        } finally {
          await service.close();
          await repo.close();
        }
        final restored = await EncryptedInformationRepository.open(
          '${root.path}/restored',
          TestKeyStore(),
        );
        final owner = InformationService(repository: restored);
        try {
          final preview = await restored.backups.inspect(output, recovery);
          expect(preview.informationCount, 1);
          await owner.owner.restoreLibrary(
            () => restored.backups.restore(preview),
          );
          expect(owner.owner.information.single.name, '合成记录');
          expect(
            owner.owner.information.single.fields.single.value,
            'synthetic content',
          );
        } finally {
          await owner.close();
          await restored.close();
        }
      },
    );
  }, skip: !Platform.isMacOS);
}
