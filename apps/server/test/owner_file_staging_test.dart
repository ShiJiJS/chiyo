import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/owner_file_routes.dart';
import 'package:info_server/owner_library.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/owner_workspace_template_packages.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'abandoned owner uploads expire, close cancels late uploads, and cleanup preserves other forms',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'owner-upload-cleanup-',
      );
      await initializeServerSecrets('${root.path}/secrets');
      final repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/data',
        MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
      );
      final runtime = await OnlineInformationRuntime.open(repository: repo);
      final plugins = OwnerWorkspaceTemplatePackages(
        owner: runtime.service.owner,
        changed: () {},
      );
      var elapsed = Duration.zero;
      final routes = OwnerFileRoutes(
        OnlineOwnerLibrary(runtime.service.owner, plugins),
        elapsed: () => elapsed,
      );
      addTearDown(() async {
        await routes.dispose();
        plugins.dispose();
        await runtime.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      Future<(int, Object)> request(
        String method,
        String path, [
        Map<String, dynamic>? body,
      ]) => runtime.run(
        () => routes.dispatch(method, [
          'v1',
          'owner',
          'files',
          ...path.split('/'),
        ], body),
      );
      Future<Map<String, dynamic>> upload(String op) async =>
          Map<String, dynamic>.from(
            (await request('POST', 'uploads', {
                  'operationId': op,
                  'originalName': 'synthetic.txt',
                  'mediaType': 'text/plain',
                  'bytes': base64Encode(utf8.encode('SYNTHETIC')),
                })).$2
                as Map,
          );
      await upload('abandoned');
      elapsed += const Duration(minutes: 20);
      final active = fileCandidateFromJson(
        (await upload('active'))['candidate'],
      );
      expect((await repo.informationFileStagingUsage()).files, 2);
      elapsed += const Duration(minutes: 11);
      expect(routes.needsCleanup, isTrue);
      // A real storage deletion failure must retain a retryable cleanup handle.
      final key = (await File(
        '${root.path}/secrets/database.key',
      ).readAsBytes()).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      void sql(String command) {
        final db = sqlite3.open('${root.path}/data/library.db');
        try {
          db.execute('PRAGMA key = "x\'$key\'"');
          db.execute(command);
        } finally {
          db.close();
        }
      }

      sql(
        "CREATE TRIGGER fail_stage_cleanup BEFORE DELETE ON information_file_stages BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
      );
      await expectLater(
        runtime.run(routes.cleanup),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'cleanup_pending',
          ),
        ),
      );
      expect((await repo.informationFileStagingUsage()).files, 2);
      expect(routes.needsCleanup, isTrue);
      sql('DROP TRIGGER fail_stage_cleanup');
      await runtime.run(routes.cleanup);
      expect(routes.needsCleanup, isFalse);
      expect((await repo.informationFileStagingUsage()).files, 1);
      expect((await request('GET', 'uploads/abandoned')).$1, 404);
      expect((await request('GET', 'uploads/active')).$1, 200);
      await request('POST', 'release', {
        'uploads': ['pending-response'],
        'selections': [active.selectionId],
      });
      await expectLater(
        upload('pending-response'),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'selection_expired',
          ),
        ),
      );
      expect((await repo.informationFileStagingUsage()).files, 0);
      expect(runtime.service.owner.information, isEmpty);
      // The bounded retry/cancel registry is reclaimed without restarting a host.
      for (var n = 0; n < 511; n++) {
        await request('DELETE', 'uploads/cancel-$n');
      }
      elapsed += const Duration(minutes: 31);
      await runtime.run(routes.cleanup);
      final next = fileCandidateFromJson(
        (await upload('new-form'))['candidate'],
      );
      expect(next.selectionId, isNot(active.selectionId));
      expect((await repo.informationFileStagingUsage()).files, 1);
      await routes.dispose();
      expect((await repo.informationFileStagingUsage()).files, 0);
    },
  );
}
