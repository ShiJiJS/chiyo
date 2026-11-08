import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/proposal_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'formal CLI uses current credential templates; only owner private filling allows the whole linked proposal into encrypted storage',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'remote-credential-proposal-',
      );
      await initializeServerSecrets('${root.path}/secrets');
      final fixture = await createTlsFixture(root);
      final tls = SecurityContext()
        ..useCertificateChain(fixture.certificate)
        ..usePrivateKey(fixture.privateKey);
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(fixture.ca);
      final token = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final keys = MountedDatabaseKeyStore('${root.path}/secrets/database.key');
      late EncryptedInformationRepository repo;
      late OnlineInformationRuntime runtime;
      late OnlineServer server;
      late OwnerClient owner;
      Future<void> open([int port = 0]) async {
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          keys,
        );
        runtime = await OnlineInformationRuntime.open(repository: repo);
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: 'synthetic-credential-proposals',
          port: port,
        );
        owner = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
      }

      Future<void> close() async {
        owner.close();
        await server.close();
        await runtime.close();
        await repo.close();
      }

      await open();
      addTearDown(() async {
        await close();
        await root.delete(recursive: true);
      });
      final device = await owner.request('POST', '/v1/owner/devices', {
        'operationId': 'enroll',
        'name': 'Synthetic credential CLI',
      });
      final profile = AgentConnectionProfile(
        address: owner.address,
        deviceToken: device['deviceToken'] as String,
        serverId: owner.serverId,
        certificate: await File(fixture.ca).readAsString(),
      );
      final cli = AgentClient.remote(profile);
      addTearDown(cli.close);
      await cli.openLifecycleSession('Synthetic credential proposal');
      const ownerFirst = 'SYNTHETIC_OWNER_FIRST_PASSWORD',
          ownerSecond = 'SYNTHETIC_OWNER_SECOND_PASSWORD';
      const seen = 'SYNTHETIC_ALREADY_SEEN_PASSWORD',
          apiToken = 'SYNTHETIC_SUBMITTED_API_TOKEN';
      const fileText = 'SYNTHETIC_CLI_CREDENTIAL_FILE';
      Future<Map<String, dynamic>> run(
        String command, [
        Map<String, dynamic> input = const {},
      ]) async {
        final result = await cli.execute({'command': command, ...input});
        for (final value in [
          ownerFirst,
          ownerSecond,
          seen,
          apiToken,
          fileText,
        ]) {
          expect(jsonEncode(result), isNot(contains(value)));
          expect(
            jsonEncode(result),
            isNot(contains(base64Encode(utf8.encode(value)))),
          );
        }
        return result;
      }

      expect(
        (await run('capabilities'))['capabilities'],
        contains('credential-import.v1'),
      );
      final file = File('${root.path}/synthetic.key');
      await file.writeAsString(fileText);
      Future<Map<String, dynamic>> example(String id) async {
        final description =
            (await run('template-read', {'templateId': id}))['template'] as Map;
        final item = Map<String, dynamic>.from(
          ((description['submissionExample'] as Map)['items'] as List).single
              as Map,
        );
        item.remove('relations');
        item.remove('pendingRelations');
        return item;
      }

      final catalog = await run('template-list');
      final serviceTemplate = (catalog['templates'] as List)
          .cast<Map>()
          .firstWhere((t) => t['name'] == '应用与服务');
      final service = {
        ...await example(serviceTemplate['id'] as String),
        'key': 'service',
        'name': 'Synthetic service',
      };
      Future<Map<String, dynamic>> credential(
        String key,
        String kind,
        Map<String, Object?> material,
      ) async => {
        ...await example('credential.$kind'),
        'key': key,
        'name': 'Synthetic $key',
        'credential': material,
        'relations': {
          'related': [
            {'kind': 'information', 'itemKey': 'service'},
          ],
        },
      };
      final items = [
        service,
        await credential('login', 'accountPassword', {
          'source': 'owner',
          'contextExposed': false,
          'account': 'synthetic-user',
        }),
        await credential('second', 'accountPassword', {
          'source': 'owner',
          'contextExposed': false,
          'account': 'another-user',
        }),
        await credential('seen', 'accountPassword', {
          'source': 'agentString',
          'contextExposed': true,
          'secret': seen,
        }),
        await credential('token', 'token', {
          'source': 'agentString',
          'contextExposed': true,
          'secret': apiToken,
        }),
        await credential('identity', 'file', {
          'source': 'agentFile',
          'contextExposed': false,
          'filePath': file.path,
        }),
      ];
      final submitted = await run('import-submit', {
        'operationId': 'credentials-once',
        'items': items,
      });
      expect(submitted['status'], 'pending', reason: jsonEncode(submitted));
      final id = submitted['proposalId'] as String;
      expect(
        (await run('import-submit', {
          'operationId': 'credentials-once',
          'items': items,
        }))['proposalId'],
        id,
      );
      Future<WorkspaceProposalDetail> detail() async {
        final raw = await owner.request(
          'GET',
          '/v1/owner/proposals/${Uri.encodeComponent(id)}',
        );
        for (final value in [
          ownerFirst,
          ownerSecond,
          seen,
          apiToken,
          fileText,
          file.path,
        ]) {
          expect(jsonEncode(raw), isNot(contains(value)));
          expect(
            jsonEncode(raw),
            isNot(contains(base64Encode(utf8.encode(value)))),
          );
        }
        return proposalDetailFromJson(raw);
      }

      var review = await detail();
      expect(review.items, hasLength(6));
      expect(
        review.items
            .where((i) => i.credential?.source == 'owner')
            .every((i) => !i.credential!.ready),
        true,
      );
      expect(
        review.items
            .firstWhere((i) => i.credential?.source == 'agentString')
            .credential!
            .contextExposed,
        true,
      );
      Map<String, Object?> confirm(WorkspaceProposalDetail d, String op) =>
          proposalChangeToJson(
            WorkspaceProposalChange(
              operationId: op,
              proposalId: id,
              version: d.summary.version,
              reviewToken: d.reviewToken,
              action: WorkspaceProposalAction.confirm,
              reviewed: d.items.map(WorkspaceProposalItemReview.fromItem),
            ),
          );
      await expectLater(
        owner.request(
          'POST',
          '/v1/owner/proposals/decisions',
          confirm(review, 'incomplete'),
        ),
        throwsA(isA<RemoteFailure>()),
      );
      expect(repo.items, isEmpty);
      expect(repo.managedCredentials, isEmpty);
      final hostile = HttpClient(context: trust);
      try {
        final request = await hostile.postUrl(
          owner.address.resolve(
            '/v1/owner/proposals/${Uri.encodeComponent(id)}/passwords/read',
          ),
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('authorization', 'Bearer ${profile.deviceToken}');
        request.headers.set('x-chiyo-server-id', owner.serverId);
        request.write(jsonEncode({'version': 1, 'itemKey': 'login'}));
        final response = await request.close();
        expect(response.statusCode, 401);
        await response.drain<void>();
      } finally {
        hostile.close(force: true);
      }
      final fill = {
        'operationId': 'private-fill',
        'version': 1,
        'values': {'login': ownerFirst, 'second': ownerSecond},
      };
      final receipt = await owner.request(
        'POST',
        '/v1/owner/proposals/${Uri.encodeComponent(id)}/passwords/fill',
        fill,
      );
      expect((receipt['operation'] as Map)['resultingVersion'], 2);
      expect(jsonEncode(receipt), isNot(contains(ownerFirst)));
      expect(
        await owner.request(
          'POST',
          '/v1/owner/proposals/${Uri.encodeComponent(id)}/passwords/fill',
          fill,
        ),
        receipt,
      );
      expect(repo.items, isEmpty);
      expect(repo.managedCredentials, isEmpty);
      final port = server.port;
      await close();
      await open(port);
      expect(
        await owner.request(
          'GET',
          '/v1/owner/proposals/password-operations/private-fill',
        ),
        receipt,
      );
      review = await detail();
      expect(review.summary.version, 2);
      expect(
        review.items
            .where((i) => i.credential?.source == 'owner')
            .every((i) => i.credential!.ready),
        true,
      );
      await owner.request(
        'POST',
        '/v1/owner/proposals/decisions',
        confirm(review, 'confirm-all'),
      );
      expect(repo.items, hasLength(1));
      expect(repo.managedCredentials, hasLength(5));
      expect(
        repo.managedCredentials.every(
          (c) => c.linkedItemIds.contains(repo.items.single.id),
        ),
        true,
      );
      expect(runtime.service.owner.credentialUseRequests, isEmpty);
      for (final value in [ownerFirst, ownerSecond, seen, apiToken, fileText]) {
        expect(
          repo.credentialMaterials.any((m) => utf8.decode(m.bytes) == value),
          true,
        );
      }
      expect(
        (await run('import-status', {
          'operationId': 'credentials-once',
        }))['status'],
        'confirmed',
      );
      expect((await run('catalog'))['status'], 'ok');
      expect(
        await owner.request(
          'GET',
          '/v1/owner/proposals/password-operations/private-fill',
        ),
        receipt,
      );
      expect((await cli.endLifecycleSession(cli.endCapability!))['status'], 'ended');
      expect((await run('import-submit', {'operationId': 'after-end', 'items': items}))['status'], 'unauthorized');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
