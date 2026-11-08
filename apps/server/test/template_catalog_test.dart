import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/plugin_transport.dart';
import 'package:info_workspace/workspace_plugins.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';
import 'support/template_fixture.dart';

void main() {
  test(
    'online owner and formal CLI share installed templates and examples across restart',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-online-templates-',
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
      const serverId = 'synthetic-templates-server';
      late EncryptedInformationRepository repo;
      late OnlineInformationRuntime runtime;
      late OnlineServer server;
      late OwnerClient owner;
      late AgentClient cli;
      late AgentConnectionProfile connection;
      Future<void> open({int port = 0}) async {
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        runtime = await OnlineInformationRuntime.open(repository: repo);
        server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: serverId,
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
      final device = await owner.request('POST', '/v1/owner/devices', {
        'operationId': 'enroll-template-cli',
        'name': 'Synthetic CLI',
      });
      connection = AgentConnectionProfile(
        address: owner.address,
        deviceToken: device['deviceToken'] as String,
        serverId: serverId,
        certificate: await File(fixture.ca).readAsString(),
      );
      cli = AgentClient.remote(connection);
      addTearDown(() async {
        cli.close();
        await close();
        await root.delete(recursive: true);
      });

      Future<Map<String, dynamic>> read(String id) async {
        final result = await cli.execute({
          'command': 'template-read',
          'templateId': id,
        });
        expect(result['status'], 'ok');
        return Map.from(result['template'] as Map);
      }

      Future<WorkspacePluginCatalog> catalog() async => pluginCatalogFromJson(
        await owner.request('GET', '/v1/owner/plugins'),
      );
      Future<WorkspacePluginReceipt> toggle(
        WorkspacePluginAction action,
        String operation,
      ) async {
        return pluginReceiptFromJson(
          await owner.request(
            'POST',
            '/v1/owner/plugins/changes',
            pluginChangeToJson(
              WorkspacePluginChange(
                operationId: operation,
                action: action,
                packageId: 'local.synthetic',
                expectedVersion: (await catalog()).version,
              ),
            ),
          ),
        );
      }

      Future<WorkspacePluginReceipt> install(
        String version,
        String operation, {
        bool extra = false,
      }) async {
        final selected = await owner
            .request('POST', '/v1/owner/plugins/stage', {
              'filename': 'PRIVATE-SYNTHETIC-ORIGIN.json',
              'bytes': base64Encode(
                utf8.encode(
                  jsonEncode(syntheticTemplatePackage(version, extra: extra)),
                ),
              ),
            });
        final preview = pluginPreviewFromJson(
          await owner.request(
            'GET',
            '/v1/owner/plugins/previews/${selected['selectionId']}',
          ),
        );
        final change = pluginChangeToJson(
          WorkspacePluginChange(
            operationId: operation,
            action: WorkspacePluginAction.install,
            packageId: preview.package.id,
            expectedVersion: preview.catalogVersion,
            expectedDigest: preview.package.digest,
            selectionId: preview.selectionId,
          ),
        );
        final result = await owner.request(
          'POST',
          '/v1/owner/plugins/changes',
          change,
        );
        expect(
          await owner.request('POST', '/v1/owner/plugins/changes', change),
          result,
        );
        return pluginReceiptFromJson(result);
      }

      final caps =
          (await cli.execute({'command': 'capabilities'}))['capabilities']
              as List;
      expect(caps, contains('information-template-discovery.v1'));
      expect(caps, contains('information-import-admission.v1'));
      expect(caps, contains('credential-import.v1'));
      final initial = await cli.execute({'command': 'template-list'});
      expect(
        (initial['templates'] as List).any((t) => t['id'] == 'file'),
        isTrue,
      );
      for (final definition
          in (await owner.request('GET', '/v1/owner/catalog'))['templates']
              as List) {
        expect(
          (await read(definition['id'] as String))['definition'],
          definition,
        );
      }
      final file = await read('file');
      expect(
        (file['definition'] as Map)['fields'],
        contains(containsPair('type', 'file')),
      );
      expect(
        ((file['submissionExample'] as Map)['items'] as List)
            .single['attachments'],
        isNotEmpty,
      );
      final before = (await owner.request(
        'GET',
        '/v1/server',
      ))['workspaceObservation'];
      final installed = await install('1.0.0', 'install-once');
      final originalVersion = (await catalog()).version;
      final invalid = syntheticTemplatePackage('3.0.0');
      (((invalid['templates'] as List).single as Map)['fields'] as List)
              .first['type'] =
          'execute-shell';
      final badSelection = await owner
          .request('POST', '/v1/owner/plugins/stage', {
            'filename': 'unsupported.json',
            'bytes': base64Encode(utf8.encode(jsonEncode(invalid))),
          });
      await expectLater(
        owner.request(
          'GET',
          '/v1/owner/plugins/previews/${badSelection['selectionId']}',
        ),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'invalid_package'),
        ),
      );
      await owner.request(
        'DELETE',
        '/v1/owner/plugins/selections/${badSelection['selectionId']}',
      );
      await expectLater(
        owner.request('POST', '/v1/owner/plugins/changes', {
          'operationId': 'unsupported-change',
          'action': 'execute-shell',
          'packageId': 'local.synthetic',
          'expectedVersion': originalVersion,
        }),
        throwsA(
          isA<RemoteFailure>().having((e) => e.code, 'code', 'invalid_request'),
        ),
      );
      expect((await catalog()).version, originalVersion);
      await expectLater(
        owner.request('GET', '/v1/owner/plugins/operations/unsupported-change'),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'operation_not_found',
          ),
        ),
      );
      final first = await read('local.synthetic/note');
      expect(first['hasGuidance'], true);
      expect(jsonEncode(first), isNot(contains('PRIVATE-SYNTHETIC-ORIGIN')));
      expect(
        (await owner.request('GET', '/v1/server'))['workspaceObservation'],
        isNot(before),
      );
      expect({
        ...(await catalog()).packages
            .singleWhere((p) => p.id == 'local.synthetic')
            .templates
            .single
            .definition,
        'id': 'local.synthetic/note',
      }, first['definition']);

      // Validate all returned examples through the existing importer. Remote
      // files and credentials remain unadvertised until #97/#98 are connected.
      final protocol = AgentProtocol(runtime.service.agent);
      final session =
          (await runtime.run(
                () => protocol.dispatch('/session/lifecycle', {
                  'chatLabel': 'Example validation',
                }),
              ))['sessionSecret']
              as String;
      String? frozenId;
      for (final id in [
        'generic',
        'service',
        'server',
        'profile',
        'local.synthetic/note',
        'credential.accountPassword',
        'credential.token',
        'credential.file',
        'file',
      ]) {
        final template = await read(id);
        final example = Map<String, dynamic>.from(
          template['submissionExample'] as Map,
        )..remove('command');
        example['sessionSecret'] = session;
        example['operationId'] = 'validate-${id.replaceAll('/', '-')}';
        final inputItem = (example['items'] as List).single as Map;
        if (id == 'credential.file') {
          final credential = inputItem['credential'] as Map;
          credential.remove('filePath');
          credential['fileName'] = 'synthetic-identity';
          credential['bytes'] = base64Encode(utf8.encode('SYNTHETIC-KEY-ONLY'));
        }
        if (id == 'file') {
          final uploaded = await runtime.run(
            () => protocol.dispatch('/import-file/submit', {
              'sessionSecret': session,
              'operationId': 'validate-original',
              'originalName': 'synthetic-original.txt',
              'mediaType': 'text/plain',
              'bytes': base64Encode(utf8.encode('SYNTHETIC-ORIGINAL-ONLY')),
            }),
          );
          final version =
              (((inputItem['attachments'] as List).single as Map)['versions']
                          as List)
                      .single
                  as Map;
          version.remove('filePath');
          version['uploadId'] = uploaded['uploadId'];
        }
        final pending = await runtime.run(
          () => protocol.dispatch('/import/submit', example),
        );
        expect(pending['status'], 'pending', reason: id);
        if (id == 'local.synthetic/note') {
          final proposal = runtime.service.owner.importProposals.singleWhere(
            (p) => p.id == pending['proposalId'],
          );
          final receipts = await runtime.run(
            () => runtime.service.owner.confirmImport(
              proposal.id,
              proposal.version,
              proposal.items,
            ),
          );
          frozenId = receipts.single.id;
        }
      }
      final frozen = runtime.service.owner.information.singleWhere(
        (i) => i.id == frozenId,
      );
      expect(frozen.layout!.snapshot['definition'], first['definition']);
      await toggle(WorkspacePluginAction.disable, 'disable');
      expect(
        (await cli.execute({
          'command': 'template-read',
          'templateId': 'local.synthetic/note',
        }))['status'],
        'template_unavailable',
      );
      expect(
        ((await cli.execute({'command': 'template-list'}))['templates'] as List)
            .singleWhere((t) => t['id'] == 'local.synthetic/note')['enabled'],
        false,
      );
      await toggle(WorkspacePluginAction.enable, 'enable');
      await install('2.0.0', 'upgrade', extra: true);
      expect((await read('local.synthetic/note'))['version'], '2.0.0');
      final currentPort = server.port;
      await close();
      await open(port: currentPort);
      expect((await read('local.synthetic/note'))['version'], '2.0.0');
      expect(
        pluginReceiptFromJson(
          await owner.request(
            'GET',
            '/v1/owner/plugins/operations/install-once',
          ),
        ).digest,
        installed.digest,
      );
      expect(
        runtime.service.owner.information
            .singleWhere((i) => i.id == frozenId)
            .layout!
            .snapshot['definition'],
        first['definition'],
      );
      await toggle(WorkspacePluginAction.remove, 'remove');
      expect(
        (await cli.execute({
          'command': 'template-read',
          'templateId': 'local.synthetic/note',
        }))['status'],
        'template_missing',
      );
      expect(
        runtime.service.owner.information
            .singleWhere((i) => i.id == frozenId)
            .fields,
        isNotEmpty,
      );

      final evil = HttpClient(context: trust);
      addTearDown(() => evil.close(force: true));
      final request = await evil.postUrl(
        owner.address.resolve('/v1/owner/plugins/stage'),
      );
      request.headers.set('authorization', 'Bearer ${connection.deviceToken}');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'filename': 'evil.json', 'bytes': 'e30='}));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 401);
    },
  );
}
