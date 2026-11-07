import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/ssh_session_fixture.dart' show knownHostBytes;

void main() {
  test(
    'a closed service cannot replace or clear its confirmed SSH host settings',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final original = await service.owner.configureSshKnownHosts(
        'original',
        knownHostBytes(),
      );
      await service.close();
      for (final action in <Future<Object?> Function()>[
        () => service.owner.configureSshKnownHosts(
          'replacement',
          knownHostBytes(),
        ),
        () => service.owner.clearSshKnownHosts(),
      ]) {
        await expectLater(
          action(),
          throwsA(
            isA<CredentialUseFailure>().having(
              (e) => e.code,
              'code',
              'service_unavailable',
            ),
          ),
        );
      }
      expect(service.owner.sshKnownHosts!.id, original.id);
    },
  );
  test(
    'confirming SSH hosts copies the submitted bytes before asynchronous storage and returns an immutable snapshot',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final bytes = knownHostBytes(), expected = List<int>.of(knownHostBytes());
      final saving = service.owner.configureSshKnownHosts('confirmed', bytes);
      bytes.fillRange(0, bytes.length, 0);
      final snapshot = await saving;
      expect(snapshot.bytes, expected);
      expect(() => snapshot.bytes.clear(), throwsUnsupportedError);
      expect(service.owner.sshKnownHosts!.id, snapshot.id);
    },
  );
  test(
    'SSH approval binds an owner-confirmed host snapshot and effective isolation arguments, and never silently follows a replacement snapshot',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
        credentialExecutableInspector: (path, receiver) async =>
            ExecutableIdentity(path, 1, 1, 'sha256:fixture'),
      );
      addTearDown(service.close);
      var credential = await service.owner.createFileCredential(
        name: 'Synthetic SSH',
        publicPurpose: 'Test only',
        fileName: 'identity',
        bytes: utf8.encode('SYNTHETIC PRIVATE KEY NOT USED FOR AUTHENTICATION'),
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'ssh_key',
        discoverable: true,
      );
      final session = service.agent.openSession('SSH use');
      final input = CredentialUseInput.fromJson({
        'command': 'request-use',
        'purpose': 'Run a fixed noninteractive command',
        'credentials': [
          {
            'alias': 'ssh_key',
            'credentialId': credential.id,
            'version': credential.version,
          },
        ],
        'launch': {
          'receiver': 'ssh_identity',
          'executable': Platform.resolvedExecutable,
          'argv': [
            '-T',
            '-o',
            'BatchMode=yes',
            '-i',
            {'file': 'ssh_key'},
            '-p',
            '2222',
            'developer@test.beichen.example',
            '/usr/bin/true',
          ],
          'cwd': Directory.current.path,
          'env': <String, Object?>{},
        },
      });
      await expectLater(
        service.agent.requestCredentialUse(session, input),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'receiver_not_ready',
          ),
        ),
      );
      final trust = await service.owner.configureSshKnownHosts(
        'confirmed-hosts',
        knownHostBytes(),
      );
      final request = await service.agent.requestCredentialUse(session, input);
      final saved = CredentialUseRequest.fromJson(request.toStorageJson());
      final submission = CredentialUseInput.fromJson(
        saved.toRequestInputJson(),
      );
      expect(
        submission.launch.argv.map((v) => v.toJson()).toList(),
        input.launch.argv.map((v) => v.toJson()).toList(),
      );
      expect(submission.launch.sshTrustSnapshotId, isNull);
      expect(request.plan.sshTrustSnapshotId, trust.id);
      expect(
        request.plan.internalMaterialHashes['ssh_known_hosts'],
        trust.sha256,
      );
      expect(
        request.plan.argv.any(
          (v) =>
              v.kind == LaunchValueKind.internalMaterial &&
              v.value == 'ssh_config',
        ),
        isTrue,
      );
      expect(
        request.plan.argv.any(
          (v) =>
              v.kind == LaunchValueKind.internalMaterial &&
              v.value == 'ssh_user_hosts_option',
        ),
        isTrue,
      );
      expect(
        request.plan.argv.any(
          (v) =>
              v.kind == LaunchValueKind.internalMaterial &&
              v.value == 'ssh_global_hosts_option',
        ),
        isTrue,
      );
      expect(
        request.plan.argv.map((v) => v.value),
        containsAll([
          'IdentitiesOnly=yes',
          'IdentityAgent=none',
          'StrictHostKeyChecking=yes',
          'PasswordAuthentication=no',
          'KbdInteractiveAuthentication=no',
        ]),
      );
      expect(
        CredentialUseRequest.fromJson(request.toStorageJson()).plan.planHash,
        request.plan.planHash,
      );
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      await service.owner.configureSshKnownHosts(
        'same bytes, new explicit confirmation',
        knownHostBytes(),
      );
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'receiver_not_ready',
          ),
        ),
      );
      expect(service.owner.credentialExecutions, isEmpty);
    },
  );
}
