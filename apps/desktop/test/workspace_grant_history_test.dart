import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_approvals_test.dart' show decision;

Matcher fails(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

void main() {
  late SampleWorkspaceSource s;
  final reads = <String>[];
  setUp(() {
    reads.clear();
    s = SampleWorkspaceSource(
      readAsset: (p) {
        reads.add(p);
        return File(p).readAsBytes();
      },
    );
  });
  tearDown(() => s.dispose());

  test(
    'metadata filters and pages the same decision facts, without content reads or duplicate credential grants',
    () async {
      final baseline = await s.grantHistory.query(const WorkspaceGrantQuery());
      expect(baseline.items, isNotEmpty);
      expect(
        baseline.items.every((h) => h.state == WorkspaceGrantState.expired),
        true,
      );
      final server = await s.approvals.read('server');
      await s.approvals.change(decision(server));
      final token = await s.approvals.read('token');
      await s.approvals.change(
        decision(token, action: WorkspaceApprovalAction.deny, selected: []),
      );
      final all = await s.grantHistory.query(
        const WorkspaceGrantQuery(limit: 1),
        keepSelection: 'request:server',
      );
      expect(all.total, baseline.total + 2);
      expect(all.selection, 'request:server');
      expect(all.selectionIndex, isNotNull);
      final active = await s.grantHistory.query(
        const WorkspaceGrantQuery(
          filter: WorkspaceGrantFilter.active,
          kind: WorkspaceApprovalKind.credential,
          lastDays: 1,
        ),
      );
      expect(active.items.map((h) => h.id), ['request:server']);
      final denied = await s.grantHistory.read('request:token');
      expect(denied.summary.state, WorkspaceGrantState.denied);
      expect(denied.scopes, isEmpty);
      final d = await s.grantHistory.read('request:server');
      expect(
        d.scopes.map((x) => x.id).toSet(),
        (await s.approvals.read('server')).approved,
      );
      expect(d.scopes.any((x) => x.materialVersion != null), true);
      expect(reads.every((p) => p.endsWith('manifest.json')), true);
      await expectLater(
        s.grantHistory.query(const WorkspaceGrantQuery(lastDays: 2)),
        fails('invalid_query'),
      );
    },
  );

  test(
    'separate deadlines, session ending and revocation project current status without extending approval',
    () async {
      await s.approvals.change(
        decision(await s.approvals.read('server'), fields: 60, credential: 15),
      );
      final before = await s.grantHistory.read('request:server');
      s.advanceApprovalClock(const Duration(minutes: 16));
      final partial = await s.grantHistory.read('request:server');
      expect(partial.summary.state, WorkspaceGrantState.partial);
      expect(
        partial.scopes
            .where((x) => x.kind == WorkspaceApprovalScopeKind.credential)
            .single
            .active,
        false,
      );
      expect(partial.fieldExpiresAt, before.fieldExpiresAt);
      expect(partial.credentialExpiresAt, before.credentialExpiresAt);
      await s.approvals.change(
        decision(
          await s.approvals.read('server'),
          action: WorkspaceApprovalAction.revoke,
          selected: [],
        ),
      );
      expect(
        (await s.grantHistory.read('request:server')).summary.state,
        WorkspaceGrantState.revoked,
      );
      s.reset();
      await s.approvals.change(decision(await s.approvals.read('server')));
      s.endApprovalSession('session-maintenance');
      expect(
        (await s.grantHistory.read('request:server')).summary.state,
        WorkspaceGrantState.sessionEnded,
      );
    },
  );

  test(
    'Owner snapshot stays at approved record version; recycle preserves it, purge leaves only metadata',
    () async {
      final request = await s.approvals.read('server');
      final field = request.scopes.firstWhere(
        (x) => x.kind == WorkspaceApprovalScopeKind.field,
      );
      final ref = field.record;
      final original = await s.readDetail(ref);
      await s.approvals.change(decision(request, selected: [field.id]));
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'edit-after-grant',
          expectedVersion: original.version,
          record: original.record.copyWith(name: '新的同名服务器'),
          values: {'host': 'new.example'},
        ),
      );
      expect(
        (await s.grantHistory.snapshot('request:server', ref)).detail.values,
        original.values,
      );
      final changed = await s.readDetail(ref);
      final recycled = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'recycle',
          ref: ref,
          expectedVersion: changed.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      final deleted = await s.grantHistory.read('request:server');
      expect(deleted.targets.single.exists, false);
      expect(deleted.targets.single.snapshotAvailable, true);
      expect(
        (await s.grantHistory.snapshot('request:server', ref)).detail.version,
        original.version,
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'purge',
          ref: ref,
          expectedVersion: recycled.version,
          entryId: recycled.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      final purged = await s.grantHistory.read('request:server');
      expect(purged.targets.single.name, original.record.name);
      expect(purged.targets.single.snapshotAvailable, false);
      await expectLater(
        s.grantHistory.snapshot('request:server', ref),
        fails('history_unavailable'),
      );
    },
  );

  test(
    'ordinary file history pins the selected old attachment version and never exposes credential content',
    () async {
      final request = await s.approvals.read('resume');
      final file = request.scopes.singleWhere(
        (x) => x.kind == WorkspaceApprovalScopeKind.file,
      );
      await s.approvals.change(
        decision(request, selected: [file.id], files: {file.id: 1}),
      );
      final d = await s.grantHistory.read('request:resume');
      expect(d.scopes.single.fileVersion, 1);
      expect(reads.every((p) => p.endsWith('manifest.json')), true);
      final preview = await s.grantHistory.filePreview(d.summary.id, file.id);
      expect(
        preview.file.ref,
        file.fileVersions.singleWhere((v) => v.ref.version == 1).ref,
      );
      expect(preview.file.ref.version, 1);
      expect(preview.page, 0);
      final baseline = (await s.grantHistory.query(
        const WorkspaceGrantQuery(kind: WorkspaceApprovalKind.credential),
      )).items.first;
      final legacy = await s.grantHistory.read(baseline.id);
      expect(legacy.legacyNotice, isNotNull);
      await expectLater(
        s.grantHistory.snapshot(legacy.summary.id, legacy.targets.first.record),
        fails('unsupported'),
      );
      await expectLater(
        s.grantHistory.filePreview(legacy.summary.id, legacy.scopes.first.id),
        fails('history_unavailable'),
      );
      final original = await s.readDetail(file.record);
      final deletion = await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'delete-file',
          ref: file.record,
          expectedVersion: original.version,
          action: WorkspaceRecordAction.recycle,
        ),
      );
      expect(
        (await s.grantHistory.filePreview(
          d.summary.id,
          file.id,
        )).file.ref.version,
        1,
      );
      await s.changeRecord(
        WorkspaceRecordChange(
          operationId: 'purge-file',
          ref: file.record,
          expectedVersion: deletion.version,
          entryId: deletion.entryId,
          action: WorkspaceRecordAction.purge,
        ),
      );
      await expectLater(
        s.grantHistory.filePreview(d.summary.id, file.id),
        fails('history_unavailable'),
      );
    },
  );

  test(
    'reset restores baseline audit, while empty dataset never revives prior grants',
    () async {
      final baseline = await s.grantHistory.query(const WorkspaceGrantQuery());
      final row = baseline.items.first;
      final legacy = await s.grantHistory.read(row.id);
      final ref = legacy.targets.first.record;
      final original = await s.credentials.read(ref);
      final deletion = await s.credentials.change(
        WorkspaceCredentialChange(
          operationId: 'delete-credential',
          ref: ref,
          expectedRecordVersion: original.recordVersion,
          expectedMaterialVersion: original.materialVersion,
          action: WorkspaceCredentialAction.recycle,
        ),
      );
      await s.credentials.change(
        WorkspaceCredentialChange(
          operationId: 'purge-credential',
          ref: ref,
          expectedRecordVersion: deletion.recordVersion,
          expectedMaterialVersion: deletion.materialVersion,
          entryId: deletion.entryId,
          action: WorkspaceCredentialAction.purge,
        ),
      );
      expect((await s.grantHistory.read(row.id)).events, isNotEmpty);
      s.setScenario(SampleWorkspaceScenario.empty);
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        0,
      );
      expect(
        await s.createRecord(
          WorkspaceCreate(
            operationId: 'empty-new',
            typeId: 'server',
            name: '新的空库资料',
            values: {'host': 'empty.example'},
          ),
        ),
        isA<WorkspaceSaved>(),
      );
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        0,
      );
      s.reset();
      expect(
        (await s.grantHistory.query(const WorkspaceGrantQuery())).total,
        baseline.total,
      );
    },
  );
  test(
    'historical target names are explicit facts, including separators and organization scopes',
    () async {
      const azure = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'azure',
      );
      final old = await s.readDetail(azure);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'rename-before-grant',
          expectedVersion: old.version,
          record: old.record.copyWith(name: 'Azure · 旧服务器'),
          values: {},
        ),
      );
      final names = <String, Map<WorkspaceRecordRef, String>>{};
      for (final id in ['server', 'organize']) {
        await s.approvals.change(decision(await s.approvals.read(id)));
        final history = await s.grantHistory.read('request:$id');
        names[id] = {for (final t in history.targets) t.record: t.name};
        for (final target in history.targets) {
          expect(
            target.name,
            (await s.readDetail(target.record)).record.name,
            reason: '$id / ${target.record.key}',
          );
        }
      }
      final current = await s.readDetail(azure);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'rename-after-grant',
          expectedVersion: current.version,
          record: current.record.copyWith(name: '不应覆盖旧名称'),
          values: {},
        ),
      );
      const blinko = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'blinko',
      );
      final app = await s.readDetail(blinko);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'rename-org-member',
          expectedVersion: app.version,
          record: app.record.copyWith(name: '新的应用名'),
          values: {},
        ),
      );
      for (final id in ['server', 'organize']) {
        final history = await s.grantHistory.read('request:$id');
        expect({for (final t in history.targets) t.record: t.name}, names[id]);
      }
    },
  );
}
