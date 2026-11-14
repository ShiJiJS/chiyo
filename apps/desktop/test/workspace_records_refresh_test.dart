import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _DeferredCatalogSource extends OwnerWorkspaceSource {
  _DeferredCatalogSource({required super.owner})
    : super(refreshInterval: Duration.zero);
  bool defer = false;
  final reads = <Completer<WorkspaceCatalog>>[];
  @override
  Future<WorkspaceCatalog> loadCatalog() {
    if (!defer) return super.loadCatalog();
    final read = Completer<WorkspaceCatalog>();
    reads.add(read);
    return read.future;
  }
}

void main() {
  test(
    'saved-record navigation waits for a background refresh instead of reporting missing detail',
    () async {
      final service = core.InformationService(
        repository: core.MemoryInformationRepository(),
      );
      final item = await service.owner.createInformation(
        'Synthetic saved record',
        '',
        [const core.FieldInput('Body', '', 'SYNTHETIC')],
      );
      final source = _DeferredCatalogSource(owner: service.owner);
      final catalog = await source.loadCatalog();
      final controller = LibraryController(source);
      final ref = WorkspaceRecordRef(WorkspaceRecordKind.information, item.id);
      try {
        source.defer = true;
        var settled = false;
        final loading = controller
            .load(const WorkspaceQuery(), keepSelection: ref)
            .then((_) => settled = true);
        source.notifyExternalChange();
        await Future<void>.delayed(Duration.zero);
        expect(source.reads, hasLength(1));
        source.reads.first.complete(catalog);
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);
        expect(source.reads, hasLength(2));
        source.reads.last.complete(catalog);
        await loading;
        expect(controller.selection, ref);
        expect(controller.detail!.record.ref, ref);
        expect(controller.loadState, WorkspaceLoad.ready);
      } finally {
        controller.dispose();
        await source.dispose();
        await service.close();
      }
    },
  );
}
