import 'package:info_server/agent_devices.dart';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import '../../../apps/server/test/support/tls_fixture.dart';

void main() {
  test(
    'fresh clients preserve typed content and reject another server before writing',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-remote-client-',
      );
      addTearDown(() => root.delete(recursive: true));
      await initializeServerSecrets('${root.path}/secrets');
      final keys = MountedDatabaseKeyStore('${root.path}/secrets/database.key');
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(fixture.ca);
      final token = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      final service = InformationService(repository: repo);
      final server = await OnlineServer.start(
        devices: AgentDeviceRegistry(repo),
        service: service,
        tls: tls,
        ownerToken: token,
        serverId: 'client-test-server-0001',
      );
      final uri = Uri.parse('https://127.0.0.1:${server.port}');
      OwnerClient? client;
      try {
        await expectLater(
          OwnerClient.connect(address: uri, token: 'wrong', trust: trust),
          throwsA(
            isA<RemoteFailure>().having((e) => e.code, 'code', 'unauthorized'),
          ),
        );
        client = await OwnerClient.connect(
          address: uri,
          token: token,
          trust: trust,
        );
        await expectLater(
          client.request('GET', 'https://example.invalid/steal'),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        final draft = InformationDraftInput(
          name: 'Typed fixture',
          description: 'private',
          fields: [
            const InformationDraftField.text(
              'Body',
              '',
              '# 内容',
              kind: FieldKind.textNote,
            ),
          ],
          layout: InformationDraftLayout(
            InformationLayout(
              typeId: 'document',
              snapshot: {'codec': 'fixture', 'format': 'markdown'},
              fieldIds: {},
            ),
            ['body'],
          ),
        );
        final saved = await client.save('client-save', draft);
        client.close();
        client = await OwnerClient.connect(
          address: uri,
          token: token,
          trust: trust,
          expectedServerId: 'client-test-server-0001',
        );
        final fetched = (await client.information()).single;
        expect(fetched.id, saved.itemId);
        expect(fetched.layout!.typeId, 'document');
        expect(fetched.layout!.snapshot['format'], 'markdown');
        expect(fetched.fields.single.kind, FieldKind.textNote);
        expect(fetched.fields.single.value, '# 内容');
        expect(
          (await client.save('client-save', draft)).toJson(),
          saved.toJson(),
        );
        expect((await client.receipt('client-save'))!.toJson(), saved.toJson());
        expect(await client.receipt('never-submitted'), isNull);
        await expectLater(
          OwnerClient.connect(
            address: uri,
            token: token,
            trust: trust,
            expectedServerId: 'some-other-server-0002',
          ),
          throwsA(
            isA<RemoteFailure>().having(
              (e) => e.code,
              'code',
              'server_changed',
            ),
          ),
        );
        expect(service.owner.information, hasLength(1));
        await server.close();
        await expectLater(client.information(), throwsA(isA<RemoteFailure>()));
      } finally {
        client?.close();
        await server.close();
        await service.close();
        await repo.close();
      }
    },
  );
}
