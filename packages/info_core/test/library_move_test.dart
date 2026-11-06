import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/credential_import_fixture.dart';

Matcher failure(String code) =>
    throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));

void main() {
  late MemoryInformationRepository repo;
  late InformationService service;
  setUp(() {
    repo = MemoryInformationRepository();
    service = InformationService(
      repository: repo,
      credentialExecutableInspector: (path, receiver) async =>
          ExecutableIdentity(path, 10, 100, 'sha256:fixture'),
    );
    configureCredentialImports(service);
  });
  tearDown(() => service.close());

  Future<ManagedCredential> credential(String? directory) async {
    final session = service.agent.openSession('合成移动');
    final id = await service.agent.submitImport(session, [
      ImportItemInput(
        '凭据',
        '',
        [],
        key: 'token',
        directoryId: directory,
        templateId: 'credential.token',
        templateVersion: '1',
        templateDigest: 'c' * 64,
        credential: CredentialImportInput.agentString('PRIVATE-TOKEN'),
      ),
    ]);
    final p = service.owner.importProposals.singleWhere((p) => p.id == id);
    await service.owner.confirmImport(id, p.version, p.items);
    return service.owner.credentials.last;
  }

  test(
    'mixed selection moves roots once, keeps subtrees and contents, and preserves grants',
    () async {
      final parent = await service.owner.createDirectory('服务');
      final child = await service.owner.createDirectory(
        '配置',
        parentId: parent.id,
      );
      final target = await service.owner.createDirectory('目标');
      final nested = await service.owner.createInformation('嵌套资料', '', [
        const FieldInput('正文', '', 'PRIVATE-BODY'),
      ], directoryId: child.id);
      final direct = await service.owner.createInformation('独立资料', '', [
        const FieldInput('正文', '', 'PRIVATE-DIRECT'),
      ]);
      final outside = await service.owner.createInformation('不处理', '', [
        const FieldInput('正文', '', 'PRIVATE-OUTSIDE'),
      ]);
      final insideCredential = await credential(child.id);
      final directCredential = await credential(null);
      final originalMaterials = jsonEncode(
        repo.credentialMaterials.map((m) => m.toStorageJson()).toList(),
      );
      final field = FieldRef(direct.id, direct.fields.single.id);
      final session = service.agent.openSession('读取资料');
      final request = service.agent.request(session, '合成验证', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      final selection = LibrarySelection(
        directoryIds: [child.id, parent.id, parent.id],
        informationIds: [nested.id, direct.id],
        credentialIds: [insideCredential.id, directCredential.id],
      );
      final preview = await service.owner.previewLibraryMove(
        selection,
        target.id,
      );
      expect(preview.roots, [parent.id]);
      expect(preview.records.map((r) => r.id).toSet(), {
        direct.id,
        directCredential.id,
      });
      expect(preview.scope.records, hasLength(4));
      expect(preview.targetPath, ['目标']);
      expect(jsonEncode(preview.scope.toJson()), isNot(contains('PRIVATE-')));
      final receipt = await service.owner.moveLibrarySelection(
        'move-mixed',
        selection,
        target.id,
        preview.token,
      );
      expect(receipt.directoryIds, [parent.id]);
      expect(receipt.informationIds, [direct.id]);
      expect(receipt.credentialIds, [directCredential.id]);
      expect(
        service.owner.directories
            .singleWhere((d) => d.id == parent.id)
            .parentId,
        target.id,
      );
      expect(
        service.owner.directories.singleWhere((d) => d.id == child.id).version,
        child.version,
      );
      expect(
        service.owner.information
            .singleWhere((i) => i.id == nested.id)
            .directoryId,
        child.id,
      );
      final next = service.owner.information.singleWhere(
        (i) => i.id == direct.id,
      );
      expect(next.directoryId, target.id);
      expect(next.fields.single.id, direct.fields.single.id);
      expect(next.fields.single.value, 'PRIVATE-DIRECT');
      expect(next.version, direct.version + 1);
      expect(
        informationToJson(
          service.owner.information.singleWhere((i) => i.id == outside.id),
        ),
        informationToJson(outside),
      );
      expect(await service.agent.read(grant.token, field), 'PRIVATE-DIRECT');
      final c = service.owner.credentials.singleWhere(
        (c) => c.id == directCredential.id,
      );
      expect(c.directoryId, target.id);
      expect(c.version, directCredential.version);
      expect(c.useGeneration, directCredential.useGeneration);
      expect(c.enabled, directCredential.enabled);
      expect(c.revision, directCredential.revision + 1);
      expect(
        jsonEncode(
          repo.credentialMaterials.map((m) => m.toStorageJson()).toList(),
        ),
        originalMaterials,
      );
      expect(service.owner.recycleEntries, isEmpty);
      await service.owner.updateDirectory(
        target.id,
        '后来更名',
        expectedVersion: target.version,
      );
      expect(
        (await service.owner.moveLibrarySelection(
          'move-mixed',
          selection,
          target.id,
          preview.token,
        )).toJson(),
        receipt.toJson(),
      );
      await expectLater(
        service.owner.moveLibrarySelection(
          'move-mixed',
          selection,
          null,
          preview.token,
        ),
        failure('operation_conflict'),
      );
    },
  );

  test(
    'rejects cycles, target collisions and colliding selected roots without partial changes',
    () async {
      final first = await service.owner.createDirectory('第一处');
      final second = await service.owner.createDirectory('第二处');
      final a = await service.owner.createDirectory('同名', parentId: first.id);
      final b = await service.owner.createDirectory('同名', parentId: second.id);
      final child = await service.owner.createDirectory('子目录', parentId: a.id);
      final target = await service.owner.createDirectory('目标');
      await service.owner.createDirectory(' 同名 ', parentId: target.id);
      final before = service.owner.directories
          .map((d) => [d.id, d.parentId, d.version])
          .toList();
      for (final entry in [
        (LibrarySelection(directoryIds: [a.id]), a.id),
        (LibrarySelection(directoryIds: [a.id]), child.id),
        (LibrarySelection(directoryIds: [a.id]), target.id),
        (LibrarySelection(directoryIds: [a.id, b.id]), null),
      ]) {
        final preview = await service.owner.previewLibraryMove(
          entry.$1,
          entry.$2,
        );
        expect(preview.canMove, isFalse);
        expect(preview.conflicts, isNotEmpty);
        await expectLater(
          service.owner.moveLibrarySelection(
            'conflict-${entry.$2}',
            entry.$1,
            entry.$2,
            preview.token,
          ),
          failure('library_move_conflict'),
        );
      }
      expect(
        service.owner.directories
            .map((d) => [d.id, d.parentId, d.version])
            .toList(),
        before,
      );
    },
  );

  test(
    'stale review, removed target and missing selected identities never move',
    () async {
      final parent = await service.owner.createDirectory('原目录');
      final target = await service.owner.createDirectory('目标');
      final selection = LibrarySelection(directoryIds: [parent.id]);
      final preview = await service.owner.previewLibraryMove(
        selection,
        target.id,
      );
      await service.owner.createDirectory('新子目录', parentId: parent.id);
      await expectLater(
        service.owner.moveLibrarySelection(
          'stale',
          selection,
          target.id,
          preview.token,
        ),
        failure('library_selection_changed'),
      );
      await service.owner.deleteDirectory(target.id, target.version);
      await expectLater(
        service.owner.previewLibraryMove(selection, target.id),
        failure('move_target_missing'),
      );
      await expectLater(
        service.owner.previewLibraryMove(
          LibrarySelection(informationIds: ['missing']),
          null,
        ),
        failure('library_selection_changed'),
      );
      expect(
        service.owner.directories.firstWhere((d) => d.id == parent.id).parentId,
        isNull,
      );
    },
  );

  test(
    'root destination unfiles records; same placement makes no new revisions',
    () async {
      final d = await service.owner.createDirectory('原位置');
      final i = await service.owner.createInformation('资料', '', [
        const FieldInput('正文', '', 'value'),
      ], directoryId: d.id);
      final c = await credential(d.id);
      final selection = LibrarySelection(
        informationIds: [i.id],
        credentialIds: [c.id],
      );
      var p = await service.owner.previewLibraryMove(selection, null);
      await service.owner.moveLibrarySelection(
        'unfile',
        selection,
        null,
        p.token,
      );
      final next = service.owner.information.single;
      final nextCredential = service.owner.credentials.single;
      expect(next.directoryId, isNull);
      expect(nextCredential.directoryId, isNull);
      p = await service.owner.previewLibraryMove(selection, null);
      final receipt = await service.owner.moveLibrarySelection(
        'same-position',
        selection,
        null,
        p.token,
      );
      expect(receipt.informationIds, isEmpty);
      expect(receipt.credentialIds, isEmpty);
      expect(service.owner.information.single.version, next.version);
      expect(
        service.owner.credentials.single.revision,
        nextCredential.revision,
      );
    },
  );

  test(
    'receipt is metadata only and rejects malformed or unknown payloads',
    () {
      final r = LibraryMoveReceipt(
        operationId: 'op',
        inputHash: 'a' * 64,
        targetId: null,
        targetPath: [],
        directoryIds: [],
        informationIds: ['item'],
        credentialIds: [],
      );
      expect(LibraryMoveReceipt.fromJson(r.toJson()).toJson(), r.toJson());
      for (final value in [
        {...r.toJson(), 'format': 2},
        {...r.toJson(), 'body': 'unexpected'},
        {...r.toJson(), 'targetId': 'missing-path'},
        {
          ...r.toJson(),
          'information': ['same', 'same'],
        },
        {...r.toJson(), 'inputHash': ''},
      ]) {
        expect(() => LibraryMoveReceipt.fromJson(value), throwsFormatException);
      }
    },
  );

  test(
    'an already approved credential remains usable after classification moves',
    () async {
      var c = await service.owner.createStringCredential(
        name: '合成凭据',
        publicPurpose: '',
        secret: 'PRIVATE-TOKEN',
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
      final session = service.agent.openSession('合成凭据使用');
      final request = await service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'command': 'request-use',
          'purpose': '合成验证',
          'credentials': [
            {'alias': 'token', 'credentialId': c.id, 'version': c.version},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': Platform.resolvedExecutable,
            'argv': ['api', 'user', '--method', 'GET'],
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
      final target = await service.owner.createDirectory('新位置');
      final selection = LibrarySelection(credentialIds: [c.id]);
      final p = await service.owner.previewLibraryMove(selection, target.id);
      await service.owner.moveLibrarySelection(
        'credential-move',
        selection,
        target.id,
        p.token,
      );
      expect(
        (await service.agent.consumeCredentialUse(
          session,
          request.id,
        )).credentialMaterial.stringValue,
        'PRIVATE-TOKEN',
      );
      expect(service.owner.credential(c.id).useGeneration, c.useGeneration);
    },
  );
}
