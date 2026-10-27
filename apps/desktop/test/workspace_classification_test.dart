import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/classification_controller.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_approvals_test.dart' show decision;

String classificationFixture() {
  final data = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
  data.remove('trash');
  for (final row in data['records'] as List) {
    if (['azure', 'sshkey'].contains(row['id'])) {
      row['tags'] = [...List<dynamic>.from(row['tags'] ?? []), 'Mac 分类验收'];
    }
  }
  data['tags'] = [
    for (var i = 0; i < 45; i++) '空标签 ${i.toString().padLeft(2, '0')}',
  ];
  return jsonEncode(data);
}

class ClassificationPort extends SampleWorkspaceSource {
  ClassificationPort() : super(fixtureJson: classificationFixture());
  final writes = <WorkspaceClassificationChange>[], lookups = <String>[];
  bool absent = false, wrong = false, lookupFailure = false;
  Future<WorkspaceCatalog> Function()? catalogOverride;
  int details = 0;
  WorkspaceClassificationReceipt project(WorkspaceClassificationReceipt r) =>
      !wrong
      ? r
      : WorkspaceClassificationReceipt(
          operationId: r.operationId,
          commandDigest: 'wrong',
          expectedVersion: r.expectedVersion,
          version: r.version,
          targetId: r.targetId,
          directory: r.directory,
          tag: r.tag,
        );
  @override
  Future<WorkspaceClassificationReceipt> changeClassification(
    WorkspaceClassificationChange c,
  ) async {
    writes.add(c);
    if (absent) throw const WorkspaceFailure('unknown_outcome', '结果未知');
    return project(await super.changeClassification(c));
  }

  @override
  Future<WorkspaceClassificationReceipt?> classificationOperationReceipt(
    String id,
  ) async {
    lookups.add(id);
    if (lookupFailure) throw const WorkspaceFailure('offline', '查询失败');
    final r = await super.classificationOperationReceipt(id);
    return r == null ? null : project(r);
  }

  @override
  Future<WorkspaceCatalog> loadCatalog() =>
      catalogOverride?.call() ?? super.loadCatalog();
  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) {
    details++;
    return super.readDetail(ref);
  }
}

void main() {
  const info = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
      secret = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  late ClassificationPort s;
  setUp(() => s = ClassificationPort());
  tearDown(() => s.dispose());
  Future<WorkspaceTag> shared() async =>
      (await s.loadCatalog()).tags.firstWhere((t) => t.name == 'Mac 分类验收');
  Future<WorkspaceClassificationReceipt> remove(WorkspaceTag tag) async {
    final p = await s.previewTagRemoval(tag.id);
    return s.changeClassification(
      WorkspaceTagChange(
        operationId: workspaceOperationId(),
        expectedVersion: p.catalogVersion,
        action: WorkspaceTagAction.delete,
        tagId: tag.id,
        removalToken: p.token,
      ),
    );
  }

  test(
    'tag rename keeps identity, current metadata search and both record kinds; names and duplicate operations are validated',
    () async {
      final tag = await shared(),
          a = await s.readDetail(info),
          b = await s.readDetail(secret),
          version = (await s.loadCatalog()).version;
      final c = WorkspaceTagChange(
        operationId: 'rename',
        expectedVersion: version,
        action: WorkspaceTagAction.update,
        tagId: tag.id,
        name: 'Mac 共用分类',
      );
      final r = await s.changeClassification(c);
      expect(r.matches(c), true);
      expect(r.targetId, tag.id);
      expect(await s.changeClassification(c), same(r));
      final rows = await s.queryRecords(
        WorkspaceQuery(keyword: 'Mac 共用分类', tagId: tag.id),
      );
      expect(rows.items.map((r) => r.ref).toSet(), {info, secret});
      expect(
        rows.items.every(
          (r) => r.tags.any((t) => t.id == tag.id && t.name == 'Mac 共用分类'),
        ),
        true,
      );
      for (final old in [a, b]) {
        final now = await s.readDetail(old.record.ref);
        expect(now.version, old.version);
        expect(now.fieldIds, old.fieldIds);
        expect(now.values, old.values);
        expect(now.relations, old.relations);
      }
      await expectLater(
        s.changeClassification(
          WorkspaceTagChange(
            operationId: 'rename',
            expectedVersion: version,
            action: WorkspaceTagAction.update,
            tagId: tag.id,
            name: '其他',
          ),
        ),
        fails('operation_conflict'),
      );
      final fresh = (await s.loadCatalog()).version;
      await expectLater(
        s.changeClassification(
          WorkspaceTagChange(
            operationId: 'duplicate',
            expectedVersion: fresh,
            action: WorkspaceTagAction.create,
            name: 'mac 共用分类',
          ),
        ),
        fails('validation'),
      );
      await expectLater(
        s.changeClassification(
          WorkspaceTagChange(
            operationId: 'invalid',
            expectedVersion: fresh,
            action: WorkspaceTagAction.create,
            name: '\u0000',
          ),
        ),
        fails('validation'),
      );
    },
  );
  test(
    'tag removal commits reviewed members, revisions and catalog atomically without changing content, fields, credential relations or existing grants',
    () async {
      final tag = await shared(),
          a = await s.readDetail(info),
          b = await s.readDetail(secret);
      await s.approvals.change(decision(await s.approvals.read('server')));
      final grant = await s.approvals.read('server');
      final library = LibraryController(s);
      addTearDown(library.dispose);
      await library.load(WorkspaceQuery(tagId: tag.id));
      final p = await s.previewTagRemoval(tag.id);
      expect(p.affectedCount, 2);
      expect((await s.readDetail(info)).version, a.version);
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '无法保存');
      final command = WorkspaceTagChange(
        operationId: 'remove-tag',
        expectedVersion: p.catalogVersion,
        action: WorkspaceTagAction.delete,
        tagId: tag.id,
        removalToken: p.token,
      );
      await expectLater(s.changeClassification(command), fails('disk_full'));
      expect((await s.loadCatalog()).tags.any((t) => t.id == tag.id), true);
      expect((await s.readDetail(info)).version, a.version);
      final r = await s.changeClassification(command);
      expect(r.matches(command), true);
      for (final old in [a, b]) {
        final now = await s.readDetail(old.record.ref);
        expect(now.version, old.version + 1);
        expect(now.record.tags.any((t) => t.id == tag.id), false);
        expect(now.values, old.values);
        expect(now.fieldIds, old.fieldIds);
        expect(now.relations, old.relations);
      }
      final after = await s.approvals.read('server');
      expect(after.request.state, WorkspaceApprovalState.approved);
      expect(after.approved, grant.approved);
      expect(after.credentialExpiresAt, grant.credentialExpiresAt);
      await library.load(WorkspaceQuery(tagId: tag.id));
      expect(library.query.tagId, isNull);
      expect(library.scopeNotice, contains('已移除'));
      await expectLater(
        s.queryRecords(WorkspaceQuery(tagId: tag.id)),
        fails('tag_unavailable'),
      );
      final preview = await s.previewRevision(
        info,
        a.version,
        expectedVersion: a.version + 1,
      );
      expect(
        preview.archive.detail.record.tags.any((t) => t.id == tag.id),
        true,
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore-old',
          ref: info,
          expectedVersion: a.version + 1,
          action: WorkspaceRecordAction.restoreRevision,
          revisionVersion: a.version,
          expectedCatalogVersion: preview.catalogVersion,
        ),
      );
      expect(
        (await s.readDetail(info)).record.tags.any((t) => t.id == tag.id),
        false,
      );
      expect((await s.loadCatalog()).tags.any((t) => t.id == tag.id), false);
    },
  );
  test(
    'recycled snapshots retain deleted tag IDs and restoring never recreates a removed tag',
    () async {
      final tag = await shared(), old = await s.readDetail(info);
      final recycled = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'recycle',
          ref: info,
          expectedVersion: old.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      expect((await s.previewTagRemoval(tag.id)).affectedCount, 1);
      await remove(tag);
      final archive = await s.readRecycled(recycled.entryId!);
      expect(archive.detail.record.tags.any((t) => t.id == tag.id), true);
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore',
          ref: info,
          entryId: recycled.entryId,
          expectedVersion: recycled.version,
          action: WorkspaceRecordAction.restoreRecycled,
          expectedCatalogVersion: (await s.loadCatalog()).version,
        ),
      );
      expect(
        (await s.readDetail(info)).record.tags.any((t) => t.id == tag.id),
        false,
      );
    },
  );
  test(
    'same affected count with a changed member version still invalidates removal confirmation',
    () async {
      final tag = await shared(),
          p = await s.previewTagRemoval(tag.id),
          old = await s.readDetail(info);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'concurrent',
          expectedVersion: old.version,
          record: old.record.copyWith(description: '新的合成说明'),
          values: const {},
        ),
      );
      expect((await s.loadCatalog()).version, p.catalogVersion);
      await expectLater(
        s.changeClassification(
          WorkspaceTagChange(
            operationId: 'stale-scope',
            expectedVersion: p.catalogVersion,
            action: WorkspaceTagAction.delete,
            tagId: tag.id,
            removalToken: p.token,
          ),
        ),
        fails('conflict'),
      );
      expect(
        (await s.readDetail(info)).record.tags.any((t) => t.id == tag.id),
        true,
      );
      expect((await s.loadRevisions(info)).length, 1);
      await remove(tag);
      expect((await s.readDetail(info)).version, old.version + 2);
    },
  );
  test(
    'lost classification reply freezes the original editor and only its matching receipt resolves it without replay',
    () async {
      final c = ClassificationEditController(
        s,
        await s.loadCatalog(),
        kind: WorkspaceClassificationKind.directory,
        action: 'create',
      );
      addTearDown(c.dispose);
      c.edit(name: 'Mac 目录');
      s.loseNextClassificationReply = true;
      await c.save();
      expect(c.uncertain, true);
      expect(c.name, 'Mac 目录');
      expect(c.receipt, isNull);
      s.lookupFailure = true;
      await c.reconcile();
      expect(c.uncertain, true);
      s.lookupFailure = false;
      s.wrong = true;
      await c.reconcile();
      expect(c.uncertain, true);
      s.wrong = false;
      await c.reconcile();
      expect(c.uncertain, false);
      expect(c.receipt!.directory!.name, 'Mac 目录');
      expect(s.writes, hasLength(1));
      expect(s.lookups.toSet(), {s.writes.single.operationId});
      expect(
        (await s.loadCatalog()).directories.where((d) => d.name == 'Mac 目录'),
        hasLength(1),
      );
    },
  );
  test(
    'confirmed non submission requires an explicit new operation; definite tag failure keeps draft and enables retry',
    () async {
      final c = ClassificationEditController(
        s,
        await s.loadCatalog(),
        kind: WorkspaceClassificationKind.tag,
        action: 'create',
      );
      addTearDown(c.dispose);
      c.edit(name: '新标签');
      s.absent = true;
      await c.save();
      await c.reconcile();
      expect(c.failure!.code, 'not_submitted');
      expect(c.name, '新标签');
      expect(s.writes, hasLength(1));
      s.absent = false;
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '空间不足');
      await c.save();
      expect(c.failure!.code, 'disk_full');
      expect(c.canSave, true);
      await c.save();
      expect(c.receipt!.tag!.name, '新标签');
      expect(s.writes.map((w) => w.operationId).toSet(), hasLength(3));
    },
  );
  test(
    'conflicted delete reloads the exact impact; an externally removed target never switches to a same-name replacement',
    () async {
      final tag = await shared(),
          c = ClassificationEditController(
            s,
            await s.loadCatalog(),
            kind: WorkspaceClassificationKind.tag,
            action: 'delete',
            targetId: tag.id,
            initialName: tag.name,
          );
      addTearDown(c.dispose);
      await c.readRemoval();
      expect(c.removal!.affectedCount, 2);
      await s.changeClassification(
        WorkspaceTagChange(
          operationId: 'new',
          expectedVersion: c.catalog.version,
          action: WorkspaceTagAction.create,
          name: '其他',
        ),
      );
      await c.save();
      expect(c.failure!.code, 'conflict');
      expect(c.canSave, false);
      await c.reload();
      expect(c.removal!.affectedCount, 2);
      expect(c.canSave, true);
      await remove(tag);
      await s.changeClassification(
        WorkspaceTagChange(
          operationId: 'same-name',
          expectedVersion: (await s.loadCatalog()).version,
          action: WorkspaceTagAction.create,
          name: tag.name,
        ),
      );
      await c.reload();
      expect(c.failure!.code, 'not_found');
      expect(c.canSave, false);
    },
  );
  test(
    'directory draft keeps a removed parent until the Owner explicitly selects a valid replacement',
    () async {
      final parent = await s.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'parent',
          expectedVersion: (await s.loadCatalog()).version,
          action: WorkspaceDirectoryAction.create,
          name: '临时上级',
        ),
      );
      final c = ClassificationEditController(
        s,
        await s.loadCatalog(),
        kind: WorkspaceClassificationKind.directory,
        action: 'create',
        initialParent: parent!.id,
      );
      addTearDown(c.dispose);
      c.edit(name: '仍未保存的子目录');
      await s.changeDirectory(
        WorkspaceDirectoryChange(
          operationId: 'remove-parent',
          expectedVersion: c.catalog.version,
          action: WorkspaceDirectoryAction.delete,
          directoryId: parent.id,
        ),
      );
      await c.reload();
      expect(c.parent, parent.id);
      expect(c.name, '仍未保存的子目录');
      expect(c.canSave, false);
      c.edit(parent: null, changeParent: true);
      await c.save();
      expect(c.receipt!.directory!.parentId, isNull);
      expect(c.canSave, false);
      await c.save();
      expect(s.writes, hasLength(1));
    },
  );
  test(
    'reset during classification preparation cancels the old write and never leaves a receipt or a new tag',
    () async {
      final catalog = await s.loadCatalog();
      s.setScenario(SampleWorkspaceScenario.waiting);
      final waiting = expectLater(
        s.changeClassification(
          WorkspaceTagChange(
            operationId: 'late-classification',
            expectedVersion: catalog.version,
            action: WorkspaceTagAction.create,
            name: '不应写入的标签',
          ),
        ),
        fails('cancelled'),
      );
      await s.replaceFixture(classificationFixture());
      await waiting;
      expect(
        (await s.loadCatalog()).tags.any((t) => t.name == '不应写入的标签'),
        false,
      );
      expect(
        await s.classificationOperationReceipt('late-classification'),
        isNull,
      );
    },
  );
  test(
    'classification receipt survives fixture reset and directory identities are not reused',
    () async {
      final c = WorkspaceDirectoryChange(
        operationId: 'original',
        expectedVersion: (await s.loadCatalog()).version,
        action: WorkspaceDirectoryAction.create,
        name: '原目录',
      );
      final r = await s.changeClassification(c);
      await s.replaceFixture(classificationFixture());
      expect(await s.classificationOperationReceipt(c.operationId), same(r));
      expect(await s.changeClassification(c), same(r));
      final next = await s.changeClassification(
        WorkspaceDirectoryChange(
          operationId: 'next',
          expectedVersion: (await s.loadCatalog()).version,
          action: WorkspaceDirectoryAction.create,
          name: '原目录',
        ),
      );
      expect(next.targetId, isNot(r.targetId));
    },
  );
  test(
    'manager searches full directory paths, paginates stable metadata, reveals new targets and ignores stale catalog reads without loading bodies',
    () async {
      final m = ClassificationController(s);
      addTearDown(m.dispose);
      await m.load();
      m.search('个人资料 /');
      expect(m.total, greaterThan(0));
      m.select(WorkspaceClassificationKind.tag);
      expect(m.total, greaterThan(40));
      final first = m.rows.map((r) => r.id).toSet();
      m.page(20);
      expect(m.rows.any((r) => first.contains(r.id)), false);
      m.search('不存在');
      expect(m.total, 0);
      final created = await s.changeClassification(
        WorkspaceTagChange(
          operationId: 'reveal',
          expectedVersion: m.catalog!.version,
          action: WorkspaceTagAction.create,
          name: '刚创建的分类',
        ),
      );
      await m.load(reveal: created.targetId);
      expect(m.keyword, '');
      expect(m.rows.any((r) => r.id == created.targetId), true);
      expect(s.details, 0);
      final current = m.catalog!, replies = <Completer<WorkspaceCatalog>>[];
      s.catalogOverride = () {
        final c = Completer<WorkspaceCatalog>();
        replies.add(c);
        return c.future;
      };
      final a = m.load(), b = m.load();
      replies[1].complete(current);
      await b;
      replies[0].completeError(const WorkspaceFailure('offline', '旧错误'));
      await a;
      expect(m.failure, isNull);
      expect(m.catalog, same(current));
    },
  );
}
