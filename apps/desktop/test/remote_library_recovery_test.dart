@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/classification_controller.dart';
import 'package:info_desktop/workspace/library_move_controller.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  test(
    'lost classification and move replies reconcile original receipts without resubmitting',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp(
          'chiyo-library-response-loss-',
        );
        await initializeServerSecrets('${root.path}/secrets');
        final fixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(fixture.ca);
        final token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        final repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        final runtime = await core.OnlineInformationRuntime.open(
          repository: repo,
        );
        const serverId = 'library-response-loss-synthetic';
        final server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: serverId,
        );
        final direct = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
        final upstream = HttpClient(context: trust);
        final proxy = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          tls,
        );
        var decisions = 0, failReceipts = false;
        proxy.listen((request) async {
          try {
            if (failReceipts &&
                (request.uri.path.contains('/classification/operations/') ||
                    request.uri.path.contains('/library/operations/'))) {
              request.response.statusCode = 503;
              request.response.headers.set('x-chiyo-server-id', serverId);
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({'error': 'server_unavailable'}),
              );
              await request.response.close();
              return;
            }
            final next = await upstream.openUrl(
              request.method,
              direct.address.resolve(request.uri.path),
            );
            for (final key in [
              'authorization',
              'content-type',
              'x-chiyo-server-id',
            ]) {
              final value = request.headers.value(key);
              if (value != null) next.headers.set(key, value);
            }
            await next.addStream(request);
            final response = await next.close();
            final bytes = await response.fold<List<int>>(
              [],
              (a, b) => a..addAll(b),
            );
            if ((request.uri.path == '/v1/owner/classification/changes' ||
                request.uri.path == '/v1/owner/library/moves')) {
              decisions++;
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.destroy();
              return;
            }
            request.response.statusCode = response.statusCode;
            request.response.headers.set(
              'x-chiyo-server-id',
              response.headers.value('x-chiyo-server-id')!,
            );
            request.response.headers.contentType = ContentType.json;
            request.response.add(bytes);
            await request.response.close();
          } on Object {
            try {
              request.response.statusCode = 503;
              await request.response.close();
            } on Object {
              /* disconnected */
            }
          }
        });
        OwnerClient? owner;
        RemoteWorkspaceSource? source;
        ClassificationEditController? classification;
        LibraryMoveController? move;
        try {
          final saved = await direct.request(
            'POST',
            '/v1/owner/saves/synthetic',
            {
              'name': 'Synthetic record',
              'description': '',
              'fields': [
                {
                  'name': 'Body',
                  'description': '',
                  'text': 'PRIVATE_SYNTHETIC_BODY',
                },
              ],
            },
          );
          final id = saved['itemId'] as String;
          owner = await OwnerClient.connect(
            address: Uri.parse('https://127.0.0.1:${proxy.port}'),
            token: token,
            trust: trust,
          );
          source = RemoteWorkspaceSource(owner);
          classification = ClassificationEditController(
            source,
            await source.loadCatalog(),
            kind: WorkspaceClassificationKind.directory,
            action: 'create',
            initialName: 'Synthetic target',
          );
          await classification.save();
          expect(classification.uncertain, true);
          expect(classification.frozen, true);
          expect(decisions, 1);
          expect(runtime.service.owner.directories, hasLength(1));
          await classification.save();
          expect(decisions, 1);
          failReceipts = true;
          await classification.reconcile();
          expect(classification.uncertain, true);
          expect(classification.frozen, true);
          await classification.save();
          expect(decisions, 1);
          failReceipts = false;
          await classification.reconcile();
          expect(classification.uncertain, false);
          expect(classification.receipt, isNotNull);
          final target = classification.receipt!.targetId;
          move = LibraryMoveController(
            source,
            WorkspaceLibrarySelection(
              records: [
                WorkspaceRecordRef(WorkspaceRecordKind.information, id),
              ],
            ),
            targetId: target,
          );
          await move.load();
          expect(move.canSave, true);
          await move.save();
          expect(move.uncertain, true);
          expect(move.frozen, true);
          expect(decisions, 2);
          expect((await direct.information()).single.directoryId, target);
          await move.save();
          expect(decisions, 2);
          failReceipts = true;
          await move.reconcile();
          expect(move.uncertain, true);
          expect(move.frozen, true);
          await move.save();
          expect(decisions, 2);
          failReceipts = false;
          await move.reconcile();
          expect(move.receipt, isNotNull);
          expect(move.uncertain, false);
          expect(move.canSave, false);
          expect(decisions, 2);
          expect((await direct.information()).single.directoryId, target);
          expect(runtime.service.owner.directories, hasLength(1));
          expect(
            (await direct.information()).single.fields.single.value,
            'PRIVATE_SYNTHETIC_BODY',
          );
        } finally {
          move?.dispose();
          classification?.dispose();
          await source?.dispose();
          owner?.close();
          direct.close();
          upstream.close(force: true);
          await proxy.close(force: true);
          await server.close();
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        }
      }, _RealHttp());
    },
  );
}
