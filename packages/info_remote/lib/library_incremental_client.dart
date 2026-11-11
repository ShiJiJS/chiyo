part of 'library_replication_client.dart';

final class RemoteVersionedInitialExport {
  RemoteVersionedInitialExport._(this.contents, this.baseline);
  final RemoteInitialExport contents;
  final LibrarySyncBaselineManifest baseline;
}

final class RemoteDeltaExport {
  RemoteDeltaExport._(this.contents, this.transfer);
  final RemoteInitialExport contents;
  final LibraryDeltaTransfer transfer;
}

/// One authenticated owner connection pinned to a library replica. This is not
/// an Agent transport and never copies a management token into a data archive.
final class LibraryIncrementalClient {
  LibraryIncrementalClient._(this.transport, this.identity, this.empty);
  final LibraryReplicationClient transport;
  final LibraryReplicaIdentity identity;
  final bool empty;
  OwnerClient get _client => transport.client;
  static const _base = LibraryReplicationClient.base;

  static T _decode<T>(T Function() parse) {
    try {
      return parse();
    } on FormatException {
      throw const RemoteFailure('invalid_response');
    } on TypeError {
      throw const RemoteFailure('invalid_response');
    }
  }

  static String _key(Object? raw) {
    if (raw is! String ||
        !RegExp(r'^aim-recovery-v1:[A-Za-z0-9_-]{43}=$').hasMatch(raw))
      throw const RemoteFailure('invalid_response');
    return raw;
  }

  static void _v2(Map<String, dynamic> result) {
    if (result['wireVersion'] != 2)
      throw const RemoteFailure('unsupported_sync');
  }

  void _sameIdentity(Object? raw) {
    final current = _decode(
      () => LibraryReplicaIdentity.fromJson(
        Map<String, dynamic>.from(raw as Map),
      ),
    );
    if (current.libraryId != identity.libraryId ||
        current.replicaId != identity.replicaId)
      throw const RemoteFailure('sync_base_changed');
  }

  static Future<LibraryIncrementalClient> connect(OwnerClient client) async {
    final info = await client.request('GET', '/v1/server');
    final caps = info['replication'];
    if (caps is! Map ||
        caps['wireVersion'] != 1 ||
        caps['incrementalWireVersion'] != 2 ||
        caps['versionedInitial'] != true ||
        caps['chunkBytes'] != LibraryReplicationClient.chunkBytes)
      throw const RemoteFailure('unsupported_sync');
    final status = await client.request('GET', '$_base/changes');
    _v2(status);
    if (status['empty'] is! bool ||
        status['cursor'] is! int ||
        status['conflicts'] is! int ||
        (status['cursor'] as int) < 0 ||
        (status['conflicts'] as int) < 0)
      throw const RemoteFailure('invalid_response');
    final identity = _decode(
      () => LibraryReplicaIdentity.fromJson(
        Map<String, dynamic>.from(status['identity'] as Map),
      ),
    );
    return LibraryIncrementalClient._(
      LibraryReplicationClient(client),
      identity,
      status['empty'] as bool,
    );
  }

  Future<List<Map<String, dynamic>>> conflicts() async {
    final result = await _client.request('GET', '$_base/changes/conflicts');
    _v2(result);
    _sameIdentity(result['identity']);
    return _decode(
      () => (result['conflicts'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
  }

  Future<Map<String, dynamic>> conflict(int cursor) async {
    if (cursor < 1) throw ArgumentError.value(cursor);
    final result = await _client.request(
      'GET',
      '$_base/changes/conflicts/$cursor',
    );
    _v2(result);
    _sameIdentity(result['identity']);
    return _decode(() => Map<String, dynamic>.from(result['conflict'] as Map));
  }

  Future<LibrarySyncReceipt> resolveConflict({
    required int cursor,
    required String token,
    required bool useIncoming,
    required String operationId,
  }) async {
    final result = await _client
        .request('POST', '$_base/changes/conflicts/resolve', {
          'wireVersion': 2,
          'cursor': cursor,
          'token': replicaDigest(token),
          'useIncoming': useIncoming,
          'operationId': replicaOperationId(operationId),
        });
    _v2(result);
    _sameIdentity(result['identity']);
    return _decode(
      () => LibrarySyncReceipt.fromJson(
        Map<String, dynamic>.from(result['receipt'] as Map),
      ),
    );
  }

  Future<({int cursor, int conflicts, bool empty})> status() async {
    final result = await _client.request('GET', '$_base/changes');
    _v2(result);
    _sameIdentity(result['identity']);
    if (result['cursor'] is! int ||
        result['conflicts'] is! int ||
        result['empty'] is! bool ||
        (result['cursor'] as int) < 0 ||
        (result['conflicts'] as int) < 0)
      throw const RemoteFailure('invalid_response');
    return (
      cursor: result['cursor'] as int,
      conflicts: result['conflicts'] as int,
      empty: result['empty'] as bool,
    );
  }

  Future<List<LibrarySyncChangeSummary>> changes(
    int cursor, {
    int limit = 32,
  }) async {
    if (cursor < 0 || limit < 1 || limit > 256)
      throw ArgumentError('Invalid change page');
    final result = await _client.request('POST', '$_base/changes/feed', {
      'wireVersion': 2,
      'cursor': cursor,
      'limit': limit,
    });
    _v2(result);
    _sameIdentity(result['identity']);
    if (result['changes'] is! List ||
        (result['changes'] as List).length > limit)
      throw const RemoteFailure('invalid_response');
    final summaries = <LibrarySyncChangeSummary>[];
    var previous = cursor;
    for (final value in result['changes'] as List) {
      final entry = _decode(
        () => LibrarySyncChangeSummary.fromJson(
          Map<String, dynamic>.from(value as Map),
        ),
      );
      if (entry.cursor <= previous || entry.libraryId != identity.libraryId)
        throw const RemoteFailure('invalid_response');
      previous = entry.cursor;
      summaries.add(entry);
    }
    return summaries;
  }

  Future<RemoteVersionedInitialExport> prepareInitial(
    String operationId,
  ) async {
    replicaOperationId(operationId);
    final result = await _client.request('POST', '$_base/versioned-exports', {
      'wireVersion': 2,
      'operationId': operationId,
    });
    _v2(result);
    final manifest = _decode(
      () => LibraryInitialTransfer.fromJson(
        Map<String, dynamic>.from(result['transfer'] as Map),
      ),
    );
    final baseline = _decode(
      () => LibrarySyncBaselineManifest.fromJson(
        Map<String, dynamic>.from(result['baseline'] as Map),
      ),
    );
    if (manifest.libraryId != identity.libraryId ||
        baseline.libraryId != manifest.libraryId ||
        baseline.snapshotId != manifest.snapshotId ||
        baseline.sourceReplicaId != identity.replicaId)
      throw const RemoteFailure('sync_base_changed');
    return RemoteVersionedInitialExport._(
      RemoteInitialExport._(
        libraryReplicaId(result['resourceId']),
        manifest,
        _key(result['transferKey']),
      ),
      baseline,
    );
  }

  Future<LibrarySyncBaseline> readBaseline(
    RemoteVersionedInitialExport source,
  ) async {
    final manifest = source.baseline;
    final bytes = BytesBuilder(copy: false);
    while (bytes.length < manifest.byteLength) {
      final length = min(
        LibraryReplicationClient.chunkBytes,
        manifest.byteLength - bytes.length,
      );
      bytes.add(
        await transport._readChunk(
          source.contents.resourceId,
          bytes.length,
          length,
          baseline: true,
        ),
      );
    }
    final value = _decode(
      () => LibrarySyncBaseline.fromJson(
        decodeProtocolObject(
          utf8.decode(bytes.takeBytes()),
          maxBytes: LibrarySyncBatch.maxBytes,
        ),
      ),
    );
    if (!manifest.matches(value))
      throw const RemoteFailure('sync_integrity_failed');
    return value;
  }

  Future<RemoteDeltaExport> prepareDelta(
    LibrarySyncChangeSummary summary,
  ) async {
    if (summary.libraryId != identity.libraryId)
      throw const RemoteFailure('sync_base_changed');
    final result = await _client.request('POST', '$_base/delta-exports', {
      'wireVersion': 2,
      'sourceReplicaId': summary.sourceReplicaId,
      'operationId': summary.operationId,
    });
    _v2(result);
    final transfer = _decode(
      () => LibraryDeltaTransfer.fromJson(
        Map<String, dynamic>.from(result['transfer'] as Map),
      ),
    );
    if (!summary.matches(transfer))
      throw const RemoteFailure('sync_operation_conflict');
    return RemoteDeltaExport._(
      RemoteInitialExport._(
        libraryReplicaId(result['resourceId']),
        transfer.archive,
        _key(result['transferKey']),
      ),
      transfer,
    );
  }

  LibrarySyncReceipt _confirmedDelta(
    Object? raw,
    LibraryDeltaTransfer transfer,
  ) {
    final receipt = _decode(
      () => LibrarySyncReceipt.fromJson(Map<String, dynamic>.from(raw as Map)),
    );
    if (receipt.libraryId != transfer.archive.libraryId ||
        receipt.receiverReplicaId != identity.replicaId ||
        receipt.sourceReplicaId != transfer.sourceReplicaId ||
        receipt.operationId != transfer.operationId ||
        receipt.digest != transfer.archive.snapshotId) {
      throw const RemoteFailure('sync_operation_conflict');
    }
    return receipt;
  }

  LibraryInitialReceipt _confirmedInitial(
    Object? raw,
    String operation,
    LibraryInitialTransfer transfer,
  ) {
    final receipt = _decode(
      () =>
          LibraryInitialReceipt.fromJson(Map<String, dynamic>.from(raw as Map)),
    );
    if (receipt.identity.replicaId != identity.replicaId)
      throw const RemoteFailure('sync_base_changed');
    return transport._confirmed(receipt, operation, transfer);
  }

  Future<LibrarySyncReceipt?> deltaReceipt(
    LibraryDeltaTransfer transfer,
  ) async {
    final result = await _client.request('POST', '$_base/changes/receipts', {
      'wireVersion': 2,
      'transfer': transfer.toJson(),
    });
    _v2(result);
    return result['receipt'] == null
        ? null
        : _confirmedDelta(result['receipt'], transfer);
  }

  /// Check the business operation before exporting a new encrypted file. The
  /// digest includes the sequence and every change; no archive or field value
  /// is sent merely to check a previously acknowledged operation.
  Future<LibrarySyncReceipt?> receiptFor(LibrarySyncBatch batch) async {
    if (batch.libraryId != identity.libraryId) {
      throw const RemoteFailure('sync_base_changed');
    }
    final result = await _client.request(
      'GET',
      '$_base/changes/receipts/${batch.sourceReplicaId}/${batch.operationId}',
    );
    _v2(result);
    if (result['receipt'] == null) return null;
    final receipt = _decode(
      () => LibrarySyncReceipt.fromJson(
        Map<String, dynamic>.from(result['receipt'] as Map),
      ),
    );
    if (receipt.libraryId != batch.libraryId ||
        receipt.receiverReplicaId != identity.replicaId ||
        receipt.sourceReplicaId != batch.sourceReplicaId ||
        receipt.operationId != batch.operationId ||
        receipt.digest != batch.digest) {
      throw const RemoteFailure('sync_operation_conflict');
    }
    return receipt;
  }

  Future<LibraryInitialReceipt?> initialReceipt(
    String operation,
    LibraryInitialTransfer transfer,
    LibrarySyncBaselineManifest baseline,
  ) async {
    replicaOperationId(operation);
    final result = await _client
        .request('POST', '$_base/changes/initial-receipts', {
          'wireVersion': 2,
          'operationId': operation,
          'transfer': transfer.toJson(),
          'baseline': baseline.toJson(),
        });
    _v2(result);
    return result['receipt'] == null
        ? null
        : _confirmedInitial(result['receipt'], operation, transfer);
  }

  Future<LibrarySyncReceipt> uploadDelta({
    required File file,
    required LibraryDeltaTransfer transfer,
    required String transferKey,
    void Function(int completed, int total)? progress,
  }) async {
    final known = await deltaReceipt(transfer);
    if (known != null) return known;
    await transport._verifyFile(file, transfer.archive);
    _key(transferKey);
    final prepared = await _client.request('POST', '$_base/delta-imports', {
      'wireVersion': 2,
      'transfer': transfer.toJson(),
    });
    _v2(prepared);
    if (prepared['receipt'] != null)
      return _confirmedDelta(prepared['receipt'], transfer);
    final resource = libraryReplicaId(prepared['resourceId']);
    final offset = prepared['offset'];
    if (offset is! int || offset < 0 || offset > transfer.archive.byteLength)
      throw const RemoteFailure('invalid_response');
    await transport._uploadFile(
      file,
      transfer.archive,
      resource,
      offset,
      progress,
    );
    final result = await _client.request(
      'POST',
      '$_base/transfers/$resource/commit',
      {'wireVersion': 1, 'transferKey': transferKey},
    );
    _v2(result);
    return _confirmedDelta(result['receipt'], transfer);
  }

  Future<LibraryInitialReceipt> uploadInitial({
    required File file,
    required LibraryInitialTransfer transfer,
    required String transferKey,
    required LibrarySyncBaseline baseline,
    required String operationId,
    void Function(int completed, int total)? progress,
  }) async {
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(baseline.toJson())),
    );
    final descriptor = LibrarySyncBaselineManifest(
      libraryId: baseline.libraryId,
      sourceReplicaId: baseline.sourceReplicaId,
      snapshotId: baseline.snapshotId,
      digest: baseline.digest,
      cursor: baseline.cursor,
      byteLength: bytes.length,
    );
    if (descriptor.libraryId != transfer.libraryId ||
        descriptor.snapshotId != transfer.snapshotId)
      throw const RemoteFailure('sync_base_changed');
    final known = await initialReceipt(operationId, transfer, descriptor);
    if (known != null) return known;
    await transport._verifyFile(file, transfer);
    _key(transferKey);
    final prepared = await _client.request('POST', '$_base/versioned-imports', {
      'wireVersion': 2,
      'operationId': operationId,
      'transfer': transfer.toJson(),
      'baseline': descriptor.toJson(),
    });
    _v2(prepared);
    if (prepared['receipt'] != null)
      return _confirmedInitial(prepared['receipt'], operationId, transfer);
    final resource = libraryReplicaId(prepared['resourceId']);
    final fileOffset = prepared['offset'];
    var offset = prepared['baselineOffset'];
    if (fileOffset is! int ||
        fileOffset < 0 ||
        fileOffset > transfer.byteLength ||
        offset is! int ||
        offset < 0 ||
        offset > bytes.length)
      throw const RemoteFailure('invalid_response');
    while (offset < bytes.length) {
      final end = min(
        offset + LibraryReplicationClient.chunkBytes,
        bytes.length,
      );
      await transport._writeChunk(
        resource,
        offset,
        Uint8List.sublistView(bytes, offset, end),
        baseline: true,
      );
      offset = end;
    }
    await transport._uploadFile(file, transfer, resource, fileOffset, progress);
    final result = await _client.request(
      'POST',
      '$_base/transfers/$resource/commit',
      {'wireVersion': 1, 'transferKey': transferKey},
    );
    _v2(result);
    return _confirmedInitial(result['receipt'], operationId, transfer);
  }
}
