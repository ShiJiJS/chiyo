import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/workspace_transport.dart';
import 'workspace_source.dart';

/// Relation names and types only. A proposal binding resolves pending rows
/// without inventing an information-library record before admission.
class RemoteWorkspaceRelations implements WorkspaceRelationSource {
  RemoteWorkspaceRelations(
    this.client, {
    this.prefix = '/v1/owner/relations',
    this.binding = const {},
  });
  final OwnerClient client;
  final String prefix;
  final Map<String, Object?> binding;
  Future<T> _read<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RemoteFailure catch (e) {
      throw WorkspaceFailure(e.code, '暂时无法读取关联资料，请重新读取提案或检查连接。');
    } on FormatException {
      throw const WorkspaceFailure('invalid_response', '关联资料格式不受支持，请核对运行版本。');
    }
  }

  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) => _read(
    () async => workspaceResultsFromJson(
      await client.request('POST', '$prefix/query', {
        ...binding,
        'query': relationQueryToJson(query),
      }),
    ),
  );
  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) => _read(() async {
    final result = await client.request('POST', '$prefix/summaries', {
      ...binding,
      'records': refs.map(recordRefToJson).toList(),
    });
    return decodeWorkspace(
      () => (result['items'] as List).map(recordSummaryFromJson).toList(),
    );
  });
}
