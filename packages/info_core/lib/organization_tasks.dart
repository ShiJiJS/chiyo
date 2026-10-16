enum OrganizationTaskState {
  pending,
  active,
  proposed,
  confirmed,
  rejected,
  cancelled,
  expired,
  conflicted,
}

class OrganizationChange {
  OrganizationChange({
    required this.itemId,
    required this.baseVersion,
    this.directoryId,
    this.directoryName = '',
    Iterable<String> tagIds = const [],
    Iterable<String> tagNames = const [],
  }) : tagIds = List.unmodifiable(tagIds),
       tagNames = List.unmodifiable(tagNames);
  final String itemId, directoryName;
  final String? directoryId;
  final int baseVersion;
  final List<String> tagIds, tagNames;
  Map<String, Object?> toJson() => {
    'itemId': itemId,
    'baseVersion': baseVersion,
    'directoryId': directoryId,
    'directoryName': directoryName,
    'tagIds': tagIds,
    'tagNames': tagNames,
  };
  factory OrganizationChange.fromJson(Map<String, dynamic> j) =>
      OrganizationChange(
        itemId: j['itemId'] as String,
        baseVersion: j['baseVersion'] as int,
        directoryId: j['directoryId'] as String?,
        directoryName: j['directoryName'] as String? ?? '',
        tagIds: (j['tagIds'] as List? ?? []).cast<String>(),
        tagNames: (j['tagNames'] as List? ?? []).cast<String>(),
      );
}

/// Contains identities and organization metadata only, never information values.
class OrganizationTask {
  OrganizationTask({
    required this.id,
    required this.sessionBinding,
    required this.chatLabel,
    required this.purpose,
    required this.createdAt,
    required this.expiresAt,
    required Map<String, int> itemVersions,
    this.state = OrganizationTaskState.active,
    this.agentName = '',
    this.approvedAt,
    this.autoApply = false,
    Iterable<OrganizationChange> changes = const [],
  }) : itemVersions = Map.unmodifiable(itemVersions),
       changes = List.unmodifiable(changes);
  final String id, sessionBinding, chatLabel, purpose;
  final DateTime createdAt, expiresAt;
  final DateTime? approvedAt;
  final String agentName;
  final bool autoApply;
  final Map<String, int> itemVersions;
  final OrganizationTaskState state;
  final List<OrganizationChange> changes;
  OrganizationTask withState(
    OrganizationTaskState state, {
    List<OrganizationChange>? changes,
    Map<String, int>? itemVersions,
    DateTime? expiresAt,
    DateTime? approvedAt,
    bool? autoApply,
  }) => OrganizationTask(
    id: id,
    sessionBinding: sessionBinding,
    chatLabel: chatLabel,
    purpose: purpose,
    createdAt: createdAt,
    expiresAt: expiresAt ?? this.expiresAt,
    itemVersions: itemVersions ?? this.itemVersions,
    agentName: agentName,
    approvedAt: approvedAt ?? this.approvedAt,
    autoApply: autoApply ?? this.autoApply,
    state: state,
    changes: changes ?? this.changes,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionBinding': sessionBinding,
    'chatLabel': chatLabel,
    'purpose': purpose,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'itemVersions': itemVersions,
    'state': state.name,
    'agentName': agentName,
    'approvedAt': approvedAt?.toUtc().toIso8601String(),
    'autoApply': autoApply,
    'changes': changes.map((c) => c.toJson()).toList(),
  };
  factory OrganizationTask.fromJson(Map<String, dynamic> j) => OrganizationTask(
    id: j['id'] as String,
    sessionBinding: j['sessionBinding'] as String,
    chatLabel: j['chatLabel'] as String,
    purpose: j['purpose'] as String,
    agentName: j['agentName'] as String? ?? '',
    approvedAt: j['approvedAt'] == null
        ? null
        : DateTime.parse(j['approvedAt'] as String),
    autoApply: j['autoApply'] as bool? ?? false,
    createdAt: DateTime.parse(j['createdAt'] as String),
    expiresAt: DateTime.parse(j['expiresAt'] as String),
    itemVersions: (j['itemVersions'] as Map<String, dynamic>)
        .cast<String, int>(),
    state: OrganizationTaskState.values.byName(j['state'] as String),
    changes: (j['changes'] as List).map(
      (dynamic c) => OrganizationChange.fromJson(c as Map<String, dynamic>),
    ),
  );
}
