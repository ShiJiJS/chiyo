import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'reopening encrypted storage preserves the material registry but no capability, and marks unconfirmed file use for inspection',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'file-runtime-storage-',
      );
      final keys = TestKeyStore();
      var repository = await EncryptedInformationRepository.open(
        directory.path,
        keys,
      );
      var service = InformationService(
        repository: repository,
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 1, 1, 'sha256:controlled'),
      );
      CredentialMaterialLease? lease;
      addTearDown(() async {
        await service.close();
        await repository.close();
        if (lease != null) {
          ManagedCredentialFiles.cleanup(
            lease,
          ); // Fixture never creates a process.
        }
        await directory.delete(recursive: true);
      });
      var credential = await service.owner.createFileCredential(
        name: 'Synthetic AWS',
        publicPurpose: 'Test only',
        fileName: 'credentials.ini',
        bytes: utf8.encode(
          '[default]\naws_access_key_id=TEST_ONLY\naws_secret_access_key=NOT_A_REAL_KEY_983172\n',
        ),
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'token',
        discoverable: true,
      );
      final session = service.agent.openSession(
        'Synthetic interrupted file use',
      );
      final request = await service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'command': 'request-use',
          'purpose': 'Controlled file preparation',
          'credentials': [
            {
              'alias': 'token',
              'credentialId': credential.id,
              'version': credential.version,
            },
          ],
          'launch': {
            'receiver': 'aws_shared_credentials',
            'executable': Platform.resolvedExecutable,
            'argv': ['sts', 'get-caller-identity', '--region', 'us-east-1'],
            'cwd': Directory.current.path,
            'env': {
              'AWS_SHARED_CREDENTIALS_FILE': {'file': 'token'},
            },
          },
        }),
      );
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final material = await service.agent.consumeCredentialUse(
        session,
        request.id,
      );
      lease = ManagedCredentialFiles.reserve(material.materialLease!, [
        'credential.bin',
        'aws-config',
      ]);
      await service.agent.registerCredentialMaterials(
        material.executionId,
        material.executionCapability,
        lease,
      );
      ManagedCredentialFiles.write(
        lease,
        'credential.bin',
        material.credentialMaterial.bytes,
      );
      ManagedCredentialFiles.write(lease, 'aws-config', const []);
      await service.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(
        directory.path,
        keys,
      );
      service = InformationService(repository: repository);
      final record = service.owner.credentialExecutions.single;
      expect(record.state, 'unknown');
      expect(record.cleanupState, 'needs_check');
      expect(record.materialLease!.identity, lease.identity);
      expect(record.materialLease!.files, lease.files);
      expect(jsonEncode(record.toJson()), isNot(contains(lease.path)));
      expect(
        jsonEncode(record.toStorageJson()),
        isNot(contains(material.executionCapability)),
      );
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'session_required',
          ),
        ),
      );
      await expectLater(
        service.owner.cleanupCredentialExecution(record.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'cleanup_busy',
          ),
        ),
      );
      expect(await File('${lease.path}/credential.bin').exists(), isTrue);
      for (final file in directory.listSync().whereType<File>().where(
        (f) => !f.path.endsWith('.lock'),
      )) {
        expect(
          String.fromCharCodes(await file.readAsBytes()),
          isNot(contains('NOT_A_REAL_KEY_983172')),
        );
      }
    },
    skip: !Platform.isWindows,
  );
}
