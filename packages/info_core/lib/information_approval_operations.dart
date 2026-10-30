part of 'info_core.dart';

enum InformationApprovalAction { approve, deny, revoke }

/// Durable owner decision identity. No field value, bearer or session secret.
final class InformationApprovalReceipt {
  InformationApprovalReceipt({
    required this.operationId,
    required this.requestId,
    required this.action,
    required this.reviewToken,
    required this.commandDigest,
    required this.revision,
    required this.recordedAt,
  }) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(operationId) ||
        requestId.isEmpty ||
        requestId.length > 200 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(reviewToken) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(commandDigest) ||
        revision < 1) {
      throw const FormatException('Invalid approval receipt');
    }
  }
  final String operationId, requestId, reviewToken, commandDigest;
  final InformationApprovalAction action;
  final int revision;
  final DateTime recordedAt;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'requestId': requestId,
    'action': action.name,
    'reviewToken': reviewToken,
    'commandDigest': commandDigest,
    'revision': revision,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
  };
  factory InformationApprovalReceipt.fromJson(Map<String, dynamic> json) {
    if (json.length != 7) {
      throw const FormatException('Invalid approval receipt');
    }
    return InformationApprovalReceipt(
      operationId: json['operationId'] as String,
      requestId: json['requestId'] as String,
      action: InformationApprovalAction.values.byName(json['action'] as String),
      reviewToken: json['reviewToken'] as String,
      commandDigest: json['commandDigest'] as String,
      revision: json['revision'] as int,
      recordedAt: DateTime.parse(json['recordedAt'] as String),
    );
  }
}

/// A single persistent decision with its audit facts. Publishing a live grant
/// remains the core service's responsibility after a successful commit.
final class InformationApprovalCommit {
  InformationApprovalCommit({
    required this.receipt,
    required this.request,
    this.grant,
    Map<String, int> itemVersions = const {},
  }) : itemVersions = Map.unmodifiable(itemVersions) {
    final expectedState = switch (receipt.action) {
      InformationApprovalAction.approve => AccessRequestState.approved,
      InformationApprovalAction.deny => AccessRequestState.denied,
      InformationApprovalAction.revoke => AccessRequestState.revoked,
    };
    if (request.id != receipt.requestId ||
        request.state != expectedState ||
        request.recordedAt != receipt.recordedAt ||
        request.restoredAt != null ||
        itemVersions.length > 200 ||
        itemVersions.values.any((v) => v < 1) ||
        (receipt.action == InformationApprovalAction.deny
            ? grant != null ||
                  request.grantId != null ||
                  itemVersions.isNotEmpty
            : grant == null ||
                  grant!.id != request.grantId ||
                  grant!.requestId != request.id ||
                  grant!.sessionId != request.sessionId ||
                  grant!.events.isEmpty ||
                  grant!.restoredAt != null ||
                  grant!.fields.isEmpty ||
                  grant!.fields.length > 200 ||
                  grant!.active !=
                      (receipt.action == InformationApprovalAction.approve))) {
      throw const FormatException('Inconsistent approval commit');
    }
    if (receipt.action == InformationApprovalAction.approve) {
      final ids = grant!.fields.map((f) => f.itemId).toSet();
      if (request.sessionEnded ||
          request.applicationClosed ||
          grant!.approvedAt != receipt.recordedAt ||
          grant!.events.length != 1 ||
          grant!.events.single.kind != GrantEventKind.approved ||
          grant!.events.single.at != receipt.recordedAt ||
          !grant!.expiresAt.isAfter(receipt.recordedAt) ||
          ids.length != itemVersions.length ||
          !ids.containsAll(itemVersions.keys) ||
          grant!.fields.any(
            (f) => !request.fields.any(
              (r) => r.itemId == f.itemId && r.fieldId == f.fieldId,
            ),
          )) {
        throw const FormatException('Invalid approved scope');
      }
    } else if (receipt.action == InformationApprovalAction.revoke &&
        (itemVersions.isNotEmpty ||
            grant!.events.last.kind != GrantEventKind.revoked)) {
      throw const FormatException('Invalid revocation');
    }
    if (receipt.action != InformationApprovalAction.revoke &&
        (request.sessionEnded ||
            request.applicationClosed ||
            receipt.recordedAt.isBefore(request.createdAt) ||
            !receipt.recordedAt.isBefore(request.requestExpiresAt))) {
      throw const FormatException('Invalid decision lifetime');
    }
  }
  void validatePrevious(RequestHistory? previous, GrantHistory? previousGrant) {
    if (receipt.action != InformationApprovalAction.revoke) {
      if (previous != null || previousGrant != null) {
        throw const AccessFailure('request_changed');
      }
      return;
    }
    if (previous == null ||
        previous.state != AccessRequestState.approved ||
        previous.restoredAt != null ||
        previous.sessionEnded ||
        previous.applicationClosed ||
        previous.grantId != grant!.id ||
        receipt.recordedAt.isBefore(previous.recordedAt) ||
        jsonEncode({
              ...previous.toJson(),
              'state': AccessRequestState.revoked.name,
              'recordedAt': receipt.recordedAt.toUtc().toIso8601String(),
            }) !=
            jsonEncode(request.toJson()) ||
        previousGrant == null ||
        !previousGrant.active ||
        jsonEncode(
              previousGrant
                  .finish(GrantEventKind.revoked, receipt.recordedAt)
                  .toJson(),
            ) !=
            jsonEncode(grant!.toJson())) {
      throw const AccessFailure('request_changed');
    }
  }

  final InformationApprovalReceipt receipt;
  final RequestHistory request;
  final GrantHistory? grant;
  final Map<String, int> itemVersions;
}

abstract interface class InformationApprovalRepository {
  Future<InformationApprovalReceipt?> informationApprovalReceipt(
    String operationId,
  );
  Future<int> informationApprovalRevision(String requestId);
  Future<void> commitInformationApproval(
    InformationApprovalCommit change, {
    void Function()? validate,
  });
}
