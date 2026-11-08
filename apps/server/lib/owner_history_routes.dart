import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/history_transport.dart';
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/library_transport.dart';
import 'package:info_workspace/owner_workspace_history.dart';
import 'package:info_workspace/owner_workspace_library_recycle.dart';
import 'package:info_workspace/owner_workspace_grant_history.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'owner_library.dart';

/// The normal Owner queue is the sole entry. These projections reuse original
/// transactions and receipts; Agent devices never reach this management API.
class OwnerHistoryRoutes {
  OwnerHistoryRoutes(this.library)
    : history = OwnerWorkspaceHistory(
        owner: library.owner,
        information: library,
      ),
      recycle = OwnerWorkspaceLibraryRecycle(
        library.owner,
        library.loadCatalog,
        () {},
      ),
      grants = OwnerWorkspaceGrantHistory(owner: library.owner);
  final OnlineOwnerLibrary library;
  final OwnerWorkspaceHistory history;
  final OwnerWorkspaceLibraryRecycle recycle;
  final OwnerWorkspaceGrantHistory grants;
  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    final tail = path.skip(3).toList();
    if (path[2] == 'grant-history') {
      if (tail.length == 1 && method == 'POST' && tail.single == 'query') {
        final q = grantQueryFromJson(body);
        return (
          200,
          grantResultsToJson(
            await grants.query(q.query, keepSelection: q.keepSelection),
          ),
        );
      }
      if (tail.length == 2 && tail.first == 'entries' && method == 'GET') {
        return (200, grantDetailToJson(await grants.read(tail.last)));
      }
      if (tail.length == 1 && tail.single == 'snapshot' && method == 'POST') {
        final b = historyEnvelope(body, ['id', 'record']);
        return (
          200,
          workspaceArchiveToJson(
            await grants.snapshot(
              historyText(b['id']),
              recordRefFromJson(b['record']),
            ),
          ),
        );
      }
      if (tail.length == 1 && tail.single == 'file' && method == 'POST') {
        final b = historyEnvelope(body, ['id', 'scopeId']);
        final selected = await grants.resolveFile(
          historyText(b['id']),
          historyText(b['scopeId']),
        );
        final content = await library.owner.readInformationAttachment(
              selected.ref,
            ),
            v = content.version,
            original = selected.original;
        if (original != null &&
            (v.reference != original.attachment ||
                v.sha256 != original.sha256 ||
                v.byteLength != original.byteLength ||
                v.originalName != original.fileName ||
                v.mediaType != original.mediaType)) {
          throw const core.AccessFailure('attachment_integrity_failed');
        }
        return (200, fileOriginalToJson(content));
      }
    } else if (path[2] == 'history') {
      if (tail.length == 1 && tail.single == 'revisions' && method == 'POST') {
        final b = historyEnvelope(body, ['record']);
        return (
          200,
          revisionsToJson(
            await history.loadRevisions(recordRefFromJson(b['record'])),
          ),
        );
      }
      if (tail.length == 1 && tail.single == 'preview' && method == 'POST') {
        final b = historyEnvelope(body, [
          'record',
          'revision',
          'expectedVersion',
        ]);
        return (
          200,
          revisionPreviewToJson(
            await history.previewRevision(
              recordRefFromJson(b['record']),
              historyInt(b['revision'], min: 1),
              expectedVersion: historyInt(b['expectedVersion'], min: 1),
            ),
          ),
        );
      }
      if (tail.length == 2 &&
          tail.first == 'recycled' &&
          tail.last == 'query' &&
          method == 'POST') {
        final b = historyEnvelope(body, ['keyword', 'offset', 'limit']);
        return (
          200,
          recycledResultsToJson(
            await history.queryRecycled(
              keyword: historyText(b['keyword'], max: 2000, empty: true),
              offset: historyInt(b['offset']),
              limit: historyInt(b['limit'], min: 1, max: 500),
            ),
          ),
        );
      }
      if (tail.length == 2 && tail.first == 'recycled' && method == 'GET') {
        return (
          200,
          workspaceArchiveToJson(await history.readRecycled(tail.last)),
        );
      }
      if (tail.length == 1 && tail.single == 'changes' && method == 'POST') {
        final c = recordChangeFromJson(body);
        await history.changeRecord(c);
        return (
          200,
          lifecycleReceiptToJson(
            (await history.lifecycleOperationReceipt(c.operationId))!,
          ),
        );
      }
      if (tail.length == 2 && tail.first == 'operations' && method == 'GET') {
        final r = await history.lifecycleOperationReceipt(tail.last);
        return r == null
            ? (404, {'error': 'operation_not_found'})
            : (200, lifecycleReceiptToJson(r));
      }
      if (tail.length == 2 &&
          tail.first == 'batches' &&
          tail.last == 'preview' &&
          method == 'POST') {
        final b = historyEnvelope(body, ['selection']);
        return (
          200,
          batchPreviewToJson(
            await recycle.preview(librarySelectionFromJson(b['selection'])),
          ),
        );
      }
      if (tail.length == 2 &&
          tail.first == 'batches' &&
          tail.last == 'restore-preview' &&
          method == 'POST') {
        final b = historyEnvelope(body, ['batchId', 'options']);
        return (
          200,
          batchPreviewToJson(
            await recycle.restorePreview(
              historyText(b['batchId']),
              batchOptionsFromJson(b['options']),
            ),
          ),
        );
      }
      if (tail.length == 2 &&
          tail.first == 'batches' &&
          tail.last == 'changes' &&
          method == 'POST') {
        return (
          200,
          batchReceiptToJson(await recycle.change(batchChangeFromJson(body))),
        );
      }
      if (tail.length == 3 &&
          tail.first == 'batches' &&
          tail[1] == 'operations' &&
          method == 'GET') {
        final r = await recycle.receipt(tail.last);
        return r == null
            ? (404, {'error': 'operation_not_found'})
            : (200, batchReceiptToJson(r));
      }
    }
    return (404, {'error': 'not_found'});
  }
}
