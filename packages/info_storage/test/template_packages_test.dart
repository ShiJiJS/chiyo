import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late InformationService service;
  List<int> source({String version = '1.0.0', String name = '合成模板'}) =>
      utf8.encode(
        jsonEncode({
          'id': 'local.synthetic',
          'name': name,
          'version': version,
          'hostApi': 1,
          'author': '合成测试',
          'description': '',
          'templates': [
            {
              'id': 'record',
              'name': '合成资料',
              'icon': 'file',
              'fields': [
                {
                  'key': 'body',
                  'label': '内容',
                  'type': 'text',
                  'required': false,
                },
              ],
              'sections': [
                {
                  'kind': 'fields',
                  'title': '资料',
                  'keys': ['body'],
                },
              ],
              'relations': [],
              'instructions': '',
            },
          ],
        }),
      );
  InstalledTemplatePackage package({
    String version = '1.0.0',
    String name = '合成模板',
  }) => InstalledTemplatePackage(
    id: 'local.synthetic',
    enabled: true,
    origin: 'synthetic.json',
    bytes: source(version: version, name: name),
  );
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = InformationService(repository: repo);
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
  }

  Future<TemplatePackageReceipt> change(
    TemplatePackageAction action, {
    String id = 'local.synthetic',
    InstalledTemplatePackage? input,
    String op = 'package-1',
  }) => service.owner.changeTemplatePackage(
    TemplatePackageCommand(
      operationId: op,
      action: action,
      packageId: id,
      expectedVersion: service.owner.templatePackageVersion,
      commandDigest: 'a' * 64,
      expectedDigest: input?.digest,
    ),
    input: input,
  );
  Database inspect() {
    final db = sqlite3.open('${root.path}/library.db');
    final hex = keys.key!
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('template-packages-');
    keys = TestKeyStore();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  test(
    'real install, disable and removal retain exact metadata receipts across reopen',
    () async {
      final p = package();
      final installed = await change(TemplatePackageAction.install, input: p);
      expect(service.owner.installedTemplatePackages.single.digest, p.digest);
      await change(TemplatePackageAction.disable, op: 'disable-1');
      await close();
      await open();
      expect(service.owner.installedTemplatePackages.single.enabled, isFalse);
      expect(
        (await service.owner.templatePackageReceipt('package-1'))!.digest,
        installed.digest,
      );
      await expectLater(
        change(
          TemplatePackageAction.install,
          input: package(name: '同版本不同内容'),
          op: 'conflicting',
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'package_version_conflict',
          ),
        ),
      );
      await change(TemplatePackageAction.remove, op: 'remove-1');
      expect(service.owner.installedTemplatePackages, isEmpty);
      expect(
        (await service.owner.templatePackageReceipt('remove-1'))!.digest,
        p.digest,
      );
    },
  );
  test(
    'encrypted backup15 restores exact package bytes and disabled builtin preference',
    () async {
      final p = package();
      await change(TemplatePackageAction.install, input: p);
      await change(
        TemplatePackageAction.disable,
        id: 'builtin.server',
        op: 'disable-builtin',
      );
      final directory = await service.owner.createDirectory('合成混合目录');
      await service.owner.createInformation('合成普通资料', '', [
        const FieldInput('字段', '', '合成正文'),
      ], directoryId: directory.id);
      await service.owner.saveCredentialRecord(
        'mixed-credential',
        CredentialRecordInput(
          action: CredentialRecordAction.create,
          commandDigest: 'b' * 64,
          form: CredentialForm.string,
          name: '合成凭据',
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: '',
          material: utf8.encode('SYNTHETIC-ONLY'),
          updateClassification: true,
          directoryId: directory.id,
          tagIds: const [],
        ),
      );
      final db = inspect();
      expect(db.select('PRAGMA user_version').single.values.single, 41);
      db.close();
      final recovery = await enableTestBackups(repo.backups),
          backup = '${root.path}/packages.aimbackup';
      await repo.backups.exportTo(backup);
      expect((await repo.backups.inspect(backup, recovery)).formatVersion, 15);
      final recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        TestKeyStore(),
      );
      await recipient.backups.restoreFrom(backup, recovery);
      expect(
        recipient.installedTemplatePackages
            .firstWhere((p) => p.id == 'local.synthetic')
            .bytes,
        p.bytes,
      );
      expect(
        recipient.installedTemplatePackages
            .firstWhere((p) => p.id == 'builtin.server')
            .enabled,
        isFalse,
      );
      expect(recipient.items.single.name, '合成普通资料');
      expect(recipient.managedCredentials.single.directoryId, directory.id);
      expect(
        recipient.credentialMaterials.single.bytes,
        utf8.encode('SYNTHETIC-ONLY'),
      );
      expect(await recipient.templatePackageReceipt('package-1'), isNull);
      await recipient.close();
    },
  );
  test(
    'receipt failure rolls package, catalog version and format marker back together',
    () async {
      final db = inspect();
      db.execute(
        "CREATE TRIGGER fail_package BEFORE INSERT ON template_package_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END",
      );
      db.close();
      await expectLater(
        change(TemplatePackageAction.install, input: package()),
        throwsA(isA<StorageFailure>()),
      );
      expect(service.owner.installedTemplatePackages, isEmpty);
      expect(service.owner.templatePackageVersion, 1);
      expect(await service.owner.templatePackageReceipt('package-1'), isNull);
      final after = inspect();
      expect(after.select('PRAGMA user_version').single.values.single, 38);
      after.close();
      await close();
      await open();
      expect(service.owner.installedTemplatePackages, isEmpty);
    },
  );
  test(
    'disabled template blocks stale new forms but preserves existing record edits and receipts',
    () async {
      final p = package();
      await change(TemplatePackageAction.install, input: p);
      InformationDraftInput input({
        String? id,
        int? base,
        String value = '合成值',
      }) => InformationDraftInput(
        itemId: id,
        baseVersion: base,
        name: '合成实例',
        description: '',
        fields: [
          InformationDraftField.text(
            '内容',
            '',
            value,
            fieldId: id == null
                ? null
                : service.owner.information.single.fields.single.id,
          ),
        ],
        layout: InformationDraftLayout(
          InformationLayout(
            typeId: 'local.synthetic/record',
            snapshot: {
              'definition': {
                'packageId': p.id,
                'templateVersion': '1.0.0',
                'packageDigest': p.digest,
              },
            },
            fieldIds: {},
          ),
          ['body'],
        ),
      );
      final original = input();
      final saved = await service.owner.saveInformationRecord(
        'create-1',
        original,
      );
      await change(TemplatePackageAction.disable, op: 'disable-1');
      await expectLater(
        service.owner.saveInformationRecord('create-2', input()),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'template_unavailable',
          ),
        ),
      );
      expect(
        (await service.owner.saveInformationRecord(
          'create-1',
          original,
        )).itemId,
        saved.itemId,
      );
      await service.owner.saveInformationRecord(
        'edit-1',
        input(id: saved.itemId, base: 1, value: '主人编辑'),
      );
      expect(service.owner.information.single.fields.single.value, '主人编辑');
    },
  );
}
