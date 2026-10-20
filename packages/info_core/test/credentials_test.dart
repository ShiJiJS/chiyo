import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/protocol_json.dart';
import 'package:test/test.dart';

class FailingVault extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<void> commitCredentials(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) async {
    if (fail) throw const AccessFailure('synthetic_storage_failure');
    await super.commitCredentials(credentials, materials);
  }
}

void main() {
  test(
    'strict protocol rejects nested duplicate keys and nonfinite numbers before shape validation',
    () {
      for (final text in [
        '{"nested":{"a":1,"\\u0061":2}}',
        '{"nested":[1e999]}',
      ]) {
        expect(() => decodeProtocolObject(text), throwsFormatException);
      }
    },
  );
  test(
    'credential transport distinguishes malformed, unknown, typed and reference errors without echoing input',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final server = await AgentServer.start(service.agent, port: 0);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close();
        await service.close();
      });
      Future<Map<String, dynamic>> send(String text) async {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/credentials/catalog'),
        );
        request.headers.contentType = ContentType.json;
        request.write(text);
        return jsonDecode(await utf8.decoder.bind(await request.close()).join())
            as Map<String, dynamic>;
      }

      for (final sample in [
        ('{"limit":1,"limit":2}', 'invalid_json'),
        ('{"secret":"synthetic-never-echo"}', 'unknown_field'),
        ('{"limit":1.0}', 'invalid_type'),
        ('{"limit":101}', 'limit_exceeded'),
        ('{"cursor":"synthetic-never-echo"}', 'invalid_reference'),
        ('{"cursor":""}', 'invalid_reference'),
      ]) {
        final result = await send(sample.$1);
        expect(result['protocolVersion'], 1);
        expect(result['errorCode'], sample.$2);
        expect(jsonEncode(result), isNot(contains('synthetic-never-echo')));
      }
    },
  );
  test(
    'failed owner mutations leave the old fixed version and associations intact',
    () async {
      final repo = FailingVault();
      final service = InformationService(repository: repo);
      addTearDown(service.close);
      var c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'fictional',
      );
      repo.fail = true;
      await expectLater(
        service.owner.rotateStringCredential(c.id, c.revision, 'replacement'),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.credential(c.id).version, 1);
      service.owner.checkCredentialEligibility(
        c.id,
        1,
        useGeneration: c.useGeneration,
      );
      await expectLater(
        service.owner.createFileCredential(
          name: 'Synthetic file',
          publicPurpose: '',
          fileName: 'file',
          bytes: [1],
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.credentials.length, 1);
      repo.fail = false;
      c = await service.owner.setCredentialEnabled(c.id, c.revision, false);
      expect(c.enabled, isFalse);
    },
  );
  test(
    'catalog pages use NFC names and include only opted-in current availability',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      for (final name in ['A\u030A', 'Z']) {
        final c = await service.owner.createStringCredential(
          name: name,
          publicPurpose: 'Public',
          secret: 'fictional',
        );
        await service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: c.publicPurpose,
          privateNote: 'private',
          suggestedBinding: c.suggestedBinding,
          discoverable: true,
        );
      }
      final first = service.agent.credentialCatalog(limit: 1);
      expect(first.credentials.single['name'], 'Z');
      expect(first.nextCursor, isNotNull);
      final next = service.agent.credentialCatalog(
        cursor: first.nextCursor,
        limit: 1,
      );
      expect(next.credentials.single['name'], 'A\u030A');
      expect(next.nextCursor, isNull);
    },
  );
  test(
    'disable then re-enable cannot revive a captured use generation; recycle restores disabled new version',
    () async {
      var now = DateTime.utc(2026, 10, 17);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      addTearDown(service.close);
      final owner = service.owner;
      var c = await owner.createStringCredential(
        name: 'Token',
        publicPurpose: '',
        secret: 'fictional',
      );
      final generation = c.useGeneration;
      c = await owner.setCredentialEnabled(c.id, c.revision, false);
      c = await owner.setCredentialEnabled(c.id, c.revision, true);
      expect(
        () => owner.checkCredentialEligibility(
          c.id,
          1,
          useGeneration: generation,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'credential_version_changed',
          ),
        ),
      );
      await owner.deleteCredential(c.id, c.revision);
      expect(owner.credentials, isEmpty);
      expect(owner.recycledCredentials.single.id, c.id);
      c = await owner.restoreCredential(c.id);
      expect(c.version, 2);
      expect(c.enabled, isFalse);
      c = await owner.setCredentialEnabled(c.id, c.revision, true);
      owner.checkCredentialEligibility(c.id, 2);
      now = now.add(const Duration(days: 31));
      await owner.purgeExpiredCredentialMaterial();
      expect(owner.credentialVersions(c.id).map((v) => v.version), [2]);
    },
  );
  test(
    'file owns its byte copy and rotation invalidates fixed version without changing links',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final owner = service.owner;
      final item = await owner.createInformation('Server', '', [
        const FieldInput('Host', '', 'fictional.invalid'),
      ]);
      final other = await owner.createInformation('Deployment', '', [
        const FieldInput('Directory', '', '/fictional'),
      ]);
      final input = [0, 1, 254, 255];
      var c = await owner.createFileCredential(
        name: 'Private key',
        publicPurpose: 'SSH',
        fileName: 'deploy_ed25519',
        bytes: input,
        suggestedBinding: 'ssh_key',
      );
      input[0] = 22;
      c = await owner.setCredentialLinks(c.id, c.revision, [item.id, other.id]);
      expect(c.byteLength, 4);
      owner.checkCredentialEligibility(c.id, 1);
      c = await owner.rotateFileCredential(
        c.id,
        c.revision,
        bytes: [9, 8, 7],
        fileName: 'replacement',
      );
      expect(c.version, 2);
      expect(c.linkedItemIds, [item.id, other.id]);
      expect(
        () => owner.checkCredentialEligibility(c.id, 1),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'credential_version_changed',
          ),
        ),
      );
      c = await owner.setCredentialEnabled(c.id, c.revision, false);
      expect(
        () => owner.checkCredentialEligibility(c.id, 2),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'credential_disabled',
          ),
        ),
      );
      expect(owner.information.first.fields.single.value, 'fictional.invalid');
      expect(jsonEncode(service.agent.catalog()), isNot(contains(c.id)));
    },
  );
  test('owner stores a string independently and discovery is opt in', () async {
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    addTearDown(service.close);
    final c = await service.owner.createStringCredential(
      name: 'Repository token',
      publicPurpose: 'Maintain skills',
      secret: 'fictional-secret-42',
      privateNote: 'owner-only note',
      suggestedBinding: 'GH_TOKEN',
    );
    expect(c.version, 1);
    expect(c.discoverable, isFalse);
    expect(service.agent.credentialCatalog().credentials, isEmpty);
    expect(service.agent.catalog(), isEmpty);
    await service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: c.publicPurpose,
      privateNote: c.privateNote,
      suggestedBinding: c.suggestedBinding,
      discoverable: true,
    );
    final catalog = service.agent.credentialCatalog().toJson();
    expect((catalog['credentials'] as List).single, {
      'credentialId': c.id,
      'name': 'Repository token',
      'publicPurpose': 'Maintain skills',
      'form': 'string',
      'version': 1,
      'availability': 'available',
    });
    expect(jsonEncode(catalog), isNot(contains('fictional-secret')));
    expect(jsonEncode(catalog), isNot(contains('owner-only')));
    expect(service.owner.information, isEmpty);
  });
}
