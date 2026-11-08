import 'package:info_workspace/owner_workspace_classification.dart'
    show WorkspaceClassificationInformation;
import 'package:info_core/info_core.dart' as core;
import 'package:info_workspace/owner_credential_type.dart';
import 'package:info_workspace/owner_workspace_relation_queries.dart';
import 'package:info_workspace/owner_workspace_template_packages.dart';
import 'package:info_workspace/workspace_information_codec.dart';
import 'package:info_workspace/workspace_source.dart';

/// Trusted owner projections used by proposal review and relation pickers.
/// The encrypted library remains on the host; this owns no desktop or cache.
final class OnlineOwnerLibrary
    implements WorkspaceProposalLibrary, WorkspaceClassificationInformation {
  OnlineOwnerLibrary(this.owner, this.plugins)
    : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final OwnerWorkspaceTemplatePackages plugins;
  final core.OwnerLibraryScope _scope;
  final _codec = WorkspaceInformationCodec();
  @override
  Map<String, Map<String, Object?>> get templates => plugins.templates;
  void _check() {
    if (!_scope.isCurrent || !owner.serviceAvailable) {
      throw const WorkspaceFailure('library_changed', '资料库已变化，请重新连接。');
    }
  }

  Map<String, String> get _tags => {for (final t in owner.tags) t.id: t.name};
  List<WorkspaceRecordSummary> summaries() {
    _check();
    return [
      for (final i in owner.information) _codec.summary(i, tagNames: _tags),
      for (final c in owner.credentials)
        WorkspaceRecordSummary(
          ref: WorkspaceRecordRef(WorkspaceRecordKind.credential, c.id),
          name: c.name,
          description: c.publicPurpose,
          type: ownerCredentialType(c),
          updatedAt: c.modifiedAt,
          directoryId: c.directoryId,
          tags: [for (final id in c.tagIds) WorkspaceTag(id, _tags[id] ?? '')],
        ),
    ];
  }

  @override
  Future<WorkspaceCatalog> loadCatalog() async {
    _check();
    final records = summaries(), definitions = plugins.templates;
    final snapshot = await owner.informationClassificationSnapshot();
    return WorkspaceCatalog(
      version: snapshot.version,
      directories: [
        for (final d in owner.directories)
          WorkspaceDirectory(d.id, d.name, parentId: d.parentId),
      ],
      tags: [for (final t in owner.tags) WorkspaceTag(t.id, t.name)],
      types: {
        ...{
          for (final d in definitions.values)
            d['id'] as String: WorkspaceType(
              d['id'] as String,
              d['name'] as String,
              d['icon'] as String? ?? 'file',
            ),
          for (final r in records) r.type.id: r.type,
        }.values,
      },
      creatableTypes: [
        for (final d in definitions.values)
          if (!const {'file', 'resume', 'credential'}.contains(d['id']))
            WorkspaceType(
              d['id'] as String,
              d['name'] as String,
              d['icon'] as String? ?? 'file',
            ),
      ],
      directoryCounts: {
        for (final d in owner.directories)
          d.id: records.where((r) => r.directoryId == d.id).length,
      },
      tagCounts: {
        for (final t in owner.tags)
          t.id: records
              .where((r) => r.tags.any((tag) => tag.id == t.id))
              .length,
      },
    );
  }

  @override
  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) async {
    _check();
    if (ref.kind != WorkspaceRecordKind.information) {
      throw const WorkspaceFailure('unsupported', '请使用凭据管理入口。');
    }
    final item = owner.information.where((i) => i.id == ref.id).firstOrNull;
    if (item == null) throw const WorkspaceFailure('not_found', '资料已不存在。');
    final d = _codec.decode(item, tagNames: _tags);
    final incoming = owner.credentialsForInformation(ref.id);
    return WorkspaceDetail(
      record: d.record,
      version: d.version,
      templateState: d.templateState == WorkspaceTemplateState.available
          ? plugins.stateFor(
              d.record.type.id,
              d.definition['packageId'] as String?,
            )
          : d.templateState,
      definition: d.definition,
      values: d.values,
      relations: d.relations,
      incomingRelations: {
        if (incoming.isNotEmpty)
          'credentials': [
            for (final c in incoming)
              WorkspaceRecordRef(WorkspaceRecordKind.credential, c.id),
          ],
      },
      fieldIds: d.fieldIds,
      fieldOverrides: d.fieldOverrides,
      retainedFields: d.retainedFields,
      retainedRelations: d.retainedRelations,
    );
  }

  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async {
    final wanted = refs.toSet();
    return summaries().where((r) => wanted.contains(r.ref)).toList();
  }

  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) => OwnerWorkspaceRelationQueries(
    owner: owner,
    readSummaries: summaries,
    readTemplate: (id) async {
      _check();
      return plugins.templates[id] ??
          (throw const WorkspaceFailure('not_found', '模板已不可用。'));
    },
  ).queryRelationCandidates(query);
}
