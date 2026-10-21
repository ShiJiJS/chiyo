part of 'info_core.dart';

const informationDeliveryLimit = 32;
const informationDeliveryByteLimit = 100 * 1024 * 1024;
const informationDeliveryHistoryLimit = 10000;

final class InformationFileFailure implements Exception {
  const InformationFileFailure(
    this.code, {
    this.deliveryId,
    this.operationClaimed = false,
  });
  final String code;
  final String? deliveryId;
  final bool operationClaimed;
  Map<String, Object?> toJson() => {
    'protocolVersion': 2,
    'status': switch (code) {
      'not_authorized' || 'session_ended' => 'unauthorized',
      'grant_expired' => 'expired',
      'operation_conflict' || 'field_removed' => 'conflict',
      'delivery_not_found' => 'not_found',
      'audit_failed' ||
      'service_unavailable' ||
      'delivery_capacity' => 'service_unavailable',
      'delivery_io_failed' ||
      'attachment_integrity_failed' ||
      'delivery_unknown' => 'failed',
      _ => 'invalid_request',
    },
    'errorCode': code,
    'retryable': false,
    'operationClaimed': operationClaimed,
    if (deliveryId != null) 'deliveryId': deliveryId,
  };
  @override
  String toString() => 'InformationFileFailure($code)';
}

String _deliveryId(Object? raw) {
  if (raw is! String ||
      raw.isEmpty ||
      raw.length > 200 ||
      raw.codeUnits.any((c) => c < 33 || c > 126)) {
    throw const InformationFileFailure('invalid_reference');
  }
  return raw;
}

void _deliveryShape(Map<String, dynamic> json, Set<String> keys) {
  if (json.length != keys.length || !json.keys.toSet().containsAll(keys)) {
    throw const InformationFileFailure('invalid_request');
  }
}

DateTime _deliveryDate(Object? raw) {
  if (raw is! String || raw.length > 32) {
    throw const InformationFileFailure('invalid_request');
  }
  final value = DateTime.tryParse(raw);
  if (value == null ||
      !value.isUtc ||
      value.year < 1970 ||
      value.year > 9999 ||
      value.toIso8601String() != raw) {
    throw const InformationFileFailure('invalid_request');
  }
  return value;
}

final class InformationFileFetchInput {
  const InformationFileFetchInput._(
    this.requestId,
    this.field,
    this.operationId,
  );
  final String requestId, operationId;
  final FieldRef field;
  factory InformationFileFetchInput.fromJson(Map<String, dynamic> json) {
    _deliveryShape(json, {
      'protocolVersion',
      'command',
      'requestId',
      'itemId',
      'fieldId',
      'operationId',
    });
    if (json['protocolVersion'] != 2 || json['protocolVersion'] is! int) {
      throw const InformationFileFailure('unsupported_protocol');
    }
    if (json['command'] != 'file-fetch') {
      throw const InformationFileFailure('invalid_request');
    }
    return InformationFileFetchInput._(
      _deliveryId(json['requestId']),
      FieldRef(_deliveryId(json['itemId']), _deliveryId(json['fieldId'])),
      _deliveryId(json['operationId']),
    );
  }
  Map<String, Object?> toJson() => {
    'protocolVersion': 2,
    'command': 'file-fetch',
    'requestId': requestId,
    'itemId': field.itemId,
    'fieldId': field.fieldId,
    'operationId': operationId,
  };
}

final class InformationFileDeliveryInput {
  const InformationFileDeliveryInput._(
    this.command,
    this.deliveryId,
    this.operationId,
  );
  final String command;
  final String? deliveryId, operationId;
  factory InformationFileDeliveryInput.fromJson(Map<String, dynamic> json) {
    final byOperation =
        json['command'] == 'file-status' && json.containsKey('operationId');
    _deliveryShape(json, {
      'protocolVersion',
      'command',
      byOperation ? 'operationId' : 'deliveryId',
    });
    if (json['protocolVersion'] != 2 || json['protocolVersion'] is! int) {
      throw const InformationFileFailure('unsupported_protocol');
    }
    if (!{'file-status', 'file-release'}.contains(json['command'])) {
      throw const InformationFileFailure('invalid_request');
    }
    return InformationFileDeliveryInput._(
      json['command'] as String,
      byOperation ? null : _deliveryId(json['deliveryId']),
      byOperation ? _deliveryId(json['operationId']) : null,
    );
  }
}

/// Durable operation and cleanup facts. Private registry/session association
/// never appear in status/history projections or portable archives.
final class InformationFileDelivery {
  InformationFileDelivery._(this._json);
  final Map<String, Object?> _json;
  static const states = {
    'preparing',
    'ready',
    'released',
    'expired',
    'cleanup_pending',
    'failed',
    'unknown',
  };
  static const terminals = {'released', 'expired', 'failed', 'unknown'};
  static const reasons = {
    'released',
    'grant_expired',
    'not_authorized',
    'session_ended',
    'field_removed',
    'restarted',
    'service_closed',
    'delivery_io_failed',
    'attachment_integrity_failed',
    'audit_failed',
    'delivery_unknown',
  };
  static const cleanupErrors = {'cleanup_failed', 'cleanup_identity_mismatch'};
  String get id => _json['id'] as String;
  String? get sessionBinding => _json['sessionBinding'] as String?;
  String get operationId => _json['operationId'] as String;
  String get requestId => _json['requestId'] as String;
  String get grantId => _json['grantId'] as String;
  RecordedField get field =>
      RecordedField.fromJson(Map<String, dynamic>.from(_json['field'] as Map));
  FieldRef get fieldRef => FieldRef(field.itemId, field.fieldId);
  int get fieldVersion => _json['fieldVersion'] as int;
  InformationAttachmentRef get attachment => InformationAttachmentRef.fromJson(
    Map<String, dynamic>.from(_json['attachment'] as Map),
  );
  String get fileName => _json['fileName'] as String;
  String get mediaType => _json['mediaType'] as String;
  int get byteLength => _json['byteLength'] as int;
  String get sha256 => _json['sha256'] as String;
  DateTime get createdAt => _deliveryDate(_json['createdAt']);
  DateTime get expiresAt => _deliveryDate(_json['expiresAt']);
  DateTime? get finishedAt =>
      _json['finishedAt'] == null ? null : _deliveryDate(_json['finishedAt']);
  String get state => _json['state'] as String;
  String? get targetState => _json['targetState'] as String?;
  String? get reason => _json['reason'] as String?;
  String? get cleanupError => _json['cleanupError'] as String?;
  InformationDeliveryLease? get lease => _json['lease'] == null
      ? null
      : InformationDeliveryLease.fromPrivateJson(
          Map<String, dynamic>.from(_json['lease'] as Map),
        );
  bool get runtime => _json['runtime'] as bool;
  DateTime? get restoredAt =>
      _json['restoredAt'] == null ? null : _deliveryDate(_json['restoredAt']);
  bool get holdsCopy => runtime && (lease != null || state == 'preparing');
  factory InformationFileDelivery.preparing({
    required String id,
    required String sessionBinding,
    required String operationId,
    required String requestId,
    required String grantId,
    required RecordedField field,
    required int fieldVersion,
    required InformationAttachmentVersion version,
    required DateTime createdAt,
    required DateTime expiresAt,
  }) => InformationFileDelivery.fromPrivateJson({
    'id': id,
    'sessionBinding': sessionBinding,
    'operationId': operationId,
    'requestId': requestId,
    'grantId': grantId,
    'field': field.toJson(),
    'fieldVersion': fieldVersion,
    'attachment': version.reference.toJson(),
    'fileName': version.originalName,
    'mediaType': version.mediaType,
    'byteLength': version.byteLength,
    'sha256': version.sha256,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'state': 'preparing',
    'targetState': null,
    'reason': null,
    'cleanupError': null,
    'lease': null,
    'runtime': true,
    'restoredAt': null,
    'finishedAt': null,
  });
  factory InformationFileDelivery.fromPrivateJson(Map<String, dynamic> j) {
    _deliveryShape(j, {
      'id',
      'sessionBinding',
      'operationId',
      'requestId',
      'grantId',
      'field',
      'fieldVersion',
      'attachment',
      'fileName',
      'mediaType',
      'byteLength',
      'sha256',
      'createdAt',
      'expiresAt',
      'state',
      'targetState',
      'reason',
      'cleanupError',
      'lease',
      'runtime',
      'restoredAt',
      'finishedAt',
    });
    for (final k in ['id', 'operationId', 'requestId', 'grantId']) {
      _deliveryId(j[k]);
    }
    if (j['runtime'] is! bool ||
        !states.contains(j['state']) ||
        j['field'] is! Map<String, dynamic> ||
        j['attachment'] is! Map<String, dynamic> ||
        j['fieldVersion'] is! int ||
        (j['fieldVersion'] as int) < 1 ||
        (j['fieldVersion'] as int) > 2147483647 ||
        j['fileName'] is! String ||
        j['mediaType'] is! String ||
        j['byteLength'] is! int ||
        j['sha256'] is! String) {
      throw const InformationFileFailure('invalid_request');
    }
    final f = j['field'] as Map<String, dynamic>;
    _deliveryShape(f, {'itemId', 'fieldId', 'itemName', 'fieldName'});
    _deliveryId(f['itemId']);
    _deliveryId(f['fieldId']);
    for (final k in ['itemName', 'fieldName']) {
      if (f[k] is! String ||
          (f[k] as String).trim().isEmpty ||
          (f[k] as String).length > 200) {
        throw const InformationFileFailure('invalid_request');
      }
    }
    final attachment = InformationAttachmentRef.fromJson(
      j['attachment'] as Map<String, dynamic>,
    );
    if (attachment.attachmentVersion > 2147483647) {
      throw const InformationFileFailure('invalid_request');
    }
    InformationFileStage(
      id: 'check',
      draftId: 'check',
      originalName: j['fileName'] as String,
      mediaType: j['mediaType'] as String,
      byteLength: j['byteLength'] as int,
      sha256: j['sha256'] as String,
    );
    final created = _deliveryDate(j['createdAt']),
        expires = _deliveryDate(j['expiresAt']);
    if (!expires.isAfter(created) ||
        j['reason'] != null && !reasons.contains(j['reason']) ||
        j['cleanupError'] != null &&
            !cleanupErrors.contains(j['cleanupError']) ||
        j['targetState'] != null && !terminals.contains(j['targetState'])) {
      throw const InformationFileFailure('invalid_request');
    }
    if (j['finishedAt'] != null) _deliveryDate(j['finishedAt']);
    if (j['restoredAt'] != null) _deliveryDate(j['restoredAt']);
    final active = {'preparing', 'ready'}.contains(j['state']);
    if (active &&
            (j['finishedAt'] != null ||
                j['targetState'] != null ||
                j['reason'] != null ||
                j['cleanupError'] != null) ||
        j['state'] == 'cleanup_pending' &&
            (j['targetState'] == null ||
                j['finishedAt'] == null ||
                j['reason'] == null) ||
        terminals.contains(j['state']) &&
            (j['targetState'] != null ||
                j['finishedAt'] == null ||
                j['reason'] == null ||
                j['cleanupError'] != null)) {
      throw const InformationFileFailure('invalid_request');
    }
    InformationDeliveryLease? lease;
    if (j['lease'] != null) {
      if (j['lease'] is! Map<String, dynamic>) {
        throw const InformationFileFailure('invalid_request');
      }
      lease = InformationDeliveryLease.fromPrivateJson(
        j['lease'] as Map<String, dynamic>,
      );
    }
    if (j['runtime'] == true) {
      _deliveryId(j['sessionBinding']);
      if (j['restoredAt'] != null ||
          j['state'] == 'ready' && (lease == null || j['finishedAt'] != null) ||
          j['state'] == 'preparing' && j['finishedAt'] != null ||
          j['state'] == 'cleanup_pending' &&
              (lease == null ||
                  j['targetState'] == null ||
                  j['finishedAt'] == null) ||
          terminals.contains(j['state']) &&
              (lease != null ||
                  j['targetState'] != null ||
                  j['finishedAt'] == null)) {
        throw const InformationFileFailure('invalid_request');
      }
    } else if (j['sessionBinding'] != null || lease != null) {
      throw const InformationFileFailure('invalid_request');
    }
    return InformationFileDelivery._(
      Map.unmodifiable({
        ...j,
        'field': Map.unmodifiable(f),
        'attachment': Map.unmodifiable(attachment.toJson()),
        'lease': lease == null ? null : Map.unmodifiable(lease.toPrivateJson()),
      }),
    );
  }
  Map<String, Object?> toPrivateJson() => {
    ..._json,
    'field': field.toJson(),
    'attachment': attachment.toJson(),
    'lease': lease?.toPrivateJson(),
  };
  InformationFileDelivery changed(Map<String, Object?> changes) =>
      InformationFileDelivery.fromPrivateJson({...toPrivateJson(), ...changes});
  Map<String, Object?> statusJson() => {
    'deliveryId': id,
    'itemId': field.itemId,
    'fieldId': field.fieldId,
    'fieldVersion': fieldVersion,
    'attachmentVersion': attachment.attachmentVersion,
    'state': state,
    'expiresAt': expiresAt.toIso8601String(),
    'errorCode': ?cleanupError ?? reason,
  };
  Map<String, Object?> readyJson() => {
    ...statusJson(),
    'fileName': fileName,
    'mediaType': mediaType,
    'byteLength': byteLength,
    'path': lease!.filePath,
  };
  Map<String, Object?> historyJson() => {
    ...statusJson(),
    'operationId': operationId,
    'requestId': requestId,
    'grantId': grantId,
    'field': field.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'restoredAt': restoredAt?.toIso8601String(),
  };

  /// Portable facts use an explicit allowlist, never the private runtime DTO.
  Map<String, Object?> toArchiveJson() => {
    'id': id,
    'operationId': operationId,
    'requestId': requestId,
    'grantId': grantId,
    'field': field.toJson(),
    'fieldVersion': fieldVersion,
    'attachment': attachment.toJson(),
    'fileName': fileName,
    'mediaType': mediaType,
    'byteLength': byteLength,
    'sha256': sha256,
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    'state': state,
    'targetState': targetState,
    'reason': reason,
    'cleanupError': cleanupError,
    'restoredAt': restoredAt?.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
  };
  factory InformationFileDelivery.fromArchiveJson(Map<String, dynamic> json) {
    _deliveryShape(json, {
      'id',
      'operationId',
      'requestId',
      'grantId',
      'field',
      'fieldVersion',
      'attachment',
      'fileName',
      'mediaType',
      'byteLength',
      'sha256',
      'createdAt',
      'expiresAt',
      'state',
      'targetState',
      'reason',
      'cleanupError',
      'restoredAt',
      'finishedAt',
    });
    return InformationFileDelivery.fromPrivateJson({
      ...json,
      'sessionBinding': null,
      'runtime': false,
      'lease': null,
    });
  }
  @override
  String toString() => 'InformationFileDelivery($state)';
}

abstract interface class InformationFileDeliveryRepository {
  List<InformationFileDelivery> get informationFileDeliveries;
  Future<void> saveInformationFileDelivery(InformationFileDelivery delivery);
  Future<void> pruneInformationFileDeliveryHistory(Set<String> ids);
}
