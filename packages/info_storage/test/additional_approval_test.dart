import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = InformationService(
      repository: repo,
      credentialExecutableInspector: (p, r) async =>
          ExecutableIdentity(p, 10, 100, 'sha256:fixture'),
    );
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('additional-decision-');
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  void trigger() {
    final db = sqlite3.open('${root.path}/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    db.execute(
      "CREATE TRIGGER fail_receipt BEFORE INSERT ON additional_approval_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
    );
    db.close();
  }

  Future<void> decide(String kind, String id, Future<void> Function() action) =>
      service.owner.performAdditionalApproval(
        operationId: 'test-$kind',
        requestId: id,
        kind: kind,
        action: InformationApprovalAction.approve,
        reviewToken: 'a' * 64,
        commandDigest: 'b' * 64,
        validate: () {},
        decide: action,
      );
  test(
    'credential receipt failure rolls original decision and grant back',
    () async {
      final c = await service.owner.createStringCredential(
        name: '合成凭据',
        publicPurpose: '',
        secret: 'SYNTHETIC',
      );
      await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
      final item = await service.owner.createInformation('合成资料', '', [
        const FieldInput('字段', '', '内容'),
      ]);
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('合成聊天');
      final r = await service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'protocolVersion': 2,
          'command': 'request-use',
          'readFields': [field.toJson()],
          'purpose': '合成审批',
          'credentials': [
            {'alias': 'token', 'credentialId': c.id, 'version': c.version},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'user', '--method', 'GET'],
            'cwd': root.path,
            'env': {
              'GH_TOKEN': {'secret': 'token'},
            },
          },
        }),
      );
      trigger();
      await expectLater(
        decide(
          'credential',
          r.id,
          () => service.owner.decideCredentialUse(
            r.id,
            approveCredential: true,
            fields: [field],
          ),
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'audit_unavailable',
          ),
        ),
      );
      expect(service.owner.credentialUseRequests.single.state, 'pending');
      expect(repo.grantHistory, isEmpty);
      expect(
        service.owner.credentialUseRequests.single.credentialApproved,
        false,
      );
      expect(
        await service.owner.additionalApprovalReceipt('test-credential'),
        isNull,
      );
      await close();
      await open();
      // Closing cancels an unapproved request; it must never resurrect a grant.
      expect(service.owner.credentialUseRequests.single.state, 'cancelled');
      expect(
        service.owner.credentialUseRequests.single.credentialApproved,
        false,
      );
    },
  );
  test('organization receipt failure rolls scope and decision back', () async {
    final item = await service.owner.createInformation('合成资料', '', [
      const FieldInput('字段', '', '内容'),
    ]);
    final session = service.agent.openSession('合成聊天');
    final task = await service.agent.requestOrganization(session, '合成整理', [
      item.id,
    ]);
    trigger();
    await expectLater(
      decide(
        'organization',
        task.id,
        () => service.owner.approveOrganization(task.id, [item.id]),
      ),
      throwsA(isA<StorageFailure>()),
    );
    expect(
      service.owner.organizationTasks.single.state,
      OrganizationTaskState.pending,
    );
    expect(
      await service.owner.additionalApprovalReceipt('test-organization'),
      isNull,
    );
    await close();
    await open();
    expect(
      service.owner.organizationTasks.single.state,
      OrganizationTaskState.pending,
    );
  });
  test(
    'known_hosts receipt failure rolls receiver trust material back',
    () async {
      final algorithm = utf8.encode('ssh-ed25519');
      final key = base64Encode([
        0,
        0,
        0,
        algorithm.length,
        ...algorithm,
        0,
        0,
        0,
        32,
        ...List.filled(32, 7),
      ]);
      final bytes = utf8.encode('synthetic.example ssh-ed25519 $key\n');
      trigger();
      await expectLater(
        decide('ssh', 'ssh-trust', () async {
          await service.owner.configureSshKnownHosts('known_hosts', bytes);
        }),
        throwsA(isA<StorageFailure>()),
      );
      expect(service.owner.sshKnownHosts, isNull);
      expect(await service.owner.additionalApprovalReceipt('test-ssh'), isNull);
      await close();
      await open();
      expect(service.owner.sshKnownHosts, isNull);
    },
  );
}
