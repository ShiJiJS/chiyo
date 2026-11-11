import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/history_transport.dart';
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'workspace_source.dart';
import 'workspace_attachment_renderer.dart';

Future<T> _historyCall<T>(
  Future<T> Function() action, {
  bool writing = false,
}) async {
  try {
    return await action();
  } on WorkspaceFailure {
    rethrow;
  } on RemoteFailure catch (e) {
    if (const {
      'conflict',
      'validation',
      'not_found',
      'operation_conflict',
      'library_changed',
      'unauthorized',
      'server_changed',
      'attachment_missing',
      'snapshot_unavailable',
      'recycle_restore_required',
    }.contains(e.code)) {
      throw WorkspaceFailure(e.code, switch (e.code) {
        'conflict' => '资料或恢复范围已变化，请重新读取并核对。',
        'operation_conflict' => '原操作编号不能用于另一份修改。',
        'not_found' => '指定历史或回收内容已不可用，请刷新后重试。',
        'attachment_missing' ||
        'snapshot_unavailable' => '当时的准确原文已不可用，不会替换成当前内容。',
        'recycle_restore_required' => '请先恢复回收内容，再恢复旧版本。',
        'library_changed' ||
        'unauthorized' ||
        'server_changed' => '连接或资料库已变化，请重新连接。',
        _ => '请核对资料、版本和恢复位置。',
      }, fieldErrors: e.fieldErrors);
    }
    throw WorkspaceFailure(
      writing ? 'unknown_outcome' : 'unavailable',
      writing ? '操作结果尚未确认，请核对原操作，不要重复提交。' : '历史暂时无法读取，请检查服务器连接后重试。',
    );
  } on Object {
    throw WorkspaceFailure(
      writing ? 'unknown_outcome' : 'unavailable',
      writing ? '操作结果尚未确认，请核对原操作，不要重复提交。' : '历史返回内容无效或连接中断，请重新读取。',
    );
  }
}

class RemoteWorkspaceHistory implements WorkspaceLibraryRecycle {
  RemoteWorkspaceHistory(this.client, {required this.changed});
  final OwnerClient client;
  final void Function() changed;
  static const prefix = '/v1/owner/history';
  Future<T> _write<T>(Future<T> Function() action) => _historyCall(() async {
    final result = await action();
    changed();
    return result;
  }, writing: true);
  Future<List<WorkspaceRevision>> loadRevisions(WorkspaceRecordRef ref) =>
      _historyCall(() async {
        final values = revisionsFromJson(
          await client.request('POST', '$prefix/revisions', {
            'wireVersion': 1,
            'record': recordRefToJson(ref),
          }),
        );
        if (values.any((v) => v.record.ref != ref)) {
          throw const FormatException();
        }
        return values;
      });
  Future<WorkspaceRevisionPreview> previewRevision(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
    String? snapshotId,
  }) => _historyCall(() async {
    final result = revisionPreviewFromJson(
      await client.request('POST', '$prefix/preview', {
        'wireVersion': 1,
        'record': recordRefToJson(ref),
        'revision': version,
        'snapshotId': ?snapshotId,
        'expectedVersion': expectedVersion,
      }),
    );
    if (result.current.record.ref != ref ||
        result.archive.detail.version != version ||
        result.current.version != expectedVersion) {
      throw const FormatException();
    }
    return result;
  });
  Future<WorkspaceRecycleResults> queryRecycled({
    String keyword = '',
    int offset = 0,
    int limit = 25,
  }) => _historyCall(
    () async => recycledResultsFromJson(
      await client.request('POST', '$prefix/recycled/query', {
        'wireVersion': 1,
        'keyword': keyword,
        'offset': offset,
        'limit': limit,
      }),
    ),
  );
  Future<WorkspaceFilePreview> readRecycledFilePreview(
    String entryId,
    String fieldKey, {
    int page = 0,
  }) => _historyCall(() async {
    if (page < 0) throw const WorkspaceFailure('invalid_request', '页码无效。');
    final content = fileOriginalFromJson(
      await client.request('POST', '$prefix/recycled-file', {
        'wireVersion': 1,
        'entryId': entryId,
        'fieldKey': fieldKey,
      }),
    );
    return const WorkspaceAttachmentRenderer().renderContent(
      content.file,
      content.bytes,
      page: page,
    );
  });
  Future<WorkspaceArchive> readRecycled(String entryId) => _historyCall(
    () async => historyArchiveFromJson(
      await client.request(
        'GET',
        '$prefix/recycled/${Uri.encodeComponent(entryId)}',
      ),
    ),
  );
  Future<WorkspaceRecordReceipt> changeRecord(WorkspaceRecordChange c) =>
      _write(() async {
        final r = lifecycleReceiptFromJson(
          await client.request(
            'POST',
            '$prefix/changes',
            recordChangeToJson(c),
          ),
        );
        if (r.operationId != c.operationId ||
            !r.intent.matches(WorkspaceOperationIntent.change(c))) {
          throw const FormatException();
        }
        return r.result;
      });
  Future<WorkspaceOperationReceipt?> receipt(String id) =>
      _historyCall(() async {
        try {
          final r = lifecycleReceiptFromJson(
            await client.request(
              'GET',
              '$prefix/operations/${Uri.encodeComponent(id)}',
            ),
          );
          if (r.operationId != id) throw const FormatException();
          return r;
        } on RemoteFailure catch (e) {
          if (e.code == 'operation_not_found') return null;
          rethrow;
        }
      });
  @override
  bool get libraryRecycleSupported => true;
  @override
  Future<WorkspaceLibraryRecyclePreview> previewLibraryRecycle(
    WorkspaceLibrarySelection selection,
  ) => _historyCall(
    () async => batchPreviewFromJson(
      await client.request('POST', '$prefix/batches/preview', {
        'wireVersion': 1,
        'selection': selection.toJson(),
      }),
    ),
  );
  @override
  Future<WorkspaceLibraryRecyclePreview> previewLibraryRecycleRestore(
    String id,
    WorkspaceLibraryRestoreOptions options,
  ) => _historyCall(
    () async => batchPreviewFromJson(
      await client.request('POST', '$prefix/batches/restore-preview', {
        'wireVersion': 1,
        'batchId': id,
        'options': options.toJson(),
      }),
    ),
  );
  @override
  Future<WorkspaceLibraryRecycleReceipt> changeLibraryRecycle(
    WorkspaceLibraryRecycleCommand c,
  ) => _write(() async {
    final r = batchReceiptFromJson(
      await client.request(
        'POST',
        '$prefix/batches/changes',
        batchChangeToJson(c),
      ),
    );
    if (!r.matches(c)) throw const FormatException();
    return r;
  });
  @override
  Future<WorkspaceLibraryRecycleReceipt?> libraryRecycleOperationReceipt(
    String id,
  ) => _historyCall(() async {
    try {
      final r = batchReceiptFromJson(
        await client.request(
          'GET',
          '$prefix/batches/operations/${Uri.encodeComponent(id)}',
        ),
      );
      if (r.operationId != id) throw const FormatException();
      return r;
    } on RemoteFailure catch (e) {
      if (e.code == 'operation_not_found') return null;
      rethrow;
    }
  });
}

class RemoteWorkspaceGrantHistory implements WorkspaceGrantHistorySource {
  RemoteWorkspaceGrantHistory(
    this.client, {
    this.renderer = const WorkspaceAttachmentRenderer(),
  });
  final OwnerClient client;
  final WorkspaceAttachmentRenderer renderer;
  static const prefix = '/v1/owner/grant-history';
  @override
  Future<WorkspaceGrantResults> query(
    WorkspaceGrantQuery query, {
    String? keepSelection,
  }) => _historyCall(
    () async => grantResultsFromJson(
      await client.request(
        'POST',
        '$prefix/query',
        grantQueryToJson(query, keepSelection: keepSelection),
      ),
    ),
  );
  @override
  Future<WorkspaceGrantDetail> read(String id) => _historyCall(() async {
    final d = grantDetailFromJson(
      await client.request('GET', '$prefix/entries/${Uri.encodeComponent(id)}'),
    );
    if (d.summary.id != id) throw const FormatException();
    return d;
  });
  @override
  Future<WorkspaceArchive> snapshot(String id, WorkspaceRecordRef record) =>
      _historyCall(() async {
        final a = historyArchiveFromJson(
          await client.request('POST', '$prefix/snapshot', {
            'wireVersion': 1,
            'id': id,
            'record': recordRefToJson(record),
          }),
        );
        if (a.detail.record.ref != record) throw const FormatException();
        return a;
      });
  @override
  Future<WorkspaceFilePreview> filePreview(
    String id,
    String scopeId, {
    int page = 0,
  }) => _historyCall(() async {
    if (page < 0) throw const WorkspaceFailure('invalid_request', '页码无效。');
    final content = fileOriginalFromJson(
      await client.request('POST', '$prefix/file', {
        'wireVersion': 1,
        'id': id,
        'scopeId': scopeId,
      }),
    );
    return renderer.renderContent(content.file, content.bytes, page: page);
  });
}
