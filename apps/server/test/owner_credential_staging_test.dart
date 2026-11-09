import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_server/owner_credential_routes.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';

void main() {
  test(
    'private credential inputs expire on monotonic time, cancel before a late upload and preserve committed records',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'credential-input-expiry-',
      );
      await initializeServerSecrets('${root.path}/secrets');
      final repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/data',
        MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
      );
      final runtime = await OnlineInformationRuntime.open(repository: repo);
      var elapsed = Duration.zero;
      final routes = OwnerCredentialRoutes(
        runtime.service.owner,
        elapsed: () => elapsed,
      );
      addTearDown(() async {
        routes.dispose();
        await runtime.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      Future<String> upload(String op) => runtime.run(() async {
        final result = await routes.upload({
          'operationId': op,
          'form': 'string',
          'secret': 'SYNTHETIC_$op',
        });
        return (result['candidate'] as Map)['id'] as String;
      });
      final first = await upload('saved');
      final saved = await runtime.run(
        () => routes.source.save(
          WorkspaceCredentialWrite(
            operationId: 'save',
            name: 'Synthetic committed credential',
            candidateId: first,
          ),
        ),
      );
      final pending = [for (var i = 0; i < 16; i++) await upload('input-$i')];
      await expectLater(
        upload('over-limit'),
        throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', 'capacity'),
        ),
      );
      elapsed = const Duration(minutes: 31);
      expect(routes.needsCleanup, true);
      await runtime.run(routes.cleanup);
      for (final id in pending) {
        expect(
          () => routes.source.staging.candidate(id),
          throwsA(
            isA<WorkspaceFailure>().having(
              (e) => e.code,
              'code',
              'selection_expired',
            ),
          ),
        );
      }
      expect(
        (await runtime.run(() => routes.source.read(saved.ref))).record.name,
        'Synthetic committed credential',
      );
      await runtime.run(
        () => routes.dispatch('DELETE', [
          'v1',
          'owner',
          'credentials',
          'inputs',
          'late',
        ], null),
      );
      await expectLater(
        upload('late'),
        throwsA(
          isA<WorkspaceFailure>().having(
            (e) => e.code,
            'code',
            'selection_expired',
          ),
        ),
      );
      final next = await upload('after-expiry');
      final claimed = routes.source.staging.claim(next, 'unfinished');
      routes.dispose();
      expect(claimed.bytes.every((b) => b == 0), true);
      expect(runtime.service.owner.credentials, hasLength(1));
    },
  );
}
