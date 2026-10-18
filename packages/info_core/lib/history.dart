import 'organization_tasks.dart';

/// Past facts only. None of these identifiers are authorization capabilities.
enum AccessRequestState {
  pending,
  approved,
  denied,
  expired,
  cancelled,
  revoked,
}

/// Durable, non-secret request outcome. Pending requests are never stored.
class RequestHistory {
  RequestHistory({
    required this.id,
    required this.sessionId,
    required this.chatLabel,
    required this.purpose,
    required this.createdAt,
    required this.requestExpiresAt,
    required this.recordedAt,
    required this.state,
    required Iterable<RecordedField> fields,
    this.grantId,
    this.sessionEnded = false,
    this.applicationClosed = false,
    this.restoredAt,
  }) : fields = List.unmodifiable(fields);
  final String id, sessionId, chatLabel, purpose;
  final DateTime createdAt, requestExpiresAt, recordedAt;
  final AccessRequestState state;
  final List<RecordedField> fields;
  final String? grantId;
  final bool sessionEnded, applicationClosed;
  final DateTime? restoredAt;
  RequestHistory asRestored(DateTime at) => RequestHistory(
    id: id,
    sessionId: sessionId,
    chatLabel: chatLabel,
    purpose: purpose,
    createdAt: createdAt,
    requestExpiresAt: requestExpiresAt,
    recordedAt: recordedAt,
    state: state,
    fields: fields,
    grantId: grantId,
    sessionEnded: sessionEnded,
    applicationClosed: applicationClosed,
    restoredAt: at,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'chatLabel': chatLabel,
    'purpose': purpose,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'requestExpiresAt': requestExpiresAt.toUtc().toIso8601String(),
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'state': state.name,
    'fields': fields.map((f) => f.toJson()).toList(),
    'grantId': grantId,
    'sessionEnded': sessionEnded,
    'applicationClosed': applicationClosed,
    if (restoredAt != null) 'restoredAt': restoredAt!.toUtc().toIso8601String(),
  };
  factory RequestHistory.fromJson(Map<String, dynamic> j) => RequestHistory(
    id: j['id'] as String,
    sessionId: j['sessionId'] as String,
    chatLabel: j['chatLabel'] as String,
    purpose: j['purpose'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    requestExpiresAt: DateTime.parse(j['requestExpiresAt'] as String),
    recordedAt: DateTime.parse(j['recordedAt'] as String),
    state: AccessRequestState.values.byName(j['state'] as String),
    fields: (j['fields'] as List).map(
      (f) => RecordedField.fromJson(f as Map<String, dynamic>),
    ),
    grantId: j['grantId'] as String?,
    sessionEnded: j['sessionEnded'] == true,
    applicationClosed: j['applicationClosed'] == true,
    restoredAt: j['restoredAt'] == null
        ? null
        : DateTime.parse(j['restoredAt'] as String),
  );
}

enum GrantEventKind { approved, revoked, expired, ended, applicationClosed }

enum AccessOutcome { allowed, unauthorized, auditUnavailable }

class RecordedField {
  const RecordedField(this.itemId, this.fieldId, this.itemName, this.fieldName);
  final String itemId, fieldId, itemName, fieldName;
  Map<String, Object?> toJson() => {
    'itemId': itemId,
    'fieldId': fieldId,
    'itemName': itemName,
    'fieldName': fieldName,
  };
  factory RecordedField.fromJson(Map<String, dynamic> json) => RecordedField(
    json['itemId'] as String,
    json['fieldId'] as String,
    json['itemName'] as String,
    json['fieldName'] as String,
  );
}

class GrantEvent {
  const GrantEvent(this.kind, this.at);
  final GrantEventKind kind;
  final DateTime at;
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'at': at.toUtc().toIso8601String(),
  };
  factory GrantEvent.fromJson(Map<String, dynamic> json) => GrantEvent(
    GrantEventKind.values.byName(json['kind'] as String),
    DateTime.parse(json['at'] as String),
  );
}

class GrantHistory {
  GrantHistory({
    required this.id,
    required this.requestId,
    required this.sessionId,
    required this.chatLabel,
    required this.approvedAt,
    required this.expiresAt,
    required Iterable<RecordedField> fields,
    required Iterable<GrantEvent> events,
    this.restoredAt,
  }) : fields = List.unmodifiable(fields),
       events = List.unmodifiable(events);
  final String id, requestId, sessionId, chatLabel;
  final DateTime approvedAt, expiresAt;

  /// Imported facts never represent a live permission in this installation.
  final DateTime? restoredAt;
  final List<RecordedField> fields;
  final List<GrantEvent> events;
  bool get active =>
      restoredAt == null && events.last.kind == GrantEventKind.approved;
  GrantHistory asRestored(DateTime at) => GrantHistory(
    id: id,
    requestId: requestId,
    sessionId: sessionId,
    chatLabel: chatLabel,
    approvedAt: approvedAt,
    expiresAt: expiresAt,
    fields: fields,
    events: events,
    restoredAt: at,
  );
  GrantHistory finish(GrantEventKind kind, DateTime at) => GrantHistory(
    id: id,
    requestId: requestId,
    sessionId: sessionId,
    chatLabel: chatLabel,
    approvedAt: approvedAt,
    expiresAt: expiresAt,
    fields: fields,
    events: [...events, GrantEvent(kind, at)],
    restoredAt: restoredAt,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'requestId': requestId,
    'sessionId': sessionId,
    'chatLabel': chatLabel,
    'approvedAt': approvedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'fields': fields.map((f) => f.toJson()).toList(),
    'events': events.map((e) => e.toJson()).toList(),
    if (restoredAt != null) 'restoredAt': restoredAt!.toUtc().toIso8601String(),
  };
  factory GrantHistory.fromJson(Map<String, dynamic> json) => GrantHistory(
    id: json['id'] as String,
    requestId: json['requestId'] as String,
    sessionId: json['sessionId'] as String,
    chatLabel: json['chatLabel'] as String,
    approvedAt: DateTime.parse(json['approvedAt'] as String),
    expiresAt: DateTime.parse(json['expiresAt'] as String),
    fields: (json['fields'] as List).map(
      (f) => RecordedField.fromJson(f as Map<String, dynamic>),
    ),
    events: (json['events'] as List).map(
      (e) => GrantEvent.fromJson(e as Map<String, dynamic>),
    ),
    restoredAt: json['restoredAt'] == null
        ? null
        : DateTime.parse(json['restoredAt'] as String),
  );
}

class AccessRecord {
  const AccessRecord({
    required this.id,
    required this.at,
    required this.outcome,
    this.sessionId,
    this.grantId,
    this.itemId,
    this.fieldId,
    this.itemName,
    this.fieldName,
  });
  final String id;
  final DateTime at;
  final AccessOutcome outcome;
  final String? sessionId, grantId, itemId, fieldId;
  final String? itemName, fieldName;
  Map<String, Object?> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'operation': 'read',
    'outcome': outcome.name,
    'sessionId': sessionId,
    'grantId': grantId,
    'itemId': itemId,
    'fieldId': fieldId,
    if (itemName != null) 'itemName': itemName,
    if (fieldName != null) 'fieldName': fieldName,
  };
  factory AccessRecord.fromJson(Map<String, dynamic> json) => AccessRecord(
    id: json['id'] as String,
    at: DateTime.parse(json['at'] as String),
    outcome: AccessOutcome.values.byName(json['outcome'] as String),
    sessionId: json['sessionId'] as String?,
    grantId: json['grantId'] as String?,
    itemId: json['itemId'] as String?,
    fieldId: json['fieldId'] as String?,
    itemName: json['itemName'] as String?,
    fieldName: json['fieldName'] as String?,
  );
}

class AuditHistory {
  AuditHistory(
    Iterable<GrantHistory> grants,
    Iterable<AccessRecord> accesses, [
    Iterable<RequestHistory> requests = const [],
    Iterable<OrganizationTask> organizations = const [],
  ]) : grants = List.unmodifiable(grants),
       accesses = List.unmodifiable(accesses),
       requests = List.unmodifiable(requests),
       organizations = List.unmodifiable(organizations);
  final List<GrantHistory> grants;
  final List<AccessRecord> accesses;
  final List<RequestHistory> requests;
  final List<OrganizationTask> organizations;
  Map<String, Object?> toJson() => {
    'grants': grants.map((g) => g.toJson()).toList(),
    'accesses': accesses.map((a) => a.toJson()).toList(),
    'requests': requests.map((r) => r.toJson()).toList(),
    'organizations': organizations.map((t) => t.toJson()).toList(),
  };
}

class AuditRetentionPreview {
  const AuditRetentionPreview(
    this.days,
    this.grants,
    this.accesses,
    this.cutoff, [
    this.requests = 0,
    this.organizations = 0,
    this.credentialRequests = 0,
    this.credentialExecutions = 0,
  ]);
  final int days, grants, accesses, requests, organizations;
  final int credentialRequests, credentialExecutions;
  final DateTime cutoff;
}
