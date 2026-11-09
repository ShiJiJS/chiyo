@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/remote_workspace_credentials.dart';
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
    'lost private input/save responses query their exact operations; unknown outcomes never create a replacement credential',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp(
          'credential-response-loss-',
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
        const serverId = 'credential-response-loss-synthetic';
        final server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: serverId,
        );
        final upstream = HttpClient(context: trust);
        final proxy = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          tls,
        );
        var inputPosts = 0, saves = 0, failLookup = true, dropInput = true;
        proxy.listen((request) async {
          try {
            if (failLookup &&
                request.method == 'GET' &&
                (request.uri.path.contains('/credentials/inputs/') ||
                    request.uri.path.contains('/credentials/operations/'))) {
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
              Uri.parse(
                'https://127.0.0.1:${server.port}',
              ).resolve(request.uri.path),
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
            final input =
                request.method == 'POST' &&
                request.uri.path == '/v1/owner/credentials/inputs';
            final save =
                request.method == 'POST' &&
                request.uri.path == '/v1/owner/credentials/save';
            if (input) inputPosts++;
            if (save) saves++;
            if (input && dropInput || save) {
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.destroy();
              return;
            }
            request.response.statusCode = response.statusCode;
            request.response.headers.contentType = ContentType.json;
            request.response.headers.set('x-chiyo-server-id', serverId);
            request.response.add(bytes);
            await request.response.close();
          } on Object {
            try {
              await request.response.close();
            } on Object {
              /* disconnected */
            }
          }
        });
        final client = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${proxy.port}'),
          token: token,
          trust: trust,
        );
        final source = RemoteWorkspaceCredentials(client, changed: () {});
        Matcher fails(String code) => throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', code),
        );
        try {
          const secret = 'SYNTHETIC_RESPONSE_LOSS_TOKEN';
          await expectLater(source.string(secret), fails('unknown_outcome'));
          expect(inputPosts, 1);
          expect(repo.managedCredentials, isEmpty);
          await expectLater(source.string(secret), fails('unknown_outcome'));
          expect(
            inputPosts,
            1,
          ); // Unknown lookup does not mean no input exists.
          failLookup = false;
          final selected = await source.string(secret);
          expect(inputPosts, 1);
          final write = WorkspaceCredentialWrite(
            operationId: 'save',
            name: 'Synthetic recovered credential',
            candidateId: selected.id,
          );
          await expectLater(source.save(write), fails('unknown_outcome'));
          expect(saves, 1);
          expect(repo.managedCredentials, hasLength(1));
          failLookup = true;
          await expectLater(source.receipt('save'), fails('unknown_outcome'));
          await expectLater(
            source.save(
              WorkspaceCredentialWrite(
                operationId: 'save',
                name: 'Changed intent',
                candidateId: selected.id,
              ),
            ),
            fails('conflict'),
          );
          expect(saves, 1);
          failLookup = false;
          final receipt = await source.receipt('save');
          expect(receipt!.commandDigest, write.commandDigest);
          expect((await source.read(receipt.ref)).record.name, write.name);
          expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
          expect(repo.managedCredentials, hasLength(1));
          // Closing an input before its lost reply is observed cancels that
          // exact upload instead of letting a retry create a new selection.
          await expectLater(
            source.string('SYNTHETIC_CANCELED_INPUT'),
            fails('unknown_outcome'),
          );
          await source.cancelPending();
          dropInput = false;
          final next = await source.string('SYNTHETIC_NEW_INPUT');
          await source.releaseCandidate(next.id);
          expect(repo.managedCredentials, hasLength(1));
        } finally {
          await source.dispose();
          client.close();
          await proxy.close(force: true);
          upstream.close(force: true);
          await server.close();
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        }
      }, _RealHttp());
    },
  );
}
