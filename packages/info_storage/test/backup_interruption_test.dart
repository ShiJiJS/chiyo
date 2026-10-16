import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  test(
    'interrupted recipient process rolls back restore without losing original settings',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'backup-interruption-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
      );
      final owner = InformationService(repository: source).owner;
      for (var index = 0; index < 50; index++) {
        await owner.createInformation('Fictional $index', '', [
          for (var field = 0; field < 200; field++)
            FieldInput(
              'Field $field',
              '',
              'fictional restore content $index $field',
            ),
        ]);
      }
      await owner.setRequestLifetime(const Duration(minutes: 45));
      final key = await source.backups.enable();
      final backup = '${root.path}/many.aimbackup';
      await source.backups.exportTo(backup);
      await source.close();
      final targetPath = '${root.path}/recipient';
      final keys = WindowsDatabaseKeyStore('$targetPath/key.dpapi');
      var recipient = await EncryptedInformationRepository.open(
        targetPath,
        keys,
      );
      await InformationService(
        repository: recipient,
      ).owner.setRequestLifetime(const Duration(minutes: 15));
      await recipient.close();
      // A separate package also gives the child its own native-asset directory;
      // Windows cannot re-bundle a DLL already loaded by this test process.
      final probe = await Directory('${root.path}/probe').create();
      final sourcePackage = Directory.current.absolute.path;
      await File('${probe.path}/pubspec.yaml').writeAsString(
        'name: backup_restore_probe\npublish_to: none\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  info_storage:\n    path: ${jsonEncode(sourcePackage)}\nhooks:\n  user_defines:\n    sqlite3:\n      source: sqlcipher\n',
      );
      await File(
        'test/fixtures/restore_child.dart',
      ).copy('${probe.path}/restore_child.dart');
      final resolution = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: probe.path);
      expect(
        resolution.exitCode,
        0,
        reason: 'Independent offline probe dependencies must resolve.',
      );
      final child = await Process.start(Platform.resolvedExecutable, [
        'run',
        'restore_child.dart',
      ], workingDirectory: probe.path);
      var running = true;
      addTearDown(() {
        if (running) child.kill();
      });
      final ready = Completer<int>();
      var finished = false;
      final output = child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final started = RegExp(r'backup_ready:(\d+)$').firstMatch(line);
            if (started != null && !ready.isCompleted)
              ready.complete(int.parse(started.group(1)!));
            if (line.contains('backup_failed:') && !ready.isCompleted)
              ready.completeError(
                StateError(line.substring(line.indexOf('backup_failed:'))),
              );
            if (line == 'backup_restored' || line == 'backup_failed')
              finished = true;
          });
      final errors = child.stderr.transform(utf8.decoder).join();
      child.exitCode.then((code) async {
        if (!ready.isCompleted)
          ready.completeError(
            StateError('Backup fixture startup failed ($code).'),
          );
      });
      child.stdin.writeln(
        jsonEncode({'directory': targetPath, 'backup': backup, 'key': key}),
      );
      await child.stdin.close();
      final probePid = await ready.future.timeout(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        finished,
        isFalse,
        reason: 'The restore must still be in progress before interruption.',
      );
      // Dart CLI may have a launcher process. Interrupt only this fixture's
      // own reported VM process, not another application or desktop process.
      expect(Process.killPid(probePid, ProcessSignal.sigkill), isTrue);
      await child.exitCode;
      running = false;
      await output.cancel();
      final diagnostics = await errors;
      expect(diagnostics.contains(key), isFalse);
      recipient = await EncryptedInformationRepository.open(targetPath, keys);
      final restoredOwner = InformationService(repository: recipient).owner;
      expect(restoredOwner.information, isEmpty);
      expect(restoredOwner.requestLifetime, const Duration(minutes: 15));
      await recipient.backups.restoreFrom(backup, key);
      expect(restoredOwner.information.length, 50);
      expect(restoredOwner.information.last.fields.length, 200);
      expect(restoredOwner.requestLifetime, const Duration(minutes: 45));
      await recipient.close();
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
