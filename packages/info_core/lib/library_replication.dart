/// Versioned, owner-only metadata for a complete initial content transfer.
/// It carries neither a database key nor a chat/device authorization.
final class LibraryReplicaIdentity {
  LibraryReplicaIdentity({required this.libraryId, required this.replicaId}) {
    libraryReplicaId(libraryId);
    libraryReplicaId(replicaId);
  }
  final String libraryId, replicaId;
  Map<String, Object?> toJson() => {
    'wireVersion': 1,
    'libraryId': libraryId,
    'replicaId': replicaId,
  };
  factory LibraryReplicaIdentity.fromJson(Map<String, dynamic> value) {
    _envelope(value, {'libraryId', 'replicaId'});
    return LibraryReplicaIdentity(
      libraryId: libraryReplicaId(value['libraryId']),
      replicaId: libraryReplicaId(value['replicaId']),
    );
  }
}

final class LibraryInitialTransfer {
  LibraryInitialTransfer({
    required this.libraryId,
    required this.snapshotId,
    required this.archiveDigest,
    required this.byteLength,
    required this.contentFormat,
  }) {
    libraryReplicaId(libraryId);
    replicaDigest(snapshotId);
    replicaDigest(archiveDigest);
    if (byteLength < 4096 ||
        byteLength > 256 * 1024 * 1024 ||
        contentFormat < 8 ||
        contentFormat > 23) {
      throw const FormatException('Unsupported initial library transfer');
    }
  }
  final String libraryId, snapshotId, archiveDigest;
  final int byteLength, contentFormat;
  Map<String, Object?> toJson() => {
    'wireVersion': 1,
    'libraryId': libraryId,
    'snapshotId': snapshotId,
    'archiveDigest': archiveDigest,
    'byteLength': byteLength,
    'contentFormat': contentFormat,
  };
  factory LibraryInitialTransfer.fromJson(Map<String, dynamic> value) {
    _envelope(value, {
      'libraryId',
      'snapshotId',
      'archiveDigest',
      'byteLength',
      'contentFormat',
    });
    if (value['byteLength'] is! int || value['contentFormat'] is! int) {
      throw const FormatException('Invalid transfer size or format');
    }
    return LibraryInitialTransfer(
      libraryId: libraryReplicaId(value['libraryId']),
      snapshotId: replicaDigest(value['snapshotId']),
      archiveDigest: replicaDigest(value['archiveDigest']),
      byteLength: value['byteLength'] as int,
      contentFormat: value['contentFormat'] as int,
    );
  }
}

final class LibraryInitialReceipt {
  const LibraryInitialReceipt({
    required this.operationId,
    required this.identity,
    required this.transfer,
  });
  final String operationId;
  final LibraryReplicaIdentity identity;
  final LibraryInitialTransfer transfer;
  Map<String, Object?> toJson() => {
    'wireVersion': 1,
    'operationId': operationId,
    'identity': identity.toJson(),
    'transfer': transfer.toJson(),
  };
  factory LibraryInitialReceipt.fromJson(Map<String, dynamic> value) {
    _envelope(value, {'operationId', 'identity', 'transfer'});
    return LibraryInitialReceipt(
      operationId: replicaOperationId(value['operationId']),
      identity: LibraryReplicaIdentity.fromJson(
        Map<String, dynamic>.from(value['identity'] as Map),
      ),
      transfer: LibraryInitialTransfer.fromJson(
        Map<String, dynamic>.from(value['transfer'] as Map),
      ),
    );
  }
}

String libraryReplicaId(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(value)) {
    throw const FormatException('Invalid library identity');
  }
  return value;
}

String replicaOperationId(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
    throw const FormatException('Invalid library operation');
  }
  return value;
}

String replicaDigest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('Invalid transfer digest');
  }
  return value;
}

void _envelope(Map<String, dynamic> value, Set<String> fields) {
  if (value['wireVersion'] != 1 ||
      value.length != fields.length + 1 ||
      !fields.every(value.containsKey)) {
    throw const FormatException('Unsupported library replication format');
  }
}
