import 'dart:convert';
import 'workspace_credential_batches.dart';
import 'workspace_credential_programs.dart';

/// Public positioning metadata, not an authorization or a mutable row offset.
class CredentialOperationCursor {
  const CredentialOperationCursor(
    this.requestId,
    this.program,
    this.at,
    this.id,
  );
  final String requestId, id;
  final bool program;
  final DateTime at;
  String encode() => base64Url.encode(
    utf8.encode(
      jsonEncode([1, requestId, program, at.toUtc().toIso8601String(), id]),
    ),
  );
  factory CredentialOperationCursor.decode(String value) {
    try {
      if (value.length > 1024) throw const FormatException();
      final data = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(value))),
      );
      if (data is! List ||
          data.length != 5 ||
          data[0] != 1 ||
          data[1] is! String ||
          data[2] is! bool ||
          data[3] is! String ||
          data[4] is! String ||
          !_id(data[1]) ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(data[4])) {
        throw const FormatException();
      }
      final at = DateTime.parse(data[3]).toUtc();
      final result = CredentialOperationCursor(data[1], data[2], at, data[4]);
      if (result.encode() != value) throw const FormatException();
      return result;
    } on Object {
      throw const FormatException('Invalid operation cursor');
    }
  }
  static bool _id(Object value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 200 &&
      !value.contains(RegExp(r'[\x00-\x20\x7f]'));

  /// Most recent first, with a deterministic tie-breaker for equal timestamps.
  static int compare(DateTime a, String aid, DateTime b, String bid) {
    final time = b.compareTo(a);
    return time != 0 ? time : aid.compareTo(bid);
  }
}

class WorkspaceCredentialOperationPage {
  WorkspaceCredentialOperationPage({
    required this.requestId,
    required this.program,
    required this.total,
    this.cursor,
    this.nextCursor,
    Iterable<WorkspaceCredentialBatchOperation> batches = const [],
    Iterable<WorkspaceCredentialProgramOperation> programs = const [],
  }) : batches = List.unmodifiable(batches),
       programs = List.unmodifiable(programs);
  final String requestId;
  final bool program;
  final int total;
  final String? cursor, nextCursor;
  final List<WorkspaceCredentialBatchOperation> batches;
  final List<WorkspaceCredentialProgramOperation> programs;
  int get length => program ? programs.length : batches.length;
  Iterable<(DateTime, String)> get keys => program
      ? programs.map((o) => (o.createdAt, o.operationId))
      : batches.map((o) => (o.createdAt, o.operationId));
  bool validFor(
    String id,
    WorkspaceCredentialProgramPlan? plan,
    Set<String> scopes,
  ) =>
      requestId == id &&
      program == (plan != null) &&
      (program
          ? programs.every(
              (o) => o.requestId == id && plan!.accepts(o.plan, o.itemIds),
            )
          : batches.every(
              (o) => o.requestId == id && o.itemIds.every(scopes.contains),
            ));
  Map<String, Object?> toJson() => {
    'version': 1,
    'requestId': requestId,
    'program': program,
    'cursor': cursor,
    'nextCursor': nextCursor,
    'total': total,
    'batches': batches.map((o) => o.toJson()).toList(),
    'programs': programs.map((o) => o.toJson()).toList(),
  };
  factory WorkspaceCredentialOperationPage.fromJson(Map<String, dynamic> json) {
    if (json.length != 8 ||
        json.keys.any(
          (k) => !{
            'version',
            'requestId',
            'program',
            'cursor',
            'nextCursor',
            'total',
            'batches',
            'programs',
          }.contains(k),
        ) ||
        json['version'] != 1 ||
        json['requestId'] is! String ||
        json['cursor'] != null && json['cursor'] is! String ||
        json['nextCursor'] != null && json['nextCursor'] is! String ||
        json['program'] is! bool ||
        json['total'] is! int ||
        json['batches'] is! List ||
        json['programs'] is! List ||
        (json['batches'] as List).length > 50 ||
        (json['programs'] as List).length > 50) {
      throw const FormatException('Invalid operation page');
    }
    final result = WorkspaceCredentialOperationPage(
      requestId: json['requestId'] as String,
      program: json['program'] as bool,
      total: json['total'] as int,
      cursor: json['cursor'] as String?,
      nextCursor: json['nextCursor'] as String?,
      batches: (json['batches'] as List).map(
        (o) => WorkspaceCredentialBatchOperation.fromJson(
          Map<String, dynamic>.from(o as Map),
        ),
      ),
      programs: (json['programs'] as List).map(
        (o) => WorkspaceCredentialProgramOperation.fromJson(
          Map<String, dynamic>.from(o as Map),
        ),
      ),
    );
    if (!CredentialOperationCursor._id(result.requestId) ||
        result.total < result.length ||
        (result.program
            ? result.batches.isNotEmpty
            : result.programs.isNotEmpty) ||
        result.keys.map((key) => key.$2).toSet().length != result.length ||
        result.batches.any((o) => o.requestId != result.requestId) ||
        result.programs.any((o) => o.requestId != result.requestId)) {
      throw const FormatException('Invalid operation scope');
    }
    CredentialOperationCursor? after;
    if (result.cursor != null) {
      after = CredentialOperationCursor.decode(result.cursor!);
      if (after.requestId != result.requestId ||
          after.program != result.program) {
        throw const FormatException('Invalid operation page cursor');
      }
    }
    for (final key in result.keys) {
      if (after != null &&
          CredentialOperationCursor.compare(
                key.$1,
                key.$2,
                after.at,
                after.id,
              ) <=
              0) {
        throw const FormatException('Invalid operation page order');
      }
      after = CredentialOperationCursor(
        result.requestId,
        result.program,
        key.$1,
        key.$2,
      );
    }
    if (result.nextCursor != null &&
        (result.length == 0 ||
            result.nextCursor != after!.encode() ||
            result.total <= result.length)) {
      throw const FormatException('Invalid next operation cursor');
    }
    return result;
  }
}

abstract interface class WorkspaceCredentialOperationPages {
  Future<WorkspaceCredentialOperationPage> operationPage(
    String requestId, {
    String? cursor,
    int limit = 25,
  });
}
