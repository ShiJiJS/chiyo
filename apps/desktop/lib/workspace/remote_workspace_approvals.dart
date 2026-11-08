import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/approval_transport.dart';
import 'workspace_source.dart';

/// Uses the same owner review and command rules as the local adapter, through
/// authenticated HTTPS. No approval logic or information body is cached here.
final class RemoteWorkspaceApprovals implements WorkspaceApprovalSource {
  RemoteWorkspaceApprovals(this.client, {required this.onChanged});
  final OwnerClient client;
  final void Function() onChanged;
  Future<T> _read<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RemoteFailure catch (e) {
      throw WorkspaceFailure(e.code, switch (e.code) {
        'not_found' => '未找到这条申请。',
        'unauthorized' => '连接身份已失效，请重新连接。',
        'server_changed' || 'library_changed' => '服务器或资料库已变化，请重新连接。',
        _ => '暂时无法读取申请，请检查连接后重试。',
      });
    } on FormatException {
      throw const WorkspaceFailure('invalid_response', '申请数据无法读取，请检查运行版本。');
    }
  }

  @override
  Future<WorkspaceApprovalResults> query(
    WorkspaceApprovalQuery query, {
    String? keepSelection,
  }) => _read(
    () async => approvalResultsFromJson(
      await client.request(
        'POST',
        '/v1/owner/approvals/query',
        approvalQueryToJson(query, keepSelection: keepSelection),
      ),
    ),
  );
  @override
  Future<WorkspaceApprovalDetail> read(String id) => _read(
    () async => approvalDetailFromJson(
      await client.request(
        'GET',
        '/v1/owner/approvals/${Uri.encodeComponent(id)}',
      ),
    ),
  );
  @override
  Future<WorkspaceApprovalReceipt> change(
    WorkspaceApprovalChange change,
  ) async {
    try {
      final receipt = approvalReceiptFromJson(
        await client.request(
          'POST',
          '/v1/owner/approvals/decisions',
          approvalChangeToJson(change),
        ),
      );
      if (receipt.operationId != change.operationId ||
          receipt.requestId != change.requestId ||
          receipt.action != change.action ||
          receipt.reviewToken != change.reviewToken ||
          receipt.commandDigest != change.digest) {
        throw const FormatException('Mismatched approval receipt');
      }
      onChanged();
      return receipt;
    } on RemoteFailure catch (e) {
      if (const {
        'conflict',
        'invalid_scope',
        'unsupported',
        'unauthorized',
        'server_changed',
        'library_changed',
      }.contains(e.code)) {
        throw WorkspaceFailure(e.code, switch (e.code) {
          'conflict' => '申请或资料已变化，请重新核对范围。',
          'invalid_scope' => '请核对所选字段和使用期限。',
          'unsupported' => '此类申请的联网接入尚未完成。',
          _ => '连接身份或服务器已变化，请重新连接。',
        });
      }
      throw const WorkspaceFailure(
        'unknown_outcome',
        '无法确认审批结果，请先核对原操作，不要重复提交。',
      );
    } on Object {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '无法确认审批结果，请先核对原操作，不要重复提交。',
      );
    }
  }

  @override
  Future<WorkspaceApprovalReceipt?> receipt(
    String operationId,
  ) => _read(() async {
    try {
      return approvalReceiptFromJson(
        await client.request(
          'GET',
          '/v1/owner/approvals/operations/${Uri.encodeComponent(operationId)}',
        ),
      );
    } on RemoteFailure catch (e) {
      if (e.code == 'operation_not_found') return null;
      rethrow;
    }
  });
  @override
  Future<WorkspaceApprovalExecution> execution(
    String requestId,
    String operationId,
  ) async => throw const WorkspaceFailure('unsupported', '凭据使用记录的联网接入尚未完成。');
}
