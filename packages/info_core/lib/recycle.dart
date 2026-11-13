import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'information.dart';
import 'update_proposals.dart';

enum RecycleState { available, restored, purged }

enum RecycleFactKind { deleted, restored, purged }

enum DeleteProposalState { pending, confirmed, rejected, conflicted }

class DeleteProposal {
  const DeleteProposal({
    required this.id,
    required this.sessionBinding,
    required this.chatLabel,
    required this.itemId,
    required this.baseVersion,
    required this.createdAt,
    this.fieldId,
    this.state = DeleteProposalState.pending,
    this.version = 1,
    this.entryId,
    this.title = '',
    this.agentName = '',
    this.purpose = '',
    this.externalChatId = '',
    this.operationId,
    this.submissionDigest,
  });
  final String id, sessionBinding, chatLabel, itemId;
  final String? fieldId, entryId;
  final String? operationId, submissionDigest;
  final int baseVersion, version;
  final String title, agentName, purpose, externalChatId;
  final DateTime createdAt;
  final DeleteProposalState state;
  static String digestFor({
    required String itemId,
    required int baseVersion,
    String? fieldId,
    String title = '',
    String agentName = '',
    String purpose = '',
    String externalChatId = '',
  }) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            itemId,
            baseVersion,
            fieldId,
            title.trim(),
            agentName.trim(),
            purpose.trim(),
            externalChatId.trim(),
          ]),
        ),
      )
      .toString();
  bool get hasValidSubmissionIdentity =>
      operationId == null && submissionDigest == null ||
      operationId != null &&
          RegExp(
            r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
          ).hasMatch(operationId!) &&
          submissionDigest ==
              digestFor(
                itemId: itemId,
                baseVersion: baseVersion,
                fieldId: fieldId,
                title: title,
                agentName: agentName,
                purpose: purpose,
                externalChatId: externalChatId,
              );
  DeleteProposal finish(DeleteProposalState state, {String? entryId}) =>
      DeleteProposal(
        id: id,
        sessionBinding: sessionBinding,
        chatLabel: chatLabel,
        title: title,
        agentName: agentName,
        purpose: purpose,
        externalChatId: externalChatId,
        operationId: operationId,
        submissionDigest: submissionDigest,
        itemId: itemId,
        baseVersion: baseVersion,
        createdAt: createdAt,
        fieldId: fieldId,
        state: state,
        version: version + 1,
        entryId: entryId,
      );
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionBinding': sessionBinding,
    'chatLabel': chatLabel,
    if (operationId != null) ...{
      'operationId': operationId,
      'submissionDigest': submissionDigest,
    },
    if (title.isNotEmpty) 'title': title,
    if (agentName.isNotEmpty) 'agentName': agentName,
    if (purpose.isNotEmpty) 'purpose': purpose,
    if (externalChatId.isNotEmpty) 'externalChatId': externalChatId,
    'itemId': itemId,
    'baseVersion': baseVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'fieldId': fieldId,
    'state': state.name,
    'version': version,
    'entryId': entryId,
  };
  factory DeleteProposal.fromJson(Map<String, dynamic> j) {
    final operation = j['operationId'], digest = j['submissionDigest'];
    if ((operation == null) != (digest == null) ||
        operation != null &&
            (operation is! String ||
                !RegExp(
                  r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
                ).hasMatch(operation) ||
                digest is! String ||
                !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest))) {
      throw const FormatException('Invalid delete submission');
    }
    final result = DeleteProposal(
      id: j['id'] as String,
      sessionBinding: j['sessionBinding'] as String,
      chatLabel: j['chatLabel'] as String,
      title: j['title'] as String? ?? '',
      agentName: j['agentName'] as String? ?? '',
      purpose: j['purpose'] as String? ?? '',
      externalChatId: j['externalChatId'] as String? ?? '',
      operationId: operation as String?,
      submissionDigest: digest as String?,
      itemId: j['itemId'] as String,
      baseVersion: j['baseVersion'] as int,
      createdAt: DateTime.parse(j['createdAt'] as String),
      fieldId: j['fieldId'] as String?,
      state: DeleteProposalState.values.byName(j['state'] as String),
      version: j['version'] as int,
      entryId: j['entryId'] as String?,
    );
    if (!result.hasValidSubmissionIdentity) {
      throw const FormatException('Changed delete submission');
    }
    return result;
  }
}

/// Owner-only recoverable content. Terminal entries retain no content values.
class RecycleEntry {
  const RecycleEntry({
    required this.id,
    required this.itemId,
    required this.wholeItem,
    required this.deletedAt,
    required this.expiresAt,
    required this.version,
    required this.snapshot,
    this.state = RecycleState.available,
  });
  final String id, itemId;
  final bool wholeItem;
  final DateTime deletedAt, expiresAt;
  final int version;
  final InformationItem? snapshot;
  final RecycleState state;
  RecycleEntry finish(RecycleState state) => RecycleEntry(
    id: id,
    itemId: itemId,
    wholeItem: wholeItem,
    deletedAt: deletedAt,
    expiresAt: expiresAt,
    version: version,
    snapshot: null,
    state: state,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'itemId': itemId,
    'wholeItem': wholeItem,
    'deletedAt': deletedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'version': version,
    'state': state.name,
    if (snapshot != null) 'snapshot': informationToJson(snapshot!),
  };
  factory RecycleEntry.fromJson(Map<String, dynamic> j) => RecycleEntry(
    id: j['id'] as String,
    itemId: j['itemId'] as String,
    wholeItem: j['wholeItem'] as bool,
    deletedAt: DateTime.parse(j['deletedAt'] as String),
    expiresAt: DateTime.parse(j['expiresAt'] as String),
    version: j['version'] as int,
    state: RecycleState.values.byName(j['state'] as String),
    snapshot: j['snapshot'] == null
        ? null
        : informationFromJson(j['snapshot'] as Map<String, dynamic>),
  );
}

/// Durable synchronization facts and version watermarks; contain no field values.
class RecycleFact {
  RecycleFact(
    this.entryId,
    this.itemId,
    Iterable<String> fieldIds,
    this.version,
    this.kind,
    this.at, {
    Map<String, String> restoredFieldIds = const {},
  }) : fieldIds = List.unmodifiable(fieldIds),
       restoredFieldIds = Map.unmodifiable(restoredFieldIds);
  final String entryId, itemId;
  final List<String> fieldIds;
  final int version;
  final RecycleFactKind kind;
  final DateTime at;

  /// Explicit provenance written only by an owner recycle restore transaction.
  /// This is never an authorization alias and old backups need no inferred map.
  final Map<String, String> restoredFieldIds;
  Map<String, Object?> toJson() => {
    'entryId': entryId,
    'itemId': itemId,
    'fieldIds': fieldIds,
    'version': version,
    'kind': kind.name,
    'at': at.toUtc().toIso8601String(),
    if (restoredFieldIds.isNotEmpty) 'restoredFieldIds': restoredFieldIds,
  };
  factory RecycleFact.fromJson(Map<String, dynamic> j) => RecycleFact(
    j['entryId'] as String,
    j['itemId'] as String,
    (j['fieldIds'] as List).cast<String>(),
    j['version'] as int,
    RecycleFactKind.values.byName(j['kind'] as String),
    DateTime.parse(j['at'] as String),
    restoredFieldIds:
        (j['restoredFieldIds'] as Map?)?.cast<String, String>() ?? const {},
  );
}
