import 'package:info_core/info_core.dart' as core;
import 'workspace_records.dart';

/// Shared relation eligibility and paging. Native collation is supplied by the
/// desktop; the server uses stable metadata ordering without reading values.
class OwnerWorkspaceRelationQueries {
  OwnerWorkspaceRelationQueries({
    required this.owner,
    required this.readSummaries,
    required this.readTemplate,
    this.sort = _defaultSort,
  });
  final core.OwnerAccess owner;
  final List<WorkspaceRecordSummary> Function() readSummaries;
  final Future<Map<String, Object?>> Function(String) readTemplate;
  final void Function(List<WorkspaceRecordSummary>) sort;
  List<WorkspaceRecordSummary> _summaries() => readSummaries();
  static void _defaultSort(List<WorkspaceRecordSummary> items) =>
      items.sort((a, b) {
        final order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return order == 0 ? a.ref.key.compareTo(b.ref.key) : order;
      });
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) async {
    if (query.typeId == 'credential') {
      _available();
      if (query.key != 'related' ||
          (query.source != null &&
              (query.source!.kind != WorkspaceRecordKind.credential ||
                  !owner.credentials.any((c) => c.id == query.source!.id)))) {
        throw const WorkspaceFailure('conflict', '凭据关联来源已变化，请重新打开。');
      }
      final items = _summaries()
          .where(
            (r) =>
                r.ref.kind == WorkspaceRecordKind.information &&
                _keyword(r, query.keyword),
          )
          .toList();
      sort(items);
      final offset = _offset(query.offset, query.limit, items.length);
      return WorkspaceResults(
        items: items.skip(offset).take(query.limit),
        total: items.length,
        offset: offset,
      );
    }
    final item = query.source == null ? null : _item(query.source!);
    if (item != null && (item.layout?.typeId ?? 'generic') != query.typeId) {
      throw const WorkspaceFailure('conflict', '来源资料类型已变化。');
    }
    // Only the owner's relation descriptors are needed. Do not decode source
    // field values just to find eligible target metadata.
    final snapshot = item?.layout?.snapshot;
    if (item?.layout != null &&
        snapshot?['codec'] != 'workspace-information-v1') {
      throw const WorkspaceFailure('unsupported', '此资料布局尚不支持修改关联。');
    }
    final definition = item == null
        ? await readTemplate(query.typeId)
        : {
            'relations': [
              ...((snapshot?['definition'] as Map?)?['relations'] as List? ??
                  []),
              ...(snapshot?['retainedRelations'] as List? ?? []),
            ],
          };
    final rule = (definition['relations'] as List? ?? [])
        .where((r) => r['key'] == query.key)
        .lastOrNull;
    if (rule == null) {
      throw const WorkspaceFailure('unsupported', '此资料没有该关联类型。');
    }
    final types = rule['targetTemplates'] as List? ?? [];
    final items = _summaries()
        .where(
          (r) =>
              r.ref != query.source &&
              (query.key != 'credentials' ||
                  r.ref.kind == WorkspaceRecordKind.credential) &&
              (types.isEmpty ||
                  types.any(
                    (t) => workspaceTypeMatches(r.type.id, t as String),
                  )) &&
              _keyword(r, query.keyword),
        )
        .toList();
    sort(items);
    final offset = _offset(query.offset, query.limit, items.length);
    return WorkspaceResults(
      items: items.skip(offset).take(query.limit),
      total: items.length,
      offset: offset,
    );
  }

  bool _keyword(WorkspaceRecordSummary record, String keyword) {
    final text =
        '${record.name} ${record.description} ${record.type.name} ${record.tags.map((t) => t.name).join(' ')}'
            .toLowerCase();
    return keyword
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .every(text.contains);
  }

  int _offset(int offset, int limit, int total) {
    if (offset < 0 || limit < 1 || limit > 500) {
      throw const WorkspaceFailure('invalid_query', '无效的分页范围。');
    }
    final last = total == 0 ? 0 : (total - 1) ~/ limit * limit;
    return offset > last ? last : offset;
  }

  void _available() {
    if (!owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '资料服务尚未就绪。');
    }
  }

  core.InformationItem _item(WorkspaceRecordRef ref) {
    _available();
    if (ref.kind != WorkspaceRecordKind.information) {
      throw const WorkspaceFailure('unsupported', '请通过凭据管理入口操作。');
    }
    final item = owner.information.where((i) => i.id == ref.id).firstOrNull;
    if (item == null) throw const WorkspaceFailure('not_found', '资料已不存在。');
    return item;
  }
}
