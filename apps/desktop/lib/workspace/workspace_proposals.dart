import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_records.dart';
import 'workspace_history.dart';
import 'workspace_entries.dart';

enum WorkspaceProposalKind {
  addition('新增资料'),
  modification('修改信息'),
  deletion('删除信息'),
  organization('整理结果');

  const WorkspaceProposalKind(this.label);
  final String label;
}

enum WorkspaceProposalStatus {
  pending('待确认'),
  conflicted('版本冲突'),
  completed('已完成'),
  rejected('已拒绝'),
  ended('已结束');

  const WorkspaceProposalStatus(this.label);
  final String label;
}

enum WorkspaceProposalFilter { all, pending, handled }

enum WorkspaceProposalAction { confirm, reject }

enum WorkspaceProposalFieldIntent { correct, add, replace, remove }

class WorkspaceProposalQuery {
  const WorkspaceProposalQuery({
    this.keyword = '',
    this.filter = WorkspaceProposalFilter.all,
    this.kind,
    this.offset = 0,
    this.limit = 20,
  });
  final String keyword;
  final WorkspaceProposalFilter filter;
  final WorkspaceProposalKind? kind;
  final int offset, limit;
}

/// Queue data contains public descriptions, identities and counts, never bodies.
class WorkspaceProposalSummary {
  const WorkspaceProposalSummary({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    required this.pending,
    required this.version,
    required this.at,
    required this.agentClaim,
    required this.chatClaim,
    required this.purpose,
    required this.itemCount,
    this.wholeDeletion = false,
  });
  final String id, title, agentClaim, chatClaim, purpose;
  final WorkspaceProposalKind kind;
  final WorkspaceProposalStatus status;
  final bool pending;
  final int version, itemCount;
  final bool wholeDeletion;
  final DateTime at;
}

class WorkspaceProposalResults {
  WorkspaceProposalResults({
    required Iterable<WorkspaceProposalSummary> items,
    required this.total,
    required this.pending,
    required this.offset,
    this.selection,
    this.selectionIndex,
  }) : items = List.unmodifiable(items);
  final List<WorkspaceProposalSummary> items;
  final int total, pending, offset;
  final String? selection;
  final int? selectionIndex;
}

/// Explicit Owner review boundary. The item definition is its submitted
/// snapshot; a later installed template never reinterprets these values.
enum WorkspaceProposalBeforeState { unread, available, unavailable }

class WorkspaceProposalItem {
  WorkspaceProposalItem({
    required this.id,
    required this.proposed,
    this.before,
    this.beforeState = WorkspaceProposalBeforeState.unread,
    Iterable<WorkspaceProposalFieldChange> changes = const [],
  }) : changes = List.unmodifiable(changes) {
    if (proposed.record.ref.kind != WorkspaceRecordKind.information ||
        before?.record.ref.kind == WorkspaceRecordKind.credential) {
      throw ArgumentError('Credential bodies do not pass through proposals.');
    }
  }
  final String id;
  final WorkspaceDetail proposed;
  final WorkspaceDetail? before;
  final WorkspaceProposalBeforeState beforeState;
  final List<WorkspaceProposalFieldChange> changes;
  WorkspaceProposalItem withoutOwnerBefore({
    WorkspaceProposalBeforeState state = WorkspaceProposalBeforeState.unread,
  }) {
    final old = before;
    if (old == null) return this;
    return WorkspaceProposalItem(
      id: id,
      proposed: proposed,
      beforeState: state,
      before: WorkspaceDetail(
        record: old.record,
        version: old.version,
        definition: old.definition,
        fieldIds: old.fieldIds,
        fieldOverrides: old.fieldOverrides,
        retainedFields: old.retainedFields,
        retainedRelations: old.retainedRelations,
      ),
      changes: changes.map((c) => c.withOwnerBefore(null, available: false)),
    );
  }
}

class WorkspaceProposalFieldChange {
  WorkspaceProposalFieldChange({
    required this.intent,
    required this.key,
    required this.label,
    this.fieldId,
    this.entryId,
    this.leaf,
    this.before,
    this.after,
    this.beforeAvailable = false,
    Map<String, Object?>? definition,
  }) : definition = definition == null
           ? null
           : workspaceImmutableMap(definition);
  final WorkspaceProposalFieldIntent intent;
  final String key, label;
  final String? fieldId, entryId, leaf;
  String get reviewKey => entryId == null ? key : '$key:$entryId:$leaf';
  final String? before, after;
  final bool beforeAvailable;
  final Map<String, Object?>? definition;
  WorkspaceProposalFieldChange withOwnerBefore(
    String? value, {
    required bool available,
  }) => WorkspaceProposalFieldChange(
    intent: intent,
    key: key,
    label: label,
    fieldId: fieldId,
    entryId: entryId,
    leaf: leaf,
    before: value,
    after: after,
    beforeAvailable: available,
    definition: definition,
  );
}

/// These are retained commit facts, never a second cache of submitted values.
class WorkspaceProposalTarget {
  const WorkspaceProposalTarget({
    required this.record,
    required this.name,
    required this.version,
    required this.exists,
    required this.snapshotAvailable,
  });
  final WorkspaceRecordRef record;
  final String name;
  final int version;
  final bool exists, snapshotAvailable;
}

class WorkspaceProposalDetail {
  WorkspaceProposalDetail({
    required this.summary,
    required this.reviewToken,
    Iterable<WorkspaceProposalItem> items = const [],
    Iterable<WorkspaceProposalTarget> targets = const [],
    this.notice,
    this.currentTargetRef,
    this.currentAvailable = false,
  }) : items = List.unmodifiable(items),
       targets = List.unmodifiable(targets);
  final WorkspaceProposalSummary summary;
  final String reviewToken;
  final List<WorkspaceProposalItem> items;
  final List<WorkspaceProposalTarget> targets;
  final String? notice;
  final WorkspaceRecordRef? currentTargetRef;
  final bool currentAvailable;
  late final String snapshotDigest = _snapshotDigest();
  String _snapshotDigest() {
    Map<String, Object?> snapshot(
      WorkspaceDetail d, {
      bool includeValues = true,
    }) => {
      'record': {
        'ref': d.record.ref.key,
        'name': d.record.name,
        'description': d.record.description,
        'type': d.record.type.id,
        'directory': d.record.directoryId,
        'tags': [
          for (final t in d.record.tags) {'id': t.id, 'name': t.name},
        ],
      },
      'version': d.version,
      'definition': d.definition,
      'values': includeValues ? d.values : const <String, Object?>{},
      'fieldIds': d.fieldIds,
      'fieldOverrides': d.fieldOverrides,
      'retainedFields': d.retainedFields,
      'retainedRelations': d.retainedRelations,
      'relations': includeValues
          ? {
              for (final e in d.relations.entries)
                e.key: e.value.map((r) => r.key).toList(),
            }
          : const <String, Object?>{},
    };
    return sha256
        .convert(
          utf8.encode(
            jsonEncode(
              _canonical({
                'id': summary.id,
                'version': summary.version,
                'kind': summary.kind.name,
                'wholeDeletion': summary.wholeDeletion,
                'title': summary.title,
                'purpose': summary.purpose,
                'agent': summary.agentClaim,
                'chat': summary.chatClaim,
                'items': [
                  for (final i in items)
                    {
                      'id': i.id,
                      'proposed': snapshot(i.proposed),
                      'before': i.before == null
                          ? null
                          : snapshot(i.before!, includeValues: false),
                      'changes': [
                        for (final c in i.changes)
                          {
                            'intent': c.intent.name,
                            'key': c.key,
                            'fieldId': c.fieldId,
                            'entryId': c.entryId,
                            'leaf': c.leaf,
                            'label': c.label,
                            'after': c.after,
                            'definition': c.definition,
                          },
                      ],
                    },
                ],
              }),
            ),
          ),
        )
        .toString();
  }

  bool get canConfirm =>
      summary.pending &&
      summary.status == WorkspaceProposalStatus.pending &&
      items.isNotEmpty &&
      items.every(
        (i) =>
            i.before == null ||
            i.beforeState == WorkspaceProposalBeforeState.available &&
                i.changes.every(
                  (c) =>
                      c.intent == WorkspaceProposalFieldIntent.add ||
                      c.beforeAvailable,
                ),
      ) &&
      summary.kind != WorkspaceProposalKind.organization;
}

class WorkspaceProposalItemReview {
  WorkspaceProposalItemReview({
    required this.itemId,
    required this.name,
    required this.description,
    required Map<String, Object?> values,
    this.directoryId,
    Iterable<String> tagIds = const [],
    Map<String, List<WorkspaceRecordRef>> relations = const {},
  }) : values = workspaceImmutableMap(values),
       tagIds = List.unmodifiable(tagIds),
       relations = Map.unmodifiable({
         for (final e in relations.entries)
           e.key: List<WorkspaceRecordRef>.unmodifiable(e.value),
       });
  factory WorkspaceProposalItemReview.fromItem(WorkspaceProposalItem item) =>
      WorkspaceProposalItemReview(
        itemId: item.id,
        name: item.proposed.record.name,
        description: item.proposed.record.description,
        directoryId: item.proposed.record.directoryId,
        tagIds: item.proposed.record.tags.map((t) => t.id),
        values: item.proposed.values,
        relations: item.proposed.relations,
      );
  final String itemId, name, description;
  final String? directoryId;
  final List<String> tagIds;
  final Map<String, Object?> values;
  final Map<String, List<WorkspaceRecordRef>> relations;
  Map<String, Object?> toJson() => {
    'id': itemId,
    'name': name,
    'description': description,
    'directory': directoryId,
    'tags': tagIds,
    'values': values,
    'relations': {
      for (final e in relations.entries)
        e.key: [
          for (final r in e.value) {'kind': r.kind.name, 'id': r.id},
        ],
    },
  };
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: _canonical(value[k])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

class WorkspaceProposalChange {
  WorkspaceProposalChange({
    required this.operationId,
    required this.proposalId,
    required this.version,
    required this.reviewToken,
    required this.action,
    Iterable<WorkspaceProposalItemReview> reviewed = const [],
  }) : reviewed = List.unmodifiable(reviewed);
  final String operationId, proposalId, reviewToken;
  final int version;
  final WorkspaceProposalAction action;
  final List<WorkspaceProposalItemReview> reviewed;
  String get digest => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            _canonical({
              'operation': operationId,
              'proposal': proposalId,
              'version': version,
              'review': reviewToken,
              'action': action.name,
              'items': reviewed.map((i) => i.toJson()).toList(),
            }),
          ),
        ),
      )
      .toString();
}

class WorkspaceProposalReceipt {
  WorkspaceProposalReceipt({
    required this.operationId,
    required this.proposalId,
    required this.action,
    required this.reviewToken,
    required this.reviewedVersion,
    required this.resultingVersion,
    required this.commandDigest,
    Iterable<WorkspaceRecordReceipt> records = const [],
  }) : records = List.unmodifiable(records);
  final String operationId, proposalId, reviewToken, commandDigest;
  final int reviewedVersion, resultingVersion;
  final WorkspaceProposalAction action;
  final List<WorkspaceRecordReceipt> records;
}

/// Receipt verification needs identities and versions, never Owner old values.
class WorkspaceProposalExpectation {
  WorkspaceProposalExpectation(WorkspaceProposalDetail d)
    : kind = d.summary.kind,
      original = d.items.firstOrNull?.before?.record.ref,
      originalVersion = d.items.firstOrNull?.before?.version;
  final WorkspaceProposalKind kind;
  final WorkspaceRecordRef? original;
  final int? originalVersion;
  WorkspaceProposalReceipt check(
    WorkspaceProposalChange c,
    WorkspaceProposalReceipt r,
  ) {
    final expected = c.action == WorkspaceProposalAction.reject
        ? 0
        : c.reviewed.length;
    if (r.operationId != c.operationId ||
        r.proposalId != c.proposalId ||
        r.action != c.action ||
        r.reviewToken != c.reviewToken ||
        r.reviewedVersion != c.version ||
        r.resultingVersion <= c.version ||
        r.commandDigest != c.digest ||
        r.records.length != expected ||
        r.records.map((x) => x.ref).toSet().length != r.records.length ||
        r.records.any(
          (x) => x.ref.kind != WorkspaceRecordKind.information || x.version < 1,
        ) ||
        kind == WorkspaceProposalKind.deletion &&
            c.action == WorkspaceProposalAction.confirm &&
            r.records.any((x) => x.entryId == null || x.entryId!.isEmpty) ||
        original != null &&
            r.records.isNotEmpty &&
            (r.records.length != 1 ||
                r.records.single.ref != original ||
                r.records.single.version <= originalVersion!)) {
      throw const WorkspaceFailure('unknown_outcome', '回执与本次提案决定不符，请继续核对原操作。');
    }
    return r;
  }
}

abstract interface class WorkspaceProposalSource {
  Future<WorkspaceProposalResults> query(
    WorkspaceProposalQuery query, {
    String? keepSelection,
  });
  Future<WorkspaceProposalDetail> read(String id);
  Future<WorkspaceProposalReceipt> change(WorkspaceProposalChange change);
  Future<WorkspaceProposalReceipt?> receipt(String operationId);
  WorkspaceRelationSource relations(
    String proposalId,
    String itemId,
    int version,
  );
  Future<WorkspaceCatalog> catalog();

  /// Owner explicitly requests the exact committed ordinary-record version.
  Future<WorkspaceArchive> snapshot(
    String proposalId,
    WorkspaceRecordRef record,
  );

  /// Owner explicitly compares a pending/conflicted target with its current
  /// ordinary record. This is not part of queue metadata or an Agent aperture.
  Future<WorkspaceDetail> currentTarget(String proposalId);
}

String? workspaceProposalFieldId(
  WorkspaceDetail detail,
  WorkspaceProposalFieldChange c,
) {
  if (c.entryId == null) return detail.fieldIds[c.key];
  try {
    return WorkspaceRepeatedEntry.read(
      detail.values[c.key],
    ).where((e) => e.id == c.entryId).firstOrNull?.fieldIds[c.leaf];
  } on FormatException {
    return null;
  }
}

String? workspaceProposalFieldValue(
  WorkspaceDetail detail,
  WorkspaceProposalFieldChange c,
) {
  if (c.entryId == null) {
    return detail.values[c.key] is String
        ? detail.values[c.key] as String
        : null;
  }
  try {
    final entry = WorkspaceRepeatedEntry.read(
      detail.values[c.key],
    ).where((e) => e.id == c.entryId).firstOrNull;
    return entry?.fieldIds.containsKey(c.leaf) == true
        ? entry!.toJson()[c.leaf] as String
        : null;
  } on FormatException {
    return null;
  }
}
