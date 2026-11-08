import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/credential_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

void main() {
  test(
    'owner HTTPS saves credential strings and files through original rules; metadata and restart receipts never disclose material',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'owner-credential-http-',
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
      late OwnerClient client;
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
          serverId: 'synthetic-credential-server',
          port: port,
        );
        client = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
      }

      Future<void> close() async {
        client.close();
        await server.close();
        await runtime.close();
        await repo.close();
      }

      await open();
      addTearDown(() async {
        await close();
        await root.delete(recursive: true);
      });
      const secret = 'SYNTHETIC_OWNER_TOKEN';
      const prefix = '/v1/owner/credentials';
      Future<Map<String, dynamic>> call(
        String method,
        String path, [
        Map<String, Object?>? input,
      ]) async {
        final result = await client.request(method, '$prefix$path', input);
        expect(jsonEncode(result), isNot(contains(secret)));
        expect(
          jsonEncode(result),
          isNot(contains(base64Encode(utf8.encode(secret)))),
        );
        expect(jsonEncode(result), isNot(contains('secret')));
        return result;
      }

      Matcher fails(String code) =>
          throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', code));
      final device = await client.request('POST', '/v1/owner/devices', {
        'operationId': 'enroll',
        'name': 'Synthetic agent',
      });
      final unauthorized = HttpClient(context: trust);
      try {
        final request = await unauthorized.postUrl(
          client.address.resolve('$prefix/inputs'),
        );
        request.headers.contentType = ContentType.json;
        request.headers.set('authorization', 'Bearer ${device['deviceToken']}');
        request.headers.set('x-chiyo-server-id', client.serverId);
        request.write(
          jsonEncode({
            'operationId': 'not-owner',
            'form': 'string',
            'secret': secret,
          }),
        );
        final response = await request.close();
        expect(response.statusCode, 401);
        expect(
          await response.transform(utf8.decoder).join(),
          isNot(contains(secret)),
        );
        expect(runtime.service.owner.credentials, isEmpty);
      } finally {
        unauthorized.close(force: true);
      }
      final staged = await call('POST', '/inputs', {
        'operationId': 'input',
        'form': 'string',
        'secret': secret,
      });
      expect(
        await call('POST', '/inputs', {
          'operationId': 'input',
          'form': 'string',
          'secret': secret,
        }),
        staged,
      );
      expect(await call('GET', '/inputs/input'), staged);
      await expectLater(
        call('POST', '/inputs', {
          'operationId': 'input',
          'form': 'string',
          'secret': 'different',
        }),
        fails('operation_conflict'),
      );
      final candidate = credentialCandidateFromJson(staged['candidate']);
      expect(runtime.service.owner.credentials, isEmpty);
      WorkspaceCredentialWrite write(
        String op, {
        WorkspaceCredentialDetail? before,
        String? selected,
        String name = 'Synthetic credential',
      }) => WorkspaceCredentialWrite(
        operationId: op,
        name: name,
        purpose: 'Synthetic service login',
        binding: 'SYNTHETIC_TOKEN',
        candidateId: selected,
        ref: before?.record.ref,
        expectedRecordVersion: before?.recordVersion,
        expectedMaterialVersion: before?.materialVersion,
      );
      final input = write('save', selected: candidate.id);
      final saved = credentialReceiptFromJson(
        await call('POST', '/save', credentialWriteToJson(input)),
      );
      expect(
        credentialReceiptFromJson(
          await call('POST', '/save', credentialWriteToJson(input)),
        ).ref,
        saved.ref,
      );
      expect(
        credentialReceiptFromJson(
          await call('GET', '/operations/save'),
        ).commandDigest,
        input.commandDigest,
      );
      expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
      var detail = credentialDetailFromJson(
        await call('GET', '/${saved.ref.id}'),
      );
      final generation = detail.useGeneration;
      await call(
        'POST',
        '/save',
        credentialWriteToJson(
          write('edit', before: detail, name: 'Renamed credential'),
        ),
      );
      detail = credentialDetailFromJson(await call('GET', '/${saved.ref.id}'));
      expect(detail.recordVersion, 2);
      expect(detail.materialVersion, 1);
      expect(detail.useGeneration, generation);
      final replacement = credentialCandidateFromJson(
        (await call('POST', '/inputs', {
          'operationId': 'replacement',
          'form': 'string',
          'secret': 'SYNTHETIC_REPLACEMENT_TOKEN',
        }))['candidate'],
      );
      await call(
        'POST',
        '/save',
        credentialWriteToJson(
          write('replace', before: detail, selected: replacement.id),
        ),
      );
      detail = credentialDetailFromJson(await call('GET', '/${saved.ref.id}'));
      expect(detail.materialVersion, 2);
      expect(detail.useGeneration, greaterThan(generation));
      await call(
        'POST',
        '/enabled',
        credentialToggleToJson(
          WorkspaceCredentialToggle(
            operationId: 'disable',
            ref: detail.record.ref,
            expectedRecordVersion: detail.recordVersion,
            expectedMaterialVersion: detail.materialVersion,
            enabled: false,
          ),
        ),
      );
      final bytes = List<int>.generate(1048576, (i) => i % 251);
      final file = credentialCandidateFromJson(
        (await call('POST', '/inputs', {
          'operationId': 'file',
          'form': 'file',
          'filename': 'synthetic.key',
          'bytes': base64Encode(bytes),
        }))['candidate'],
      );
      final fileSaved = credentialReceiptFromJson(
        await call(
          'POST',
          '/save',
          credentialWriteToJson(write('save-file', selected: file.id)),
        ),
      );
      expect(
        repo.credentialMaterials
            .where((m) => m.credentialId == fileSaved.ref.id)
            .single
            .bytes,
        bytes,
      );
      await call('DELETE', '/inputs/canceled');
      await expectLater(
        call('POST', '/inputs', {
          'operationId': 'canceled',
          'form': 'string',
          'secret': secret,
        }),
        fails('selection_expired'),
      );
      await expectLater(
        call('POST', '/inputs', {
          'operationId': 'bad-shape',
          'form': 'string',
          'secret': secret,
          'path': '/not-accepted',
        }),
        fails('invalid_request'),
      );
      final unused = credentialCandidateFromJson(
        (await call('POST', '/inputs', {
          'operationId': 'unused',
          'form': 'string',
          'secret': secret,
        }))['candidate'],
      );
      await call('DELETE', '/candidates/${unused.id}');
      await expectLater(
        call(
          'POST',
          '/save',
          credentialWriteToJson(write('not-saved', selected: unused.id)),
        ),
        fails('selection_expired'),
      );
      expect(runtime.service.owner.credentials, hasLength(2));
      expect(runtime.service.owner.credentialUseRequests, isEmpty);
      final port = server.port;
      await close();
      await open(port);
      detail = credentialDetailFromJson(await call('GET', '/${saved.ref.id}'));
      expect(detail.enabled, false);
      expect(detail.materialVersion, 2);
      final materials = credentialMaterialsFromJson(
        await call('GET', '/${saved.ref.id}/materials'),
      );
      expect(materials.materials.map((m) => m.version), [2, 1]);
      expect(
        credentialReceiptFromJson(await call('GET', '/operations/save')).ref,
        saved.ref,
      );
      expect(
        (await call('GET', '/${fileSaved.ref.id}'))['filename'],
        'synthetic.key',
      );
      for (final entity in Directory('${root.path}/data').listSync()) {
        if (entity is File && !entity.path.endsWith('.lock')) {
          expect(
            latin1.decode(entity.readAsBytesSync()),
            isNot(contains(secret)),
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
