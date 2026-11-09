import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List<int>.filled(32, 61);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Fixed synthetic key');
}

void main() {
  test(
    'actual worker death after verified copy leaves durable identity and restart cleans without replay',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'delivery-worker-crash-',
      );
      addTearDown(() => root.delete(recursive: true));
      final probe = await Directory('${root.path}/probe').create();
      final storage = Directory.current.absolute.path;
      final core = Directory('../info_core').absolute.path;
      await File('${probe.path}/pubspec.yaml').writeAsString(
        'name: delivery_crash_probe\npublish_to: none\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  info_storage:\n    path: ${jsonEncode(storage)}\n  info_core:\n    path: ${jsonEncode(core)}\nhooks:\n  user_defines:\n    sqlite3:\n      source: sqlcipher\n',
      );
      await File(
        'test/fixtures/file_delivery_crash_child.dart',
      ).copy('${probe.path}/worker.dart');
      final sourceLock = (await File(
        'pubspec.lock',
      ).readAsString()).replaceAll('\r\n', '\n');
      final versions = RegExp(
        r'^  (\w+):\n[\s\S]*?    version: "([^"]+)"',
        multiLine: true,
      );
      final matches = versions.allMatches(sourceLock).toList();
      final pinned = {for (final m in matches) m[1]!: m[2]!};
      // A new root package otherwise selects newer cached hook dependencies.
      // Freeze the same hosted versions before resolving, retaining the exact
      // equality assertions below; path dependencies remain the real sources.
      await File('${probe.path}/pubspec.yaml').writeAsString(
        'dependency_overrides:\n${[for (final m in matches)
          if (m[0]!.contains('\n    source: hosted\n')) '  ${m[1]}: ${jsonEncode(m[2])}\n'].join()}',
        mode: FileMode.append,
      );
      final pub = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: probe.path);
      expect(
        pub.exitCode,
        0,
        reason: 'Independent crash probe resolves offline',
      );
      // Keep the resolved lock for inspection while this fixture is alive. All
      // dependency versions must match the production storage package lock.
      final childLock = await File('${probe.path}/pubspec.lock').readAsString();
      for (final m in versions.allMatches(childLock.replaceAll('\r\n', '\n'))) {
        if (m[1] != 'info_storage' && pinned.containsKey(m[1]))
          expect(
            m[2],
            pinned[m[1]],
            reason: 'Probe dependency ${m[1]} must match',
          );
      }
      final child = await Process.start(Platform.resolvedExecutable, [
        'run',
        'worker.dart',
        root.path,
      ], workingDirectory: probe.path);
      int? workerPid;
      var ended = false;
      final prepared = Completer<void>();
      final output = child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final worker = RegExp(r'^delivery_worker:(\d+)$').firstMatch(line);
            if (worker != null) workerPid = int.parse(worker[1]!);
            final ready = RegExp(r'^delivery_prepared:(\d+)$').firstMatch(line);
            if (ready != null && !prepared.isCompleted) {
              expect(int.parse(ready[1]!), workerPid);
              prepared.complete();
            }
          });
      final errors = child.stderr.transform(utf8.decoder).join();
      child.exitCode.then((code) {
        ended = true;
        if (!prepared.isCompleted)
          prepared.completeError(
            StateError('Fixture exited before prepared ($code)'),
          );
      });
      addTearDown(() async {
        if (!ended) {
          if (workerPid != null)
            Process.killPid(workerPid!, ProcessSignal.sigkill);
          child.kill();
          await child.exitCode.timeout(const Duration(seconds: 15));
        }
        await output.cancel();
        await errors;
      });
      await prepared.future.timeout(const Duration(seconds: 60));
      expect(workerPid, isNotNull);
      expect(Process.killPid(workerPid!, ProcessSignal.sigkill), isTrue);
      await child.exitCode.timeout(const Duration(seconds: 15));
      await output.cancel();
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/vault',
        _Keys(),
      );
      final service = InformationService(
        repository: repo,
        informationDeliveryFiles: WindowsInformationDeliveryFiles(),
      );
      addTearDown(() async {
        await service.close();
        await repo.close();
      });
      // Dart's launcher emits these progress messages on stderr. They are not
      // worker diagnostics; still reject every other unexpected byte.
      expect(
        (await errors).replaceAll('Running build hooks...', '').trim(),
        isEmpty,
      );
      final original = repo.informationFileDeliveries.single;
      expect(original.state, 'preparing');
      expect(original.lease, isNotNull);
      final copy = File(original.lease!.filePath);
      expect(await copy.readAsBytes(), [0, 255, 8, 10, 27, 42]);
      expect(await service.owner.reconcileInformationFileDeliveries(), 0);
      final recovered = repo.informationFileDeliveries.single;
      expect(recovered.state, 'unknown');
      expect(recovered.reason, 'restarted');
      expect(recovered.lease, isNull);
      expect(await copy.exists(), isFalse);
      final newSession = service.agent.openSession('New session');
      expect(
        () => service.agent.informationFileOperationStatus(
          newSession,
          'interrupted-original',
        ),
        throwsA(
          isA<InformationFileFailure>().having(
            (e) => e.code,
            'code',
            'delivery_not_found',
          ),
        ),
      );
      expect(
        await repo.readInformationAttachmentChunk(recovered.attachment, 0, 6),
        [0, 255, 8, 10, 27, 42],
      );
      expect(repo.informationFileDeliveries, hasLength(1));
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
