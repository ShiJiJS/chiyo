import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/library_transport.dart';
import 'workspace_source.dart';

class RemoteWorkspaceLibrary implements WorkspaceLibraryMove {
  RemoteWorkspaceLibrary(this.client, {required this.changed});
  final OwnerClient client;
  final void Function() changed;
  WorkspaceSort? _sort;
  @override
  bool get libraryMoveSupported => true;
  @override
  bool get libraryOrderSupported => true;
  @override
  WorkspaceSort? get preferredLibrarySort =>
      _sort ??
      WorkspaceSort.values
          .where((s) => s.name == client.initialLibrarySort)
          .firstOrNull;
  Future<T> _read<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RemoteFailure catch (e) {
      throw WorkspaceFailure(
        e.code,
        '暂时无法读取目录或移动范围，请检查连接后重试。',
        fieldErrors: e.fieldErrors,
      );
    } on FormatException {
      throw const WorkspaceFailure(
        'invalid_response',
        '目录或移动结果无法完整读取，请核对运行版本。',
      );
    }
  }

  Future<T> _write<T>(Future<T> Function() action) async {
    try {
      final result = await action();
      changed();
      return result;
    } on RemoteFailure catch (e) {
      if (const {
        'conflict',
        'validation',
        'operation_conflict',
        'unsupported',
        'save_failed',
        'directory_not_empty',
        'unauthorized',
        'server_changed',
        'library_changed',
      }.contains(e.code)) {
        throw WorkspaceFailure(e.code, switch (e.code) {
          'conflict' => '目录、资料或所选位置已变化，请重新读取并核对。',
          'validation' => '请核对名称、目录和所选范围。',
          'unsupported' => '目录删除的联网接入尚未完成，请稍后通过回收站处理。',
          'save_failed' => '保存失败，原位置没有改变，请重试。',
          _ => '操作未完成，请核对原操作或重新连接。',
        }, fieldErrors: e.fieldErrors);
      }
      throw const WorkspaceFailure(
        'unknown_outcome',
        '保存结果尚未确认，请先核对原操作，不要重复提交。',
      );
    } on Object {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '保存结果尚未确认，请先核对原操作，不要重复提交。',
      );
    }
  }

  Future<WorkspaceClassificationReceipt> changeClassification(
    WorkspaceClassificationChange change,
  ) => _write(() async {
    final receipt = classificationReceiptFromJson(
      await client.request(
        'POST',
        '/v1/owner/classification/changes',
        classificationChangeToJson(change),
      ),
    );
    if (!receipt.matches(change)) {
      throw const FormatException('Mismatched classification receipt');
    }
    return receipt;
  });
  Future<WorkspaceClassificationReceipt?> classificationReceipt(
    String operationId,
  ) => _read(() async {
    try {
      return classificationReceiptFromJson(
        await client.request(
          'GET',
          '/v1/owner/classification/operations/${Uri.encodeComponent(operationId)}',
        ),
      );
    } on RemoteFailure catch (e) {
      if (e.code == 'operation_not_found') return null;
      rethrow;
    }
  });
  Future<WorkspaceTagRemovalPreview> previewTagRemoval(String tagId) => _read(
    () async => tagRemovalFromJson(
      await client.request(
        'GET',
        '/v1/owner/classification/tag-removal/${Uri.encodeComponent(tagId)}',
      ),
    ),
  );
  @override
  Future<void> saveLibrarySort(WorkspaceSort sort) async {
    try {
      final result = await client.request('POST', '/v1/owner/library/order', {
        'sort': sort.name,
      });
      if (result['sort'] != sort.name) throw const FormatException();
      _sort = sort;
    } on Object {
      throw const WorkspaceFailure('save_failed', '显示方式未能确认保存，重开后请核对或重新选择。');
    }
  }

  @override
  Future<List<WorkspaceLibraryPlacementTarget>> libraryPlacementTargets(
    WorkspaceLibrarySelection selection,
  ) => _read(() async {
    final result = await client.request('POST', '/v1/owner/library/targets', {
      'selection': selection.toJson(),
    });
    return (result['items'] as List)
        .map(libraryPlacementTargetFromJson)
        .toList();
  });
  @override
  Future<WorkspaceLibraryMovePreview> previewLibraryMove(
    WorkspaceLibrarySelection selection,
    String? targetId, {
    WorkspaceLibraryPosition? position,
  }) => _read(
    () async => libraryMovePreviewFromJson(
      await client.request('POST', '/v1/owner/library/preview', {
        'selection': selection.toJson(),
        'targetId': targetId,
        'position': position?.toJson(),
      }),
    ),
  );
  @override
  Future<WorkspaceLibraryMoveReceipt> moveLibrarySelection(
    WorkspaceLibraryMoveCommand command,
  ) => _write(() async {
    final receipt = libraryMoveReceiptFromJson(
      await client.request(
        'POST',
        '/v1/owner/library/moves',
        libraryMoveCommandToJson(command),
      ),
    );
    if (!receipt.matches(command)) {
      throw const FormatException('Mismatched move receipt');
    }
    return receipt;
  });
  @override
  Future<WorkspaceLibraryMoveReceipt?> libraryMoveOperationReceipt(String id) =>
      _read(() async {
        try {
          return libraryMoveReceiptFromJson(
            await client.request(
              'GET',
              '/v1/owner/library/operations/${Uri.encodeComponent(id)}',
            ),
          );
        } on RemoteFailure catch (e) {
          if (e.code == 'operation_not_found') return null;
          rethrow;
        }
      });
}
