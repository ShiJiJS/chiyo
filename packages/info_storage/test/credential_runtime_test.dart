import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'encrypted runtime facts survive reopening without restoring sessions or unused start permission',
    () async {
      final folder = await Directory.systemTemp.createTemp('runtime-storage-');
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(
        repository: repo,
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 1, 1, 'sha256:fixture'),
      );
      var c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'SYNTHETIC-PRIVATE-839172',
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      final session = service.agent.openSession('Synthetic reopen');
      Future<CredentialUseRequest> request() =>
          service.agent.requestCredentialUse(
            session,
            CredentialUseInput.fromJson({
              'command': 'request-use',
              'purpose': 'Synthetic read',
              'credentials': [
                {'alias': 'token', 'credentialId': c.id, 'version': 1},
              ],
              'launch': {
                'receiver': 'gh_token',
                'executable': Platform.resolvedExecutable,
                'argv': ['api', 'user'],
                'cwd': Directory.current.path,
                'env': {
                  'GH_TOKEN': {'secret': 'token'},
                },
              },
            }),
          );
      final unused = await request();
      await service.owner.decideCredentialUse(
        unused.id,
        approveCredential: true,
      );
      final used = await request();
      await service.owner.decideCredentialUse(used.id, approveCredential: true);
      final material = await service.agent.consumeCredentialUse(
        session,
        used.id,
      );
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
      });
      expect(service.owner.credentialUseRequests.length, 2);
      expect(
        service.owner.credentialGrantState(
          service.owner.credentialUseRequests.first,
        ),
        'revoked',
      );
      expect(service.owner.credentialExecutions.single.state, 'unknown');
      await expectLater(
        service.agent.consumeCredentialUse(session, unused.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'session_required',
          ),
        ),
      );
      final facts = jsonEncode(
        service.owner.credentialUseRequests.map((r) => r.toJson()).toList(),
      );
      expect(facts, isNot(contains('SYNTHETIC-PRIVATE-839172')));
      expect(facts, isNot(contains(session)));
      expect(facts, isNot(contains(material.executionCapability)));
      for (final file in folder.listSync().whereType<File>().where(
        (f) => !f.path.endsWith('.lock'),
      )) {
        expect(
          String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('SYNTHETIC-PRIVATE-839172')),
        );
      }
    },
  );
}
