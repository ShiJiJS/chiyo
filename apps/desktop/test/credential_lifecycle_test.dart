import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/credential_mutation.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
Matcher fails(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
WorkspaceCredentialChange command(
  WorkspaceCredentialDetail d,
  String id,
  WorkspaceCredentialAction action, {
  int? material,
  String? entry,
  int? catalog,
}) => WorkspaceCredentialChange(
  operationId: id,
  ref: d.record.ref,
  expectedRecordVersion: d.recordVersion,
  expectedMaterialVersion: d.materialVersion,
  action: action,
  materialVersion: material,
  entryId: entry,
  expectedCatalogVersion: catalog,
);
Future<WorkspaceCredentialReceipt> rotate(
  SampleWorkspaceSource s,
  String op,
) async {
  final d = await s.credentials.read(ssh);
  return s.credentials.save(
    WorkspaceCredentialWrite(
      operationId: op,
      ref: ssh,
      expectedRecordVersion: d.recordVersion,
      expectedMaterialVersion: d.materialVersion,
      name: d.record.name,
      purpose: d.record.description,
      privateNote: '保留私有备注',
      binding: d.binding,
      directoryId: d.record.directoryId,
      tagIds: d.record.tags.map((t) => t.id),
      candidateId: 'ssh-file',
    ),
  );
}

void main() {
  late SampleWorkspaceSource s;
  late DateTime now;
  setUp(() {
    now = DateTime.utc(2026, 10, 27);
    s = SampleWorkspaceSource(now: () => now);
  });
  tearDown(() => s.dispose());
  test(
    'material restoration is versioned, disables use and preserves current owner metadata',
    () async {
      final initial = await s.credentials.materials(ssh);
      expect(initial.materials.single.version, 1);
      await rotate(s, 'rotate');
      final current = await s.credentials.read(ssh);
      final receiver = (await s.credentials.receivers(ssh)).single,
          session = (await s.credentials.sessions()).first;
      await s.credentials.requestUse(
        WorkspaceCredentialUseDraft(
          operationId: 'request',
          ref: ssh,
          expectedRecordVersion: current.recordVersion,
          expectedMaterialVersion: current.materialVersion,
          useGeneration: current.useGeneration,
          purpose: '合成核对',
          receiverId: receiver.id,
          sessionId: session.id,
        ),
      );
      final cmd = command(
        current,
        'restore',
        WorkspaceCredentialAction.restoreMaterial,
        material: 1,
      );
      s.nextSaveFailure = const WorkspaceFailure('offline', '恢复失败');
      await expectLater(s.credentials.change(cmd), fails('offline'));
      expect((await s.credentials.read(ssh)).materialVersion, 2);
      final results = await Future.wait([
        s.credentials.change(cmd),
        s.credentials.change(cmd),
      ]);
      expect(identical(results.first, results.last), isTrue);
      final d = await s.credentials.read(ssh);
      expect(d.materialVersion, 3);
      expect(d.enabled, isFalse);
      expect(d.filename, 'azure-jp.pem');
      expect(d.privateNote, '保留私有备注');
      expect(d.record.name, current.record.name);
      expect(d.delivery, current.delivery);
      expect(d.linkedInformation, current.linkedInformation);
      expect(d.useGeneration, current.useGeneration + 1);
      expect(
        (await s.credentials.requests(ref: ssh)).single.state,
        WorkspaceCredentialRequestState.superseded,
      );
      expect(
        (await s.credentials.materials(ssh)).materials.map((v) => v.version),
        [3, 2, 1],
      );
      expect(initial.materials.single.retiredAt, isNull);
      await expectLater(
        s.credentials.change(
          command(
            current,
            'stale',
            WorkspaceCredentialAction.restoreMaterial,
            material: 1,
          ),
        ),
        fails('conflict'),
      );
    },
  );
  test(
    'recycle uses shared list, archives metadata, invalidates pending and restores disabled to a new head',
    () async {
      final d = await s.credentials.read(ssh);
      final count = (await s.loadSummary()).records;
      final oldPeer = await s.readDetail(azure);
      final receiver = (await s.credentials.receivers(ssh)).single;
      final session = (await s.credentials.sessions()).first;
      final pending = await s.credentials.requestUse(
        WorkspaceCredentialUseDraft(
          operationId: 'pending-before-recycle',
          ref: ssh,
          expectedRecordVersion: d.recordVersion,
          expectedMaterialVersion: d.materialVersion,
          useGeneration: d.useGeneration,
          purpose: '回收失效验证',
          receiverId: receiver.id,
          sessionId: session.id,
        ),
      );
      expect((await s.loadSummary()).pending, 6);
      final c = command(d, 'recycle', WorkspaceCredentialAction.recycle);
      final receipt = await s.credentials.change(c);
      expect(identical(await s.credentials.change(c), receipt), isTrue);
      expect((await s.loadSummary()).records, count - 1);
      expect((await s.loadSummary()).pending, 5);
      expect(
        (await s.credentials.requests())
            .singleWhere((r) => r.id == pending.requestId)
            .state,
        WorkspaceCredentialRequestState.recycled,
      );
      expect(
        (await s.readDetail(azure)).relations['credentials'],
        isNot(contains(ssh)),
      );
      expect((await s.readDetail(azure)).version, greaterThan(oldPeer.version));
      await expectLater(s.credentials.read(ssh), fails('not_found'));
      final entries = await s.queryRecycled(keyword: 'Azure SSH');
      expect(entries.total, 1);
      final recycled = await s.credentials.readRecycled(receipt.entryId!);
      expect(recycled.detail.enabled, isFalse);
      expect(recycled.detail.recordVersion, receipt.recordVersion);
      expect(recycled.detail.mask, '••••••••');
      expect(recycled.restored.enabled, isFalse);
      expect(recycled.restored.materialVersion, 2);
      final restore = command(
        recycled.detail,
        'restore-recycled',
        WorkspaceCredentialAction.restoreRecycled,
        entry: receipt.entryId,
        catalog: recycled.catalogVersion,
      );
      await s.credentials.change(restore);
      final current = await s.credentials.read(ssh);
      expect(current.materialVersion, 2);
      expect(current.enabled, isFalse);
      expect(current.linkedInformation, d.linkedInformation);
      expect((await s.queryRecycled(keyword: 'Azure SSH')).total, 0);
      expect((await s.loadSummary()).records, count);
      expect(
        (await s.readDetail(azure)).relations['credentials'],
        contains(ssh),
      );
      expect((await s.readDetail(ssh)).values, isEmpty);
      await expectLater(
        s.credentials.readRecycled(receipt.entryId!),
        fails('not_found'),
      );
    },
  );
  test(
    'permanent purge and expiration do not replay material or private metadata into existence',
    () async {
      final saved = await rotate(s, 'saved-material');
      final d = await s.credentials.read(ssh);
      final recycle = await s.credentials.change(
        command(d, 'recycle', WorkspaceCredentialAction.recycle),
      );
      final r = await s.credentials.readRecycled(recycle.entryId!);
      final purge = command(
        r.detail,
        'purge',
        WorkspaceCredentialAction.purge,
        entry: r.entry.id,
      );
      s.nextSaveFailure = const WorkspaceFailure('offline', '清理失败');
      await expectLater(s.credentials.change(purge), fails('offline'));
      expect(
        (await s.credentials.readRecycled(r.entry.id)).detail.privateNote,
        '保留私有备注',
      );
      await s.credentials.change(purge);
      expect((await s.queryRecycled(keyword: 'Azure SSH')).total, 0);
      await expectLater(
        s.credentials.readRecycled(r.entry.id),
        fails('not_found'),
      );
      expect(await s.credentials.receipt('saved-material'), same(saved));
      expect(await s.credentials.receipt('purge'), isNotNull);
      await expectLater(s.credentials.materials(ssh), fails('not_found'));
      s.reset();
      await s.loadSummary();
      final expiring = await s.credentials.change(
        command(
          await s.credentials.read(ssh),
          'expire',
          WorkspaceCredentialAction.recycle,
        ),
      );
      now = now.add(const Duration(days: 30));
      expect((await s.queryRecycled(keyword: 'Azure SSH')).total, 0);
      await expectLater(
        s.credentials.readRecycled(expiring.entryId!),
        fails('not_found'),
      );
    },
  );
  test(
    'retired materials expire independently and restore refuses current or missing versions',
    () async {
      await rotate(s, 'rotate');
      var d = await s.credentials.read(ssh);
      await expectLater(
        s.credentials.change(
          command(
            d,
            'current',
            WorkspaceCredentialAction.restoreMaterial,
            material: 2,
          ),
        ),
        fails('conflict'),
      );
      now = now.add(const Duration(days: 30));
      expect(
        (await s.credentials.materials(ssh)).materials.map((m) => m.version),
        [2],
      );
      await expectLater(
        s.credentials.change(
          command(
            d,
            'expired',
            WorkspaceCredentialAction.restoreMaterial,
            material: 1,
          ),
        ),
        fails('material_unavailable'),
      );
    },
  );
  test(
    'restore normalizes removed classifications and links, rechecks catalog and never revives a purged object',
    () async {
      var catalog = await s.loadCatalog();
      final dir = (await s.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'directory',
          expectedVersion: catalog.version,
          action: WorkspaceDirectoryAction.create,
          name: '凭据回收验证',
        ),
      ))!;
      var d = await s.credentials.read(ssh);
      await s.credentials.save(
        WorkspaceCredentialWrite(
          operationId: 'classify',
          ref: ssh,
          expectedRecordVersion: d.recordVersion,
          expectedMaterialVersion: d.materialVersion,
          name: d.record.name,
          purpose: d.record.description,
          binding: d.binding,
          directoryId: dir.id,
          linkedInformation: [azure],
        ),
      );
      d = await s.credentials.read(ssh);
      final recycled = await s.credentials.change(
        command(d, 'recycle-classified', WorkspaceCredentialAction.recycle),
      );
      final before = await s.credentials.readRecycled(recycled.entryId!);
      catalog = await s.loadCatalog();
      await s.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'remove-directory',
          expectedVersion: catalog.version,
          action: WorkspaceDirectoryAction.delete,
          directoryId: dir.id,
        ),
      );
      await expectLater(
        s.credentials.change(
          command(
            before.detail,
            'stale-catalog',
            WorkspaceCredentialAction.restoreRecycled,
            entry: before.entry.id,
            catalog: before.catalogVersion,
          ),
        ),
        fails('conflict'),
      );
      final info = await s.readDetail(azure);
      final infoRecycle = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'remove-info',
          ref: azure,
          expectedVersion: info.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'purge-info',
          ref: azure,
          expectedVersion: infoRecycle.version,
          action: WorkspaceRecordAction.purge,
          entryId: infoRecycle.entryId,
        ),
      );
      final preview = await s.credentials.readRecycled(recycled.entryId!);
      expect(preview.detail.record.directoryId, dir.id);
      expect(preview.restored.record.directoryId, isNull);
      expect(preview.restored.linkedInformation, isEmpty);
      expect(preview.notices.join(), contains('原目录已移除'));
      expect(preview.notices.join(), contains('关联资料'));
      final restore = command(
        preview.detail,
        'restore-normalized',
        WorkspaceCredentialAction.restoreRecycled,
        entry: preview.entry.id,
        catalog: preview.catalogVersion,
      );
      final restored = await s.credentials.change(restore);
      d = await s.credentials.read(ssh);
      expect(d.record.directoryId, isNull);
      expect(d.linkedInformation, isEmpty);
      expect(d.enabled, isFalse);
      final again = await s.credentials.change(
        command(d, 'delete-again', WorkspaceCredentialAction.recycle),
      );
      final r = await s.credentials.readRecycled(again.entryId!);
      await s.credentials.change(
        command(
          r.detail,
          'purge-again',
          WorkspaceCredentialAction.purge,
          entry: r.entry.id,
        ),
      );
      expect(await s.credentials.change(restore), same(restored));
      await expectLater(s.credentials.read(ssh), fails('not_found'));
      expect((await s.queryRecycled(keyword: 'Azure SSH')).total, 0);
    },
  );
  test(
    'lost recycle reply retains the original operation and failed query cannot repeat deletion',
    () async {
      final d = await s.credentials.read(ssh),
          mutation = CredentialMutation(s.credentials, expectedRef: ssh);
      addTearDown(mutation.dispose);
      var writes = 0;
      await mutation.submit((id) async {
        writes++;
        await s.credentials.change(
          command(d, id, WorkspaceCredentialAction.recycle),
        );
        throw const WorkspaceFailure('unknown_outcome', '回执丢失');
      });
      expect(mutation.uncertain, isTrue);
      expect((await s.queryRecycled(keyword: 'Azure SSH')).total, 1);
      s.setScenario(SampleWorkspaceScenario.failure);
      expect(await mutation.reconcile(), isNull);
      expect(mutation.uncertain, isTrue);
      await mutation.submit((_) async {
        writes++;
        throw StateError('must not replay');
      });
      expect(writes, 1);
      s.setScenario(SampleWorkspaceScenario.ready);
      final receipt = await mutation.reconcile();
      expect(receipt?.entryId, isNotNull);
      expect(mutation.uncertain, isFalse);
      expect(
        (await s.queryRecycled(keyword: 'Azure SSH')).items.single.id,
        receipt!.entryId,
      );
      expect(writes, 1);
    },
  );
}
