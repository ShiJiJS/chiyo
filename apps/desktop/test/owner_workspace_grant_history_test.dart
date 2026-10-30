import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/grant_history_controller.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late DateTime now;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      root.path,
      keys,
      clock: () => now,
    );
    service = core.InformationService(repository: repo, clock: () => now);
    source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
  }

  Future<void> close() async {
    await source.dispose();
    await service.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-grant-history-');
    keys = _Keys();
    now = DateTime.utc(2026, 10, 30);
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Future<core.InformationItem> seed() =>
      service.owner.createInformation('合成资料', '', [
        const core.FieldInput('字段甲', '', 'PRIVATE-ONE'),
        const core.FieldInput('字段乙', '', 'PRIVATE-TWO'),
      ]);
  List<core.FieldRef> refs(core.InformationItem item) => [
    for (final f in item.fields) core.FieldRef(item.id, f.id),
  ];
  Future<String> approve(
    core.InformationItem item,
    String session, {
    bool partial = false,
  }) async {
    final request = service.agent.request(session, '合成用途', refs(item));
    final m = ApprovalsController(source.approvals, const Stream.empty());
    try {
      await m.open(request.id);
      if (partial) m.toggle(m.detail!.scopes.last.id);
      m.lifetime(5);
      await m.decide(WorkspaceApprovalAction.approve);
      expect(m.writeFailure, isNull);
      return request.id;
    } finally {
      m.dispose();
    }
  }

  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

  test(
    'actual approval, access events and history controller revoke use one source',
    () async {
      final item = await seed();
      final session = service.agent.openSession('合成聊天');
      final id = await approve(item, session, partial: true);
      var detail = await source.grantHistory.read('request:$id');
      expect(detail.scopes, hasLength(1));
      expect(detail.summary.state, WorkspaceGrantState.active);
      expect(detail.summary.operationCount, 0);
      expect(detail.events.single.result, contains('不代表已经读取'));
      expect(detail.targets.single.version, 1);
      expect(detail.targets.single.snapshotAvailable, isTrue);
      final token = service.agent.claim(session, id).token;
      expect(await service.agent.read(token, refs(item).first), 'PRIVATE-ONE');
      await expectLater(
        service.agent.read(token, refs(item).last),
        throwsA(isA<core.AccessFailure>()),
      );
      detail = await source.grantHistory.read('request:$id');
      expect(detail.summary.operationCount, 2);
      expect(
        detail.events.where((e) => e.id.startsWith('access:')),
        hasLength(2),
      );
      expect(
        jsonEncode(
          detail.events.map((e) => [e.description, e.result]).toList(),
        ),
        isNot(contains('PRIVATE-')),
      );
      expect(
        (await source.grantHistory.query(
          const WorkspaceGrantQuery(keyword: 'PRIVATE-ONE'),
        )).total,
        0,
      );
      final controller = GrantHistoryController(
        source.grantHistory,
        source.approvals,
        const Stream.empty(),
      );
      try {
        await controller.open('request:$id');
        expect(controller.canRevoke, isTrue);
        await controller.revoke();
        expect(controller.decisionFailure, isNull);
        expect(controller.detail!.summary.state, WorkspaceGrantState.revoked);
        expect(controller.canRevoke, isFalse);
        await expectLater(
          service.agent.read(token, refs(item).first),
          throwsA(isA<core.AccessFailure>()),
        );
      } finally {
        controller.dispose();
      }
    },
  );

  test(
    'exact approval snapshot survives correction, deletion and same-name replacement',
    () async {
      final item = await seed();
      final session = service.agent.openSession('snapshot');
      final id = await approve(item, session);
      final ref = WorkspaceRecordRef(WorkspaceRecordKind.information, item.id);
      final original = await source.readDetail(ref);
      await service.owner.correctValue(refs(item).first, 'CHANGED');
      expect(
        (await source.grantHistory.snapshot('request:$id', ref)).detail.values,
        original.values,
      );
      final current = service.owner.information.single;
      await service.owner.deleteInformation(item.id, current.version);
      final replacement = await seed();
      final detail = await source.grantHistory.read('request:$id');
      expect(detail.targets.single.exists, isFalse);
      expect(detail.targets.single.snapshotAvailable, isTrue);
      expect(detail.summary.state, WorkspaceGrantState.unavailable);
      expect(
        (await source.grantHistory.snapshot('request:$id', ref)).detail.values,
        original.values,
      );
      await expectLater(
        source.grantHistory.snapshot(
          'request:$id',
          WorkspaceRecordRef(WorkspaceRecordKind.information, replacement.id),
        ),
        fails('not_found'),
      );
    },
  );

  test(
    'legacy grant never substitutes current content for unknown original version',
    () async {
      final item = await seed();
      final session = service.agent.openSession('legacy');
      final r = service.agent.request(session, 'legacy', refs(item));
      service.owner.approve(r.id, refs(item));
      final d = await source.grantHistory.read('request:${r.id}');
      expect(d.targets.single.version, 0);
      expect(d.targets.single.snapshotAvailable, isFalse);
      expect(d.legacyNotice, contains('没有记录'));
      await expectLater(
        source.grantHistory.snapshot(d.summary.id, d.targets.single.record),
        fails('snapshot_unavailable'),
      );
    },
  );

  test(
    'expiry, session end and restart never display historic grants as live',
    () async {
      final item = await seed();
      final s1 = service.agent.openSession('expires');
      final r1 = await approve(item, s1);
      final s2 = service.agent.openSession('ends');
      final r2 = await approve(item, s2);
      service.agent.endSession(s2);
      expect(
        (await source.grantHistory.read('request:$r2')).summary.state,
        WorkspaceGrantState.sessionEnded,
      );
      now = now.add(const Duration(minutes: 6));
      expect(
        (await source.grantHistory.read('request:$r1')).summary.state,
        WorkspaceGrantState.expired,
      );
      final s3 = service.agent.openSession('close');
      final r3 = await approve(item, s3);
      await close();
      await open();
      final d = await source.grantHistory.read('request:$r3');
      expect(d.summary.state, WorkspaceGrantState.sessionEnded);
      expect(d.canRevoke, isFalse);
      expect(d.targets.single.snapshotAvailable, isTrue);
      expect(
        (await source.grantHistory.query(
          const WorkspaceGrantQuery(filter: WorkspaceGrantFilter.active),
        )).total,
        0,
      );
    },
  );

  test(
    'denied and cancelled requests have facts but no granted scopes or invented accesses',
    () async {
      final item = await seed();
      final s = service.agent.openSession('denied');
      final r = service.agent.request(s, 'deny', refs(item));
      final m = ApprovalsController(source.approvals, const Stream.empty());
      try {
        await m.open(r.id);
        await m.decide(WorkspaceApprovalAction.deny);
        expect(m.writeFailure, isNull);
      } finally {
        m.dispose();
      }
      final d = await source.grantHistory.read('request:${r.id}');
      expect(d.summary.state, WorkspaceGrantState.denied);
      expect(d.scopes, isEmpty);
      expect(d.summary.operationCount, 0);
      expect(d.events.single.result, contains('拒绝'));
      final pending = service.agent.request(s, 'pending', refs(item));
      await expectLater(
        source.grantHistory.read('request:${pending.id}'),
        fails('not_found'),
      );
      service.agent.endSession(s);
      final cancelled = await source.grantHistory.read('request:${pending.id}');
      expect(cancelled.events.single.result, contains('取消'));
      expect(cancelled.scopes, isEmpty);
    },
  );

  test(
    'metadata queries page consistently and date filters use service time',
    () async {
      final item = await seed();
      final s = service.agent.openSession('pages');
      final old = await approve(item, s);
      now = now.add(const Duration(days: 2));
      final fresh = await approve(item, s);
      final rows = await source.grantHistory.query(
        const WorkspaceGrantQuery(limit: 1),
        keepSelection: 'request:$old',
      );
      expect(rows.total, 2);
      expect(rows.items.single.id, 'request:$fresh');
      expect(rows.selectionIndex, 1);
      expect(
        (await source.grantHistory.query(
          const WorkspaceGrantQuery(lastDays: 1),
        )).total,
        1,
      );
      expect(
        (await source.grantHistory.query(
          const WorkspaceGrantQuery(lastDays: 7),
        )).total,
        2,
      );
      await expectLater(
        source.grantHistory.query(const WorkspaceGrantQuery(limit: 0)),
        fails('invalid_query'),
      );
    },
  );

  test(
    'new reads refresh source even without changing request count or state',
    () async {
      final item = await seed();
      final s = service.agent.openSession('refresh');
      final id = await approve(item, s);
      await source.grantHistory.read('request:$id');
      source.refreshFromOwner();
      await Future<void>.delayed(Duration.zero);
      final changes = <WorkspaceRecordRef?>[];
      final sub = source.changes.listen(changes.add);
      try {
        final token = service.agent.claim(s, id).token;
        await service.agent.read(token, refs(item).first);
        source.refreshFromOwner();
        await Future<void>.delayed(Duration.zero);
        expect(changes, hasLength(1));
        source.refreshFromOwner();
        await Future<void>.delayed(Duration.zero);
        expect(changes, hasLength(1));
      } finally {
        await sub.cancel();
      }
    },
  );

  test(
    'missing explicit history never falls back to another revocable grant',
    () async {
      final item = await seed();
      final s = service.agent.openSession('exact');
      final id = await approve(item, s);
      final m = GrantHistoryController(
        source.grantHistory,
        source.approvals,
        const Stream.empty(),
      );
      try {
        await m.open('request:missing');
        expect(m.selection, 'request:missing');
        expect(m.readFailure?.code, 'not_found');
        expect(m.detail, isNull);
        await m.load();
        expect(m.selection, 'request:missing');
        expect(m.canRevoke, isFalse);
        await m.select('request:$id');
        expect(m.canRevoke, isTrue);
      } finally {
        m.dispose();
      }
    },
  );
  test(
    'deleting one approved field makes the grant partial; retention removes only snapshot content',
    () async {
      final item = await seed();
      final session = service.agent.openSession('partial');
      final id = await approve(item, session);
      await service.owner.deleteInformation(
        item.id,
        item.version,
        fieldId: item.fields.last.id,
      );
      var detail = await source.grantHistory.read('request:$id');
      expect(detail.summary.state, WorkspaceGrantState.partial);
      expect(detail.scopes.where((s) => s.active), hasLength(1));
      now = now.add(const Duration(days: 31));
      detail = await source.grantHistory.read('request:$id');
      expect(detail.targets.single.snapshotAvailable, isFalse);
      expect(detail.scopes, hasLength(2));
      expect(detail.summary.state, WorkspaceGrantState.expired);
      await expectLater(
        source.grantHistory.snapshot(
          'request:$id',
          detail.targets.single.record,
        ),
        fails('snapshot_unavailable'),
      );
    },
  );
  test(
    'replacing the library invalidates both history and content reads from the old source',
    () async {
      final item = await seed();
      final session = service.agent.openSession('original library');
      final id = await approve(item, session);
      final detail = await source.grantHistory.read('request:$id');
      // The fixture isolates the coordinator generation boundary; actual SQLCipher
      // backup round trips are covered by approval_operations_test in storage.
      await service.owner.restoreLibrary(() async {});
      await expectLater(
        source.grantHistory.query(const WorkspaceGrantQuery()),
        fails('library_changed'),
      );
      await expectLater(
        source.grantHistory.read('request:$id'),
        fails('library_changed'),
      );
      await expectLater(
        source.grantHistory.snapshot(
          'request:$id',
          detail.targets.single.record,
        ),
        fails('library_changed'),
      );
    },
  );
}
