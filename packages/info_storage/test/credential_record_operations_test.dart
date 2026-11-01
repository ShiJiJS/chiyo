import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'backup_setup.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory folder;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  var now = DateTime.utc(2026, 11, 1);
  const secret = 'SYNTHETIC-credential-operation-v1';
  const note = 'SYNTHETIC-Owner-private-note';
  Matcher access(String code) =>
      throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));
  Matcher storage(String code) =>
      throwsA(isA<StorageFailure>().having((e) => e.code, 'code', code));
  CredentialRecordInput create({
    String value = secret,
    String? digest,
    CredentialForm form = CredentialForm.string,
    String? filename,
    List<int>? bytes,
  }) => CredentialRecordInput(
    action: CredentialRecordAction.create,
    commandDigest: digest ?? 'a' * 64,
    form: form,
    name: '合成凭据',
    publicPurpose: '合成用途',
    privateNote: note,
    suggestedBinding: 'GH_TOKEN',
    material: bytes ?? utf8.encode(value),
    fileName: filename,
    discoverable: true,
  );
  CredentialRecordInput edit(
    ManagedCredential c, {
    String name = '已编辑合成凭据',
    CredentialRecordAction action = CredentialRecordAction.edit,
    List<int>? bytes,
    String? filename,
    bool? enabled,
    List<String>? links,
    bool updateExpiry = false,
    DateTime? expiry,
  }) => CredentialRecordInput(
    action: action,
    commandDigest: 'b' * 64,
    credentialId: c.id,
    expectedRevision: c.revision,
    expectedMaterialVersion: c.version,
    name: action == CredentialRecordAction.setEnabled ? null : name,
    publicPurpose: action == CredentialRecordAction.setEnabled
        ? null
        : c.publicPurpose,
    privateNote: action == CredentialRecordAction.setEnabled
        ? null
        : c.privateNote,
    suggestedBinding: action == CredentialRecordAction.setEnabled
        ? null
        : c.suggestedBinding,
    material: bytes,
    fileName: filename,
    enabled: enabled,
    linkedItemIds: links,
    updateExpiry: updateExpiry,
    expiresAt: expiry,
  );
  Database inspect([String? path, TestKeyStore? store]) {
    final db = sqlite3.open(path ?? '${folder.path}/source/library.db');
    final key = (store ?? keys).key!
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$key\'"');
    return db;
  }

  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${folder.path}/source',
      keys,
      clock: () => now,
    );
    service = InformationService(
      repository: repo,
      clock: () => now,
      credentialExecutableInspector: (p, r) async =>
          ExecutableIdentity(p, 10, 100, 'sha256:${'a' * 64}'),
    );
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
  }

  Future<void> reopen() async {
    await close();
    await open();
  }

  setUp(() async {
    now = DateTime.utc(2026, 11, 1);
    folder = await Directory.systemTemp.createTemp(
      'credential-record-operations-',
    );
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await folder.delete(recursive: true);
  });

  test(
    'atomic create edit and exact receipt survive reopen without duplicate material or body journal',
    () async {
      final input = create();
      final first = await service.owner.saveCredentialRecord(
        'create-one',
        input,
      );
      final before = repo.managedCredentials.single;
      final changed = await service.owner.saveCredentialRecord(
        'edit-one',
        edit(before),
      );
      expect(changed.baseRevision, 1);
      expect(changed.revision, 2);
      expect(changed.materialVersion, 1);
      expect(changed.useGeneration, 1);
      await reopen();
      expect(
        (await service.owner.credentialRecordReceipt('create-one'))!.toJson(),
        first.toJson(),
      );
      expect(
        (await service.owner.saveCredentialRecord(
          'create-one',
          input,
        )).toJson(),
        first.toJson(),
      );
      expect(repo.managedCredentials.single.name, '已编辑合成凭据');
      expect(repo.managedCredentials.single.revision, 2);
      expect(repo.credentialMaterials.single.bytes, utf8.encode(secret));
      final db = inspect();
      try {
        final rows = db.select(
          'SELECT payload FROM information_record_operations',
        );
        expect(rows, hasLength(2));
        expect(jsonEncode(rows), isNot(contains(secret)));
        expect(jsonEncode(rows), isNot(contains(note)));
        expect(
          jsonEncode(rows),
          isNot(contains(base64Encode(utf8.encode(secret)))),
        );
      } finally {
        db.close();
      }
      expect(
        await service.owner.credentialRecordReceipt('never-submitted'),
        isNull,
      );
    },
  );

  test(
    'same identifier with changed material or command is conflict and stale versions cannot modify',
    () async {
      await service.owner.saveCredentialRecord('same', create());
      await expectLater(
        service.owner.saveCredentialRecord('same', create(value: 'different')),
        access('operation_conflict'),
      );
      await expectLater(
        service.owner.saveCredentialRecord('same', create(digest: 'c' * 64)),
        access('operation_conflict'),
      );
      final before = repo.managedCredentials.single;
      await service.owner.saveCredentialRecord('edit-first', edit(before));
      await expectLater(
        service.owner.saveCredentialRecord('edit-stale', edit(before)),
        access('credential_conflict'),
      );
      await expectLater(
        service.owner.saveCredentialRecord(
          'bad-links',
          edit(repo.managedCredentials.single, links: ['missing']),
        ),
        access('invalid_credential_links'),
      );
      expect(repo.managedCredentials, hasLength(1));
      expect(repo.credentialMaterials, hasLength(1));
    },
  );

  test(
    'receipt failure rolls back vault materials cache and original operation, same intent retries once',
    () async {
      final db = inspect();
      try {
        db.execute(
          "CREATE TRIGGER reject_credential_receipt BEFORE INSERT ON information_record_operations BEGIN SELECT RAISE(ABORT,'synthetic receipt failure'); END",
        );
        await expectLater(
          service.owner.saveCredentialRecord('retry', create()),
          storage('credential_save_failed'),
        );
        expect(repo.managedCredentials, isEmpty);
        expect(repo.credentialMaterials, isEmpty);
        expect(await service.owner.credentialRecordReceipt('retry'), isNull);
        expect(
          db
              .select('SELECT count(*) AS n FROM managed_credentials')
              .single['n'],
          0,
        );
        db.execute('DROP TRIGGER reject_credential_receipt');
      } finally {
        db.close();
      }
      await service.owner.saveCredentialRecord('retry', create());
      await reopen();
      await service.owner.saveCredentialRecord('retry', create());
      expect(repo.managedCredentials, hasLength(1));
      expect(repo.credentialMaterials, hasLength(1));
    },
  );

  test(
    'actual approved use becomes invalid after replacement and cannot revive through disable and enable',
    () async {
      await service.owner.saveCredentialRecord('create', create());
      var c = repo.managedCredentials.single;
      final session = service.agent.openSession('Synthetic operation grant');
      final request = await service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'protocolVersion': 2,
          'command': 'request-use',
          'purpose': 'Synthetic grant invalidation',
          'credentials': [
            {'alias': 'token', 'credentialId': c.id, 'version': c.version},
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
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final grant = service.owner.credentialUseRequests.single;
      expect(service.owner.credentialGrantState(grant), 'available');
      final replaced = await service.owner.saveCredentialRecord(
        'replace',
        edit(
          c,
          action: CredentialRecordAction.replaceMaterial,
          bytes: utf8.encode('SYNTHETIC-v2'),
        ),
      );
      expect(replaced.materialVersion, 2);
      expect(replaced.useGeneration, 2);
      expect(service.owner.credentialGrantState(grant), 'version_invalidated');
      c = repo.managedCredentials.single;
      expect(c.enabled, isTrue);
      await service.owner.saveCredentialRecord(
        'disable',
        edit(c, action: CredentialRecordAction.setEnabled, enabled: false),
      );
      c = repo.managedCredentials.single;
      await service.owner.saveCredentialRecord(
        'enable',
        edit(c, action: CredentialRecordAction.setEnabled, enabled: true),
      );
      expect(repo.managedCredentials.single.useGeneration, 4);
      expect(service.owner.credentialGrantState(grant), 'version_invalidated');
      expect(repo.credentialMaterials.map((m) => m.version), [1, 2]);
      expect(repo.credentialMaterials.first.retiredAt, now);
      await reopen();
      expect(service.owner.sessions, isEmpty);
      expect(repo.managedCredentials.single.version, 2);
      expect(
        (await service.owner.credentialRecordReceipt('replace'))!.toJson(),
        replaced.toJson(),
      );
    },
  );

  test(
    'file input copies submitted bytes and exact metadata survives replacement',
    () async {
      final bytes = utf8.encode('SYNTHETIC-original-file');
      final input = create(
        form: CredentialForm.file,
        filename: 'synthetic.pem',
        bytes: bytes,
      );
      bytes[0] = 0;
      await service.owner.saveCredentialRecord('file', input);
      final c = repo.managedCredentials.single;
      expect(
        repo.credentialMaterials.single.bytes,
        utf8.encode('SYNTHETIC-original-file'),
      );
      await service.owner.saveCredentialRecord(
        'file-replace',
        edit(
          c,
          action: CredentialRecordAction.replaceMaterial,
          bytes: utf8.encode('SYNTHETIC-next-file'),
          filename: 'replacement.pem',
        ),
      );
      await reopen();
      expect(repo.managedCredentials.single.fileName, 'replacement.pem');
      expect(
        repo.credentialMaterials.last.bytes,
        utf8.encode('SYNTHETIC-next-file'),
      );
      expect(repo.credentialMaterials.first.fileName, 'synthetic.pem');
    },
  );

  test(
    'different journal kinds and corrupted receipts are errors rather than confirmed absence',
    () async {
      await service.owner.saveInformationRecord(
        'shared',
        InformationDraftInput(
          name: '合成资料',
          description: '',
          fields: const [InformationDraftField.text('正文', '', 'synthetic')],
        ),
      );
      await expectLater(
        service.owner.credentialRecordReceipt('shared'),
        storage('invalid_operation_receipt'),
      );
      await expectLater(
        service.owner.saveCredentialRecord('shared', create()),
        storage('invalid_operation_receipt'),
      );
      final receipt = await service.owner.saveCredentialRecord(
        'credential',
        create(),
      );
      await expectLater(
        service.owner.informationRecordReceipt('credential'),
        throwsFormatException,
      );
      final db = inspect();
      try {
        db.execute(
          'UPDATE information_record_operations SET payload=? WHERE operation_id=?',
          [
            jsonEncode({...receipt.toJson(), 'materialVersion': 999}),
            'credential',
          ],
        );
      } finally {
        db.close();
      }
      await expectLater(
        service.owner.credentialRecordReceipt('credential'),
        storage('invalid_operation_receipt'),
      );
      expect(repo.managedCredentials, hasLength(1));
    },
  );

  test(
    'private input validation rejects malformed materials and shape without writing',
    () async {
      for (final input in [
        create(bytes: [-1]),
        create(bytes: [255]),
        create(value: 'bad\u0000value'),
        create(form: CredentialForm.file, filename: '../bad', bytes: [1]),
        create(bytes: List.filled(65537, 1)),
      ]) {
        await expectLater(
          service.owner.saveCredentialRecord('invalid', input),
          throwsA(isA<AccessFailure>()),
        );
      }
      expect(repo.managedCredentials, isEmpty);
      expect(await service.owner.credentialRecordReceipt('invalid'), isNull);
    },
  );

  test(
    'expiry changes and links commit together while unrelated vault content remains exact',
    () async {
      await service.owner.saveCredentialRecord('one', create());
      final c = repo.managedCredentials.single;
      await service.owner.saveCredentialRecord(
        'other',
        create(value: 'SYNTHETIC-unrelated'),
      );
      final other = repo.managedCredentials.last.toJson();
      final item = await service.owner.createInformation('合成关联', '', [
        const FieldInput('值', '', 'synthetic'),
      ]);
      final receipt = await service.owner.saveCredentialRecord(
        'metadata',
        edit(
          c,
          links: [item.id],
          updateExpiry: true,
          expiry: now.add(const Duration(minutes: 1)),
        ),
      );
      expect(receipt.useGeneration, 2);
      expect(repo.managedCredentials.first.linkedItemIds, [item.id]);
      expect(repo.managedCredentials.last.toJson(), other);
      await reopen();
      now = now.add(const Duration(minutes: 1));
      expect(
        service.owner.credentialAvailability(repo.managedCredentials.first),
        CredentialAvailability.expired,
      );
      final current = repo.managedCredentials.first;
      await service.owner.saveCredentialRecord(
        'clear-expiry',
        edit(current, updateExpiry: true),
      );
      expect(repo.managedCredentials.first.expiresAt, isNull);
      expect(repo.managedCredentials.first.useGeneration, 3);
    },
  );

  test(
    'backup excludes local receipts; failed restore preserves and successful restore invalidates them',
    () async {
      await service.owner.saveCredentialRecord('source-create', create());
      final recovery = await enableTestBackups(repo.backups);
      final archive = '${folder.path}/synthetic.aimbackup';
      await repo.backups.exportTo(archive);
      final targetKeys = TestKeyStore();
      final target = await EncryptedInformationRepository.open(
        '${folder.path}/target',
        targetKeys,
        clock: () => now,
      );
      final ownerService = InformationService(
        repository: target,
        clock: () => now,
      );
      try {
        final old = await ownerService.owner.saveCredentialRecord(
          'prior-local',
          create(value: 'SYNTHETIC-prior'),
        );
        // A trusted storage fixture empties recipient content but retains its
        // exact local operation journal, exercising the existing restore barrier.
        await target.commitCredentials([], []);
        await expectLater(
          ownerService.owner.restoreLibrary(
            () => target.backups.restoreFrom(archive, 'wrong'),
          ),
          throwsA(isA<StorageFailure>()),
        );
        expect(
          (await ownerService.owner.credentialRecordReceipt(
            'prior-local',
          ))!.toJson(),
          old.toJson(),
        );
        await ownerService.owner.restoreLibrary(
          () => target.backups.restoreFrom(archive, recovery),
        );
        expect(
          target.managedCredentials.single.id,
          repo.managedCredentials.single.id,
        );
        expect(target.credentialMaterials.single.bytes, utf8.encode(secret));
        expect(
          await ownerService.owner.credentialRecordReceipt('source-create'),
          isNull,
        );
        await expectLater(
          ownerService.owner.credentialRecordReceipt('prior-local'),
          access('library_changed'),
        );
      } finally {
        await ownerService.close();
        await target.close();
      }
    },
  );

  CredentialRecordChange plannedEdit(
    ManagedCredential c,
    String id, {
    void Function()? validate,
  }) => CredentialRecordChange(
    receipt: CredentialRecordReceipt(
      operationId: id,
      action: CredentialRecordAction.edit,
      inputHash: 'a' * 64,
      commandDigest: 'b' * 64,
      credentialId: c.id,
      baseRevision: c.revision,
      baseMaterialVersion: c.version,
      revision: c.revision + 1,
      materialVersion: c.version,
      useGeneration: c.useGeneration,
    ),
    previousDigest: credentialVaultDigest(
      repo.managedCredentials,
      repo.credentialMaterials,
    ),
    credentials: [
      for (final old in repo.managedCredentials)
        old.id == c.id ? old.copy(name: 'planned-name', modifiedAt: now) : old,
    ],
    materials: repo.credentialMaterials,
    validate: validate ?? () {},
  );

  test(
    'CAS compares actual SQL vault before a stale snapshot can overwrite a legacy edit',
    () async {
      await service.owner.saveCredentialRecord('cas-create', create());
      final c = repo.managedCredentials.single;
      final change = plannedEdit(c, 'cas-edit');
      final updated = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: 'legacy-writer-name',
        publicPurpose: c.publicPurpose,
        privateNote: c.privateNote,
        suggestedBinding: c.suggestedBinding,
        discoverable: c.discoverable,
      );
      await expectLater(
        repo.commitCredentialRecord(change),
        access('credential_conflict'),
      );
      expect(repo.managedCredentials.single.toJson(), updated.toJson());
      expect(await service.owner.credentialRecordReceipt('cas-edit'), isNull);
      await reopen();
      expect(repo.managedCredentials.single.name, 'legacy-writer-name');
    },
  );

  test(
    'last-moment library validation rolls back metadata and inserted receipt together',
    () async {
      await service.owner.saveCredentialRecord('late-create', create());
      final c = repo.managedCredentials.single;
      var calls = 0;
      final change = plannedEdit(
        c,
        'late-edit',
        validate: () {
          if (++calls == 2) throw const AccessFailure('library_changed');
        },
      );
      await expectLater(
        repo.commitCredentialRecord(change),
        access('library_changed'),
      );
      expect(calls, 2);
      expect(repo.managedCredentials.single.toJson(), c.toJson());
      expect(await service.owner.credentialRecordReceipt('late-edit'), isNull);
      await reopen();
      expect(repo.managedCredentials.single.toJson(), c.toJson());
      await repo.commitCredentialRecord(plannedEdit(c, 'late-edit'));
      expect(repo.managedCredentials.single.name, 'planned-name');
    },
  );

  test(
    'storage rejects a toggle plan that also changes unrelated metadata',
    () async {
      await service.owner.saveCredentialRecord('guard-create', create());
      final c = repo.managedCredentials.single;
      final change = CredentialRecordChange(
        receipt: CredentialRecordReceipt(
          operationId: 'guard-toggle',
          action: CredentialRecordAction.setEnabled,
          inputHash: 'a' * 64,
          commandDigest: 'b' * 64,
          credentialId: c.id,
          baseRevision: c.revision,
          baseMaterialVersion: c.version,
          revision: c.revision + 1,
          materialVersion: c.version,
          useGeneration: c.useGeneration + 1,
        ),
        previousDigest: credentialVaultDigest(
          repo.managedCredentials,
          repo.credentialMaterials,
        ),
        credentials: [
          c.copy(
            name: 'unexpected-metadata-edit',
            enabled: false,
            invalidateUse: true,
            modifiedAt: now,
          ),
        ],
        materials: repo.credentialMaterials,
        validate: () {},
      );
      await expectLater(
        repo.commitCredentialRecord(change),
        storage('credential_save_failed'),
      );
      expect(repo.managedCredentials.single.toJson(), c.toJson());
      expect(
        await service.owner.credentialRecordReceipt('guard-toggle'),
        isNull,
      );
    },
  );

  test(
    'old successful receipts cannot resurrect purged credentials or material',
    () async {
      final receipt = await service.owner.saveCredentialRecord(
        'purged-create',
        create(),
      );
      var c = repo.managedCredentials.single;
      c = await service.owner.deleteCredential(c.id, c.revision);
      await service.owner.permanentlyDeleteCredential(c.id, c.revision);
      await reopen();
      expect(
        (await service.owner.saveCredentialRecord(
          'purged-create',
          create(),
        )).toJson(),
        receipt.toJson(),
      );
      expect(service.owner.credentials, isEmpty);
      expect(repo.credentialMaterials, isEmpty);
      expect(repo.managedCredentials.single.purgedAt, isNotNull);
    },
  );

  test(
    'strict receipt parser rejects extra fields wrong kinds and impossible versions',
    () async {
      final good = (await service.owner.saveCredentialRecord(
        'parse',
        create(),
      )).toJson();
      for (final bad in [
        {...good, 'extra': true},
        {...good, 'action': 'unknown'},
        {...good, 'revision': 2},
        {...good, 'useGeneration': 2},
        {...good, 'type': 'information'},
        {...good, 'commandDigest': 'wrong'},
      ]) {
        expect(
          () => CredentialRecordReceipt.fromJson(bad),
          throwsFormatException,
        );
      }
    },
  );
}
