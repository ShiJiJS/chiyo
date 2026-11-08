import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/library_transport.dart';
import 'package:info_workspace/owner_workspace_library_move.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'owner_library.dart';

final class OwnerLibraryRoutes {
  OwnerLibraryRoutes(this.library)
    : moves = OwnerWorkspaceLibraryMove(
        library.owner,
        library.loadCatalog,
        () {},
      );
  final OnlineOwnerLibrary library;
  core.OwnerAccess get owner => library.owner;
  final OwnerWorkspaceLibraryMove moves;
  Map<String, Object?> order() => {
    'sort': owner.libraryDisplayOrder.name,
    'revision': owner.libraryOrderRevision,
    'records': [
      for (final r in owner.libraryRecordsInOrder)
        recordRefToJson(
          WorkspaceRecordRef(WorkspaceRecordKind.values.byName(r.kind), r.id),
        ),
    ],
  };
  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    final area = path[2];
    if (area == 'classification') {
      if (path.length == 4 && path.last == 'changes' && method == 'POST') {
        final change = classificationChangeFromJson(body!);
        if (change.kind == WorkspaceClassificationKind.directory &&
            change.deleting) {
          throw const WorkspaceFailure(
            'unsupported',
            '目录删除的联网接入尚未完成，请稍后通过回收站处理。',
          );
        }
        return (
          200,
          classificationReceiptToJson(
            await library.classification.changeClassification(change),
          ),
        );
      }
      if (path.length == 5 && path[3] == 'operations' && method == 'GET') {
        final r = await library.classification.classificationOperationReceipt(
          path.last,
        );
        return r == null
            ? (404, {'error': 'operation_not_found'})
            : (200, classificationReceiptToJson(r));
      }
      if (path.length == 5 && path[3] == 'tag-removal' && method == 'GET') {
        return (
          200,
          tagRemovalToJson(
            await library.classification.previewTagRemoval(path.last),
          ),
        );
      }
    }
    if (area == 'library') {
      if (path.length == 4 && path.last == 'order') {
        if (method == 'POST') {
          if (body!.length != 1 ||
              body['sort'] is! String ||
              !core.LibraryDisplayOrder.values.any(
                (v) => v.name == body['sort'],
              )) {
            throw const FormatException('Invalid display order');
          }
          await owner.saveLibraryDisplayOrder(
            core.LibraryDisplayOrder.values.byName(body['sort'] as String),
          );
        }
        if (method == 'GET' || method == 'POST') return (200, order());
      }
      if (path.length == 4 && path.last == 'targets' && method == 'POST') {
        return (
          200,
          {
            'items': (await moves.targets(
              librarySelectionFromJson(body!['selection']),
            )).map(libraryPlacementTargetToJson).toList(),
          },
        );
      }
      if (path.length == 4 && path.last == 'preview' && method == 'POST') {
        return (
          200,
          libraryMovePreviewToJson(
            await moves.preview(
              librarySelectionFromJson(body!['selection']),
              body['targetId'] as String?,
              position: libraryPositionFromJson(body['position']),
            ),
          ),
        );
      }
      if (path.length == 4 && path.last == 'moves' && method == 'POST') {
        return (
          200,
          libraryMoveReceiptToJson(
            await moves.move(libraryMoveCommandFromJson(body!)),
          ),
        );
      }
      if (path.length == 5 && path[3] == 'operations' && method == 'GET') {
        final r = await moves.receipt(path.last);
        return r == null
            ? (404, {'error': 'operation_not_found'})
            : (200, libraryMoveReceiptToJson(r));
      }
    }
    return (404, {'error': 'not_found'});
  }
}
