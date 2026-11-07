import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

class _Fault extends OwnerWorkspaceSource {
  _Fault(core.OwnerAccess owner)
    : super(owner: owner, refreshInterval: Duration.zero);
  @override
  Future<void> saveLibrarySort(WorkspaceSort sort) async =>
      throw const WorkspaceFailure(
        'save_failed',
        'Synthetic preference failure',
      );
}

void main() {
  test(
    'manual display and its real order return on a fresh controller, encrypted reopen and complete backup restore',
    () async {
      final root = await Directory.systemTemp.createTemp('library-view-order-');
      final keys = _Keys();
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      var now = DateTime.now().toUtc();
      var service = core.InformationService(repository: repo, clock: () => now);
      var source = OwnerWorkspaceSource(
        owner: service.owner,
        refreshInterval: Duration.zero,
      );
      var m = LibraryController(source);
      try {
        final ids = <String>[];
        for (final name in ['A', 'B', 'C']) {
          now = now.add(const Duration(minutes: 1));
          ids.add(
            (await service.owner.createInformation(name, '', [
              const core.FieldInput('Content', '', 'Synthetic'),
            ])).id,
          );
        }
        expect(
          service.owner.libraryDisplayOrder,
          core.LibraryDisplayOrder.updated,
        );
        await m.load(m.initialQuery);
        expect(m.results!.items.map((r) => r.ref.id), ids.reversed);
        final selection = core.LibrarySelection(informationIds: [ids.first]);
        final position = core.LibraryMovePosition(
          core.LibraryEntryRef('information', ids.last),
          after: true,
        );
        final preview = await service.owner.previewLibraryMove(
          selection,
          null,
          position: position,
        );
        await service.owner.moveLibrarySelection(
          'place-A-last',
          selection,
          null,
          preview.token,
          position: position,
        );
        await m.apply(m.query.copyWith(sort: WorkspaceSort.manual));
        final expected = [ids[1], ids[2], ids[0]];
        expect(m.results!.items.map((r) => r.ref.id), expected);
        expect(m.sortPreferenceNotice, isNull);
        m.dispose();
        await source.dispose();
        await service.close();
        await repo.close();
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          keys,
        );
        service = core.InformationService(repository: repo);
        source = OwnerWorkspaceSource(
          owner: service.owner,
          refreshInterval: Duration.zero,
        );
        m = LibraryController(source);
        expect(m.query.sort, WorkspaceSort.manual);
        await m.load(m.initialQuery);
        expect(m.results!.items.map((r) => r.ref.id), expected);
        expect(service.owner.information.every((i) => i.version == 1), isTrue);
        final recovery = await repo.backups.enable(),
            path = '${root.path}/manual.aimbackup';
        await repo.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
        await repo.backups.exportTo(path);
        final target = await EncryptedInformationRepository.open(
          '${root.path}/copy',
          _Keys(),
        );
        final copied = core.InformationService(repository: target);
        final copiedSource = OwnerWorkspaceSource(
          owner: copied.owner,
          refreshInterval: Duration.zero,
        );
        try {
          await target.backups.restoreFrom(path, recovery);
          final restoredSource = OwnerWorkspaceSource(
            owner: copied.owner,
            refreshInterval: Duration.zero,
          );
          final restored = LibraryController(restoredSource);
          try {
            expect(restored.query.sort, WorkspaceSort.manual);
            await restored.load(restored.initialQuery);
            expect(restored.results!.items.map((r) => r.ref.id), expected);
            final explicit = LibraryController(
              restoredSource,
              initialQuery: const WorkspaceQuery(sort: WorkspaceSort.name),
            );
            expect(explicit.query.sort, WorkspaceSort.name);
            explicit.dispose();
            await restored.apply(
              restored.query.copyWith(sort: WorkspaceSort.updated),
            );
            final again = LibraryController(restoredSource);
            expect(again.query.sort, WorkspaceSort.updated);
            again.dispose();
          } finally {
            restored.dispose();
            await restoredSource.dispose();
          }
        } finally {
          await copiedSource.dispose();
          await copied.close();
          await target.close();
        }
      } finally {
        m.dispose();
        await source.dispose();
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'preference failure is visible without reporting saved placement as lost',
    () async {
      final service = core.InformationService(
        repository: core.MemoryInformationRepository(),
      );
      final source = _Fault(service.owner), m = LibraryController(source);
      try {
        await m.load(m.initialQuery);
        await m.apply(m.query.copyWith(sort: WorkspaceSort.manual));
        expect(m.query.sort, WorkspaceSort.manual);
        expect(m.sortPreferenceNotice, contains('未能记住'));
        expect(
          service.owner.libraryDisplayOrder,
          core.LibraryDisplayOrder.updated,
        );
      } finally {
        m.dispose();
        await source.dispose();
        await service.close();
      }
    },
  );
}
