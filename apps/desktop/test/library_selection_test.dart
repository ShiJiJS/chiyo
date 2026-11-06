import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late LibraryController m;
  late core.InformationDirectory directory, child;
  setUp(() async {
    service = core.InformationService(
      repository: core.MemoryInformationRepository(),
    );
    directory = await service.owner.createDirectory('服务');
    child = await service.owner.createDirectory('配置', parentId: directory.id);
    for (var i = 0; i < 6; i++) {
      await service.owner.createInformation('资料$i', '', [
        core.FieldInput('正文', '', 'PRIVATE-$i'),
      ], directoryId: i < 3 ? directory.id : null);
    }
    await service.owner.createStringCredential(
      name: '资料凭据',
      publicPurpose: '',
      secret: 'PRIVATE-TOKEN',
    );
    source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
    m = LibraryController(source);
    await m.load(const WorkspaceQuery(limit: 2, sort: WorkspaceSort.name));
  });
  tearDown(() async {
    m.dispose();
    await source.dispose();
    await service.close();
  });

  test(
    'select all includes exactly the displayed page and explicitly chosen real directories',
    () {
      m.beginSelection();
      m.selectDisplayedRecords();
      expect(m.selectedCount, 2);
      expect(
        m.selectedBatch.records.toSet(),
        m.results!.items.map((r) => r.ref).toSet(),
      );
      m.toggleDirectory('all');
      m.toggleDirectory('unfiled');
      m.toggleDirectory('missing');
      expect(m.selectedCount, 2);
      m.toggleDirectory(directory.id);
      m.toggleDirectory(child.id);
      expect(m.selectedBatch.directoryIds.toSet(), {directory.id, child.id});
      expect(m.selectedCount, 4);
      m.selectDisplayedRecords();
      expect(m.selectedCount, 4);
      final hidden = service.owner.information.last;
      m.toggleRecord(
        WorkspaceRecordRef(WorkspaceRecordKind.information, hidden.id),
      );
      expect(m.selectedCount, 4);
      final ref = m.results!.items.first.ref;
      m.toggleRecord(ref);
      expect(m.selectedCount, 3);
      expect(m.recordIsSelected(ref), isFalse);
      m.cancelSelection();
      expect(m.selectedCount, 0);
      expect(m.selecting, isFalse);
    },
  );

  test(
    'paging, search and filters clear previous selection with a visible explanation',
    () async {
      m.selectDisplayedRecords();
      m.toggleDirectory(directory.id);
      final firstPage = m.selectedBatch.records.toSet();
      await m.load(m.query.copyWith(offset: 2));
      expect(m.selectedCount, 0);
      expect(m.selecting, isTrue);
      expect(m.selectionNotice, '显示范围已改变，已清除多选。');
      m.selectDisplayedRecords();
      expect(m.selectedBatch.records.any(firstPage.contains), isFalse);
      await m.apply(m.query.copyWith(keyword: '资料4'));
      expect(m.selectedCount, 0);
      m.selectDisplayedRecords();
      expect(m.selectedCount, 1);
      await m.apply(m.query.copyWith(keyword: '', directoryId: directory.id));
      expect(m.selectedCount, 0);
      m.selectDisplayedRecords();
      expect(m.selectedCount, 2);
      await m.apply(m.query.copyWith(typeId: 'credential'));
      expect(m.selectedCount, 0);
    },
  );

  test(
    'refresh removes vanished selection before rows are interactive and never selects newly visible records',
    () async {
      m.selectDisplayedRecords();
      m.toggleDirectory(child.id);
      final removed = m.results!.items.first.ref;
      var coherent = true;
      m.addListener(() {
        if (m.loadState != WorkspaceLoad.ready &&
            m.loadState != WorkspaceLoad.empty) {
          return;
        }
        final visible = m.results!.items.map((r) => r.ref).toSet();
        if (m.selectedBatch.records.any((r) => !visible.contains(r))) {
          coherent = false;
        }
      });
      final item = service.owner.information.singleWhere(
        (i) => i.id == removed.id,
      );
      await service.owner.deleteInformation(item.id, item.version);
      await service.owner.deleteDirectory(child.id, child.version);
      await m.load(m.query);
      expect(coherent, isTrue);
      expect(m.selectedCount, 1);
      expect(m.selectedBatch.records, isNot(contains(removed)));
      expect(m.selectedBatch.directoryIds, isEmpty);
      expect(m.selectionNotice, contains('已移除'));
      expect(m.results!.items.any((r) => !m.recordIsSelected(r.ref)), isTrue);
    },
  );

  test(
    'mixed credential selection remains explicit across same-query refresh and reset exits selection mode',
    () async {
      await m.load(const WorkspaceQuery(limit: 50, sort: WorkspaceSort.name));
      final credential = m.results!.items.singleWhere(
        (r) => r.ref.kind == WorkspaceRecordKind.credential,
      );
      m.toggleRecord(credential.ref);
      m.toggleDirectory(directory.id);
      await m.load(m.query);
      expect(m.selectedCount, 2);
      expect(m.recordIsSelected(credential.ref), isTrue);
      await m.resetView();
      expect(m.selectedCount, 0);
      expect(m.selecting, isFalse);
    },
  );
}
