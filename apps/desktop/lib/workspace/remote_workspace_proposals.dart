import 'package:info_workspace/file_transport.dart';
import 'workspace_attachment_renderer.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/proposal_transport.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'remote_workspace_relations.dart';
import 'workspace_source.dart';

/// The normal proposal UI and its whole-decision controller use this transport.
/// Server rules are shared with the desktop owner adapter; no auto approval.
class RemoteWorkspaceProposals
    implements
        WorkspaceProposalSource,
        WorkspaceProposalPreviewSource,
        WorkspaceProposalOriginalSource {
  RemoteWorkspaceProposals(this.client, {required this.changed});
  final _renderer = const WorkspaceAttachmentRenderer();
  @override
  Future<WorkspaceFilePreview> pendingOriginal(
    String proposalId,
    int proposalVersion,
    String itemId,
    String attachmentKey,
    int version, {
    int page = 0,
    WorkspaceProposalItemReview? review,
    int? originalProposalVersion,
  }) => _read(() async {
    final content = fileOriginalFromJson(
      await client.request('POST', '${_path(proposalId)}/originals/pending', {
        'proposalVersion': proposalVersion,
        'itemId': itemId,
        'attachmentKey': attachmentKey,
        'version': version,
        'review': review?.toJson(),
        'originalProposalVersion': originalProposalVersion,
      }),
    );
    return _renderer.renderContent(content.file, content.bytes, page: page);
  });
  @override
  Future<WorkspaceFilePreview> storedOriginal(
    String proposalId,
    int proposalVersion,
    WorkspaceRecordRef record,
    String fieldKey,
    WorkspaceFileRef file, {
    int page = 0,
    WorkspaceProposalItemReview? review,
  }) => _read(() async {
    final content = fileOriginalFromJson(
      await client.request('POST', '${_path(proposalId)}/originals/stored', {
        'proposalVersion': proposalVersion,
        'record': recordRefToJson(record),
        'fieldKey': fieldKey,
        'file': file.toJson(),
        'review': review?.toJson(),
      }),
    );
    if (content.file.ref != file) {
      throw const FormatException('Mismatched original reference');
    }
    return _renderer.renderContent(content.file, content.bytes, page: page);
  });
  final OwnerTransport client;
  final void Function() changed;
  static const _prefix = '/v1/owner/proposals';
  String _path(String id) => '$_prefix/${Uri.encodeComponent(id)}';
  Future<T> _read<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RemoteFailure catch (e) {
      throw WorkspaceFailure(e.code, switch (e.code) {
        'not_found' => '这份提案或原资料已不可用。',
        'conflict' => '提案已变化，请重新核对。',
        'unauthorized' ||
        'server_changed' ||
        'library_changed' => '连接身份或资料库已变化，请重新连接。',
        _ => '暂时无法读取提案，请检查连接后重试。',
      }, fieldErrors: e.fieldErrors);
    } on FormatException {
      throw const WorkspaceFailure('invalid_response', '提案数据无法完整读取，请核对运行版本。');
    }
  }

  @override
  Future<WorkspaceProposalResults> query(
    WorkspaceProposalQuery query, {
    String? keepSelection,
  }) => _read(
    () async => proposalResultsFromJson(
      await client.request(
        'POST',
        '$_prefix/query',
        proposalQueryToJson(query, keepSelection: keepSelection),
      ),
    ),
  );
  @override
  Future<WorkspaceProposalDetail> read(String id) => _read(
    () async => proposalDetailFromJson(await client.request('GET', _path(id))),
  );
  @override
  Future<WorkspaceCatalog> catalog() => _read(
    () async => workspaceCatalogFromJson(
      await client.request('GET', '$_prefix/catalog'),
    ),
  );
  @override
  Future<WorkspaceProposalReceipt> change(
    WorkspaceProposalChange change,
  ) async {
    try {
      final receipt = proposalReceiptFromJson(
        await client.request(
          'POST',
          '$_prefix/decisions',
          proposalChangeToJson(change),
        ),
      );
      if (receipt.operationId != change.operationId ||
          receipt.proposalId != change.proposalId ||
          receipt.action != change.action ||
          receipt.reviewToken != change.reviewToken ||
          receipt.reviewedVersion != change.version ||
          receipt.commandDigest != change.digest) {
        throw const FormatException('Mismatched proposal receipt');
      }
      changed();
      return receipt;
    } on RemoteFailure catch (e) {
      if (const {
        'conflict',
        'validation',
        'proposal_incomplete',
        'operation_conflict',
        'template_changed',
        'template_missing',
        'template_unavailable',
        'invalid_directory_name',
        'credential_material_required',
        'unsupported',
        'unauthorized',
        'server_changed',
        'library_changed',
      }.contains(e.code)) {
        throw WorkspaceFailure(e.code, switch (e.code) {
          'conflict' => '提案或原资料已变化，请重新核对。',
          'validation' => '请按模板说明核对填写内容。',
          'proposal_incomplete' ||
          'credential_material_required' => '整份提案还有内容未填齐，尚未入库。',
          'template_changed' ||
          'template_missing' ||
          'template_unavailable' => '模板已变化，请重新核对提案。',
          'invalid_directory_name' => '目录路径无效，请重新核对保存位置。',
          _ => '提案未保存，请核对原操作或重新连接。',
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

  @override
  Future<WorkspaceProposalReceipt?> receipt(String operationId) =>
      _read(() async {
        try {
          return proposalReceiptFromJson(
            await client.request(
              'GET',
              '$_prefix/operations/${Uri.encodeComponent(operationId)}',
            ),
          );
        } on RemoteFailure catch (e) {
          if (e.code == 'operation_not_found') return null;
          rethrow;
        }
      });
  @override
  WorkspaceRelationSource relations(
    String proposalId,
    String itemId,
    int version,
  ) => RemoteWorkspaceRelations(
    client,
    prefix: '${_path(proposalId)}/relations',
    binding: {'itemId': itemId, 'version': version},
  );
  @override
  WorkspaceRelationSource previewRelations() =>
      RemoteWorkspaceRelations(client);
  @override
  Future<WorkspaceProposalItem> previewRelated(
    String proposalId,
    int version,
    WorkspaceRecordRef record, {
    WorkspaceProposalItemReview? review,
  }) => _read(
    () async => proposalItemFromJson(
      await client.request('POST', '${_path(proposalId)}/related', {
        'version': version,
        'record': recordRefToJson(record),
        'review': review?.toJson(),
      }),
    ),
  );
  @override
  Future<WorkspaceProposalItem> savedPreview(
    String proposalId,
    WorkspaceRecordRef record,
  ) => _read(
    () async => proposalItemFromJson(
      await client.request('POST', '${_path(proposalId)}/saved', {
        'record': recordRefToJson(record),
      }),
    ),
  );
  @override
  Future<WorkspaceArchive> snapshot(
    String proposalId,
    WorkspaceRecordRef record,
  ) => _read(
    () async => workspaceArchiveFromJson(
      await client.request('POST', '${_path(proposalId)}/snapshot', {
        'record': recordRefToJson(record),
      }),
    ),
  );
  @override
  Future<WorkspaceDetail> currentTarget(String proposalId) => _read(
    () async => workspaceDetailFromJson(
      await client.request('GET', '${_path(proposalId)}/current'),
    ),
  );
}
