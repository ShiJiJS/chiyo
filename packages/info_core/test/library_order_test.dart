import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late MemoryInformationRepository repo;
  late InformationService service;
  setUp(() {
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo);
  });
  tearDown(() => service.close());
  Future<LibraryMoveReceipt> place(
    String operationId,
    LibrarySelection selection,
    String? parent, [
    LibraryMovePosition? position,
  ]) async {
    final preview = await service.owner.previewLibraryMove(
      selection,
      parent,
      position: position,
    );
    expect(preview.conflicts, isEmpty);
    return service.owner.moveLibrarySelection(
      operationId,
      selection,
      parent,
      preview.token,
      position: position,
    );
  }

  Future<InformationItem> item(String name, String? parent) =>
      service.owner.createInformation(name, '', [
        FieldInput('正文', '', 'PRIVATE-$name'),
      ], directoryId: parent);
  List<String> directoryOrder(String? parent) => service.owner.directories
      .where((d) => d.parentId == parent)
      .map((d) => d.id)
      .toList();
  List<LibraryEntryRef> recordOrder(String? parent) {
    final included = {
      for (final i in service.owner.information.where(
        (i) => i.directoryId == parent,
      ))
        LibraryEntryRef('information', i.id),
      for (final c in service.owner.credentials.where(
        (c) => c.directoryId == parent,
      ))
        LibraryEntryRef('credential', c.id),
    };
    return service.owner.libraryRecordsInOrder
        .where(included.contains)
        .toList();
  }

  test(
    'initial order is stable and read-only; sibling placement updates discovery without content revisions',
    () async {
      final a = await service.owner.createDirectory('A');
      final b = await service.owner.createDirectory('B');
      final c = await service.owner.createDirectory('C');
      expect(directoryOrder(null), [a.id, b.id, c.id]);
      expect(repo.libraryOrder, isNull);
      final selection = LibrarySelection(directoryIds: [c.id]);
      final position = LibraryMovePosition(LibraryEntryRef('directory', a.id));
      final p = await service.owner.previewLibraryMove(
        selection,
        null,
        position: position,
      );
      expect(p.anchorName, 'A');
      expect(repo.libraryOrder, isNull);
      final receipt = await service.owner.moveLibrarySelection(
        'before-A',
        selection,
        null,
        p.token,
        position: position,
      );
      expect(directoryOrder(null), [c.id, a.id, b.id]);
      expect(service.owner.directories.map((d) => d.version), everyElement(1));
      final catalog = service.agent.catalogDirectories();
      expect(catalog.map((d) => d['id']), [c.id, a.id, b.id]);
      expect(catalog.map((d) => d['order']), [0, 1, 2]);
      expect(receipt.directoryIds, [c.id]);
      expect(
        (await service.owner.moveLibrarySelection(
          'before-A',
          selection,
          null,
          p.token,
          position: position,
        )).toJson(),
        receipt.toJson(),
      );
      expect(
        jsonEncode(repo.libraryOrder!.toJson()),
        isNot(contains('PRIVATE-')),
      );
    },
  );

  test(
    'multi-placement preserves full saved sibling order and ignores partial result indices',
    () async {
      final d = await service.owner.createDirectory('资料');
      final a = await item('A', d.id),
          b = await item('隐藏的B', d.id),
          c = await item('C', d.id),
          hidden = await item('隐藏的D', d.id);
      LibraryEntryRef ref(InformationItem i) =>
          LibraryEntryRef('information', i.id);
      await place(
        'C-before-A',
        LibrarySelection(informationIds: [c.id]),
        d.id,
        LibraryMovePosition(ref(a)),
      );
      expect(recordOrder(d.id), [ref(c), ref(a), ref(b), ref(hidden)]);
      await place(
        'group-after-B',
        LibrarySelection(informationIds: [a.id, c.id]),
        d.id,
        LibraryMovePosition(ref(b), after: true),
      );
      expect(recordOrder(d.id), [ref(b), ref(c), ref(a), ref(hidden)]);
      for (final original in [a, b, c, hidden]) {
        expect(
          informationToJson(
            service.owner.information.singleWhere((i) => i.id == original.id),
          ),
          informationToJson(original),
        );
      }
    },
  );

  test(
    'information and credentials share record order, preserving grants while changing placement',
    () async {
      final d = await service.owner.createDirectory('资料');
      final a = await item('A', d.id), b = await item('B', d.id);
      final c = await service.owner.createStringCredential(
        name: '凭据',
        publicPurpose: '',
        secret: 'PRIVATE-TOKEN',
      );
      final field = FieldRef(a.id, a.fields.single.id);
      final session = service.agent.openSession('合成排序');
      final request = service.agent.request(session, '读取', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      await place(
        'credential-before-B',
        LibrarySelection(credentialIds: [c.id]),
        d.id,
        LibraryMovePosition(LibraryEntryRef('information', b.id)),
      );
      expect(recordOrder(d.id), [
        LibraryEntryRef('information', a.id),
        LibraryEntryRef('credential', c.id),
        LibraryEntryRef('information', b.id),
      ]);
      final moved = service.owner.credential(c.id);
      expect(moved.version, c.version);
      expect(moved.useGeneration, c.useGeneration);
      await place(
        'A-after-credential',
        LibrarySelection(informationIds: [a.id]),
        d.id,
        LibraryMovePosition(LibraryEntryRef('credential', c.id), after: true),
      );
      expect(recordOrder(d.id), [
        LibraryEntryRef('credential', c.id),
        LibraryEntryRef('information', a.id),
        LibraryEntryRef('information', b.id),
      ]);
      expect(await service.agent.read(grant.token, field), 'PRIVATE-A');
      expect(
        service.owner.information.singleWhere((i) => i.id == a.id).version,
        a.version,
      );
      expect(service.owner.credential(c.id).revision, moved.revision);
    },
  );

  test(
    'moving into a directory appends only changed members; choosing the same parent preserves order',
    () async {
      final d = await service.owner.createDirectory('目标');
      final a = await item('A', d.id),
          b = await item('B', d.id),
          c = await item('C', null);
      final sub = await service.owner.createDirectory('已有子目录', parentId: d.id);
      final movedDir = await service.owner.createDirectory('要移动的目录');
      await place(
        'B-before-A',
        LibrarySelection(informationIds: [b.id]),
        d.id,
        LibraryMovePosition(LibraryEntryRef('information', a.id)),
      );
      await place(
        'append-mixed',
        LibrarySelection(
          directoryIds: [movedDir.id],
          informationIds: [b.id, c.id],
        ),
        d.id,
      );
      expect(recordOrder(d.id).map((r) => r.id), [b.id, a.id, c.id]);
      expect(directoryOrder(d.id), [sub.id, movedDir.id]);
      final revision = repo.libraryOrder!.revision;
      await place(
        'same-location',
        LibrarySelection(informationIds: [b.id]),
        d.id,
      );
      expect(repo.libraryOrder!.revision, revision);
      expect(recordOrder(d.id).map((r) => r.id), [b.id, a.id, c.id]);
    },
  );

  test(
    'an ordering change alone invalidates a prior placement review',
    () async {
      final a = await item('A', null),
          b = await item('B', null),
          c = await item('C', null);
      final selection = LibrarySelection(informationIds: [c.id]);
      final pos = LibraryMovePosition(LibraryEntryRef('information', a.id));
      final old = await service.owner.previewLibraryMove(
        selection,
        null,
        position: pos,
      );
      await place(
        'B-after-C',
        LibrarySelection(informationIds: [b.id]),
        null,
        LibraryMovePosition(LibraryEntryRef('information', c.id), after: true),
      );
      await expectLater(
        service.owner.moveLibrarySelection(
          'stale',
          selection,
          null,
          old.token,
          position: pos,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'library_selection_changed',
          ),
        ),
      );
      expect(await service.owner.libraryMoveReceipt('stale'), isNull);
      expect(recordOrder(null).map((r) => r.id), [a.id, c.id, b.id]);
    },
  );

  test(
    'selected anchors, wrong parents, mixed lanes and missing anchors cannot be placed',
    () async {
      final d = await service.owner.createDirectory('目录'),
          other = await service.owner.createDirectory('另一个目录');
      final a = await item('A', d.id), b = await item('B', null);
      for (final entry in [
        (
          LibrarySelection(informationIds: [a.id]),
          d.id,
          LibraryEntryRef('information', a.id),
        ),
        (
          LibrarySelection(informationIds: [a.id]),
          d.id,
          LibraryEntryRef('information', b.id),
        ),
        (
          LibrarySelection(directoryIds: [d.id], informationIds: [b.id]),
          null,
          LibraryEntryRef('directory', other.id),
        ),
        (
          LibrarySelection(directoryIds: [d.id]),
          d.id,
          LibraryEntryRef('information', a.id),
        ),
      ]) {
        final p = await service.owner.previewLibraryMove(
          entry.$1,
          entry.$2,
          position: LibraryMovePosition(entry.$3),
        );
        expect(p.canMove, isFalse);
      }
      await expectLater(
        service.owner.previewLibraryMove(
          LibrarySelection(informationIds: [a.id]),
          null,
          position: const LibraryMovePosition(
            LibraryEntryRef('information', 'missing'),
          ),
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(repo.libraryOrder, isNull);
      expect(service.owner.information.map((i) => i.version), everyElement(1));
    },
  );

  test(
    'whole recycle captures previously unranked siblings and restores identity order without resurrecting anything early',
    () async {
      final a = await service.owner.createDirectory('A'),
          b = await service.owner.createDirectory('B'),
          c = await service.owner.createDirectory('C');
      final one = await item('一', a.id), two = await item('二', a.id);
      await place(
        'C-before-A',
        LibrarySelection(directoryIds: [c.id]),
        null,
        LibraryMovePosition(LibraryEntryRef('directory', a.id)),
      );
      final recent = await item('刚添加的资料', a.id);
      final beforeRecords = recordOrder(a.id);
      expect(beforeRecords.map((r) => r.id), [one.id, two.id, recent.id]);
      final selection = LibrarySelection(directoryIds: [a.id]);
      final p = await service.owner.previewLibraryRecycle(selection);
      final batch = await service.owner.recycleLibrarySelection(
        'delete-A',
        selection,
        p.token,
      );
      expect(directoryOrder(null), [c.id, b.id]);
      expect(
        service.agent.catalogDirectories().any((d) => d['id'] == a.id),
        isFalse,
      );
      expect(service.owner.information, isEmpty);
      expect(
        repo.libraryOrder!.records.map((r) => r.id),
        containsAll([one.id, two.id, recent.id]),
      );
      await place(
        'B-before-C',
        LibrarySelection(directoryIds: [b.id]),
        null,
        LibraryMovePosition(LibraryEntryRef('directory', c.id)),
      );
      final restore = await service.owner.previewLibraryRecycleRestore(
        batch.batchId,
      );
      await service.owner.restoreLibraryRecycleBatch(
        'restore-A',
        batch.batchId,
        restore.token,
      );
      expect(directoryOrder(null), [b.id, c.id, a.id]);
      expect(recordOrder(a.id), beforeRecords);
      expect(service.owner.information.map((i) => i.id).toSet(), {
        one.id,
        two.id,
        recent.id,
      });
    },
  );

  test(
    'changing a recycled root parent appends it behind existing target children',
    () async {
      final a = await service.owner.createDirectory('A'),
          target = await service.owner.createDirectory('目标');
      final existing = await service.owner.createDirectory(
        '现有子目录',
        parentId: target.id,
      );
      final selection = LibrarySelection(directoryIds: [a.id]);
      final p = await service.owner.previewLibraryRecycle(selection);
      final batch = await service.owner.recycleLibrarySelection(
        'delete',
        selection,
        p.token,
      );
      final options = LibraryRecycleRestoreOptions(
        parentOverrides: {a.id: target.id},
      );
      final restore = await service.owner.previewLibraryRecycleRestore(
        batch.batchId,
        options: options,
      );
      await service.owner.restoreLibraryRecycleBatch(
        'restore',
        batch.batchId,
        restore.token,
        options: options,
      );
      expect(directoryOrder(target.id), [existing.id, a.id]);
    },
  );

  test(
    'persisted order validates its own metadata without requiring every identity to be current',
    () {
      final snapshot = LibraryOrderSnapshot(
        revision: 1,
        directories: ['recycled-directory'],
        records: [
          const LibraryEntryRef('information', 'recycled-information'),
          const LibraryEntryRef('credential', 'credential'),
        ],
      );
      expect(
        LibraryOrderSnapshot.fromJson(snapshot.toJson()).toJson(),
        snapshot.toJson(),
      );
      for (final json in [
        {...snapshot.toJson(), 'format': 2},
        {...snapshot.toJson(), 'revision': 0},
        {...snapshot.toJson(), 'body': 'unwanted'},
        {
          ...snapshot.toJson(),
          'directories': ['same', 'same'],
        },
        {
          ...snapshot.toJson(),
          'records': [
            ['directory', 'not-record'],
          ],
        },
        {
          ...snapshot.toJson(),
          'records': [
            ['information', 'same'],
            ['information', 'same'],
          ],
        },
        {
          ...snapshot.toJson(),
          'records': [
            ['information', ''],
          ],
        },
      ]) {
        expect(
          () => LibraryOrderSnapshot.fromJson(json),
          throwsFormatException,
        );
      }
    },
  );
}
