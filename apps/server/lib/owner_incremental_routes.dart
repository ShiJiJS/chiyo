part of 'owner_replication_routes.dart';

/// At most two live resources share the existing quota. Each baseline is at
/// most 64 MiB, so buffers total <=128 MiB; metadata is never written plaintext.
final class _BaselineTransfer {
  _BaselineTransfer.outgoing(LibrarySyncBaseline value)
    : manifest = LibrarySyncBaselineManifest.of(value),
      bytes = Uint8List.fromList(utf8.encode(jsonEncode(value.toJson()))),
      uploaded = 0;
  _BaselineTransfer.incoming(this.manifest)
    : bytes = Uint8List(manifest.byteLength),
      uploaded = 0;
  final LibrarySyncBaselineManifest manifest;
  final Uint8List bytes;
  int uploaded;
  LibrarySyncBaseline decode() {
    if (uploaded != manifest.byteLength)
      throw const StorageFailure('sync_integrity_failed');
    final value = LibrarySyncBaseline.fromJson(
      decodeProtocolObject(
        utf8.decode(bytes),
        maxBytes: LibrarySyncBatch.maxBytes,
      ),
    );
    if (!manifest.matches(value))
      throw const StorageFailure('sync_integrity_failed');
    return value;
  }
}

extension _OwnerIncrementalRoutes on OwnerReplicationRoutes {
  Future<void> _readyIncremental() async {
    final pending = _incrementalReady ??= owner.exportLibrary(
      _incremental.start,
    );
    try {
      await pending;
    } on Object {
      if (identical(_incrementalReady, pending)) _incrementalReady = null;
      rethrow;
    }
  }

  Future<_TransferFile> _versionedExport(
    String operation,
    String cacheKey,
  ) async {
    final file = await _newFile();
    try {
      final prepared = await owner.exportLibrary(
        () => _incremental.exportInitialWithBaseline(file.path),
      );
      final result = _TransferFile(
        _id(),
        operation,
        file,
        prepared.initial.transfer,
        _elapsed() + OwnerReplicationRoutes.lifetime,
        key: prepared.initial.transferKey,
        cacheKey: cacheKey,
        baseline: _BaselineTransfer.outgoing(prepared.baseline),
      );
      _files[result.id] = result;
      return result;
    } on Object {
      await file.parent.delete(recursive: true);
      rethrow;
    }
  }

  Future<_TransferFile> _deltaExport(
    String source,
    String operation,
    String cacheKey,
  ) async {
    final file = await _newFile();
    try {
      final prepared = await owner.exportLibrary(
        () => _incremental.exportDelta(
          file.path,
          sourceReplicaId: source,
          operationId: operation,
        ),
      );
      final result = _TransferFile(
        _id(),
        operation,
        file,
        prepared.transfer.archive,
        _elapsed() + OwnerReplicationRoutes.lifetime,
        key: prepared.transferKey,
        cacheKey: cacheKey,
        delta: prepared.transfer,
      );
      _files[result.id] = result;
      return result;
    } on Object {
      await file.parent.delete(recursive: true);
      rethrow;
    }
  }

  Future<(int, Map<String, Object?>)> _dispatchIncremental(
    String method,
    List<String> tail,
    Object? raw,
  ) async {
    await _readyIncremental();
    if (tail.length == 2 &&
        tail[0] == 'changes' &&
        tail[1] == 'conflicts' &&
        method == 'GET') {
      final entries = await owner.exportLibrary(
        () => _incremental.conflictCursors(),
      );
      return (
        200,
        {
          'wireVersion': 2,
          'identity': (await replication.identity()).toJson(),
          'conflicts': [
            for (final cursor in entries) {'cursor': cursor},
          ],
        },
      );
    }
    if (tail.length == 3 &&
        tail[0] == 'changes' &&
        tail[1] == 'conflicts' &&
        method == 'GET') {
      final cursor = int.tryParse(tail[2]);
      if (cursor == null || cursor < 1) throw const FormatException();
      return (
        200,
        {
          'wireVersion': 2,
          'identity': (await replication.identity()).toJson(),
          'conflict': await owner.exportLibrary(
            () => _incremental.conflict(cursor),
          ),
        },
      );
    }
    if (tail.length == 3 &&
        tail[0] == 'changes' &&
        tail[1] == 'conflicts' &&
        tail[2] == 'resolve' &&
        method == 'POST') {
      final input = _input(raw, {
        'cursor',
        'token',
        'useIncoming',
        'operationId',
      }, version: 2);
      if (input['cursor'] is! int ||
          (input['cursor'] as int) < 1 ||
          input['useIncoming'] is! bool)
        throw const FormatException();
      final receipt = await owner.exportLibrary(
        () => _incremental.resolveConflict(
          cursor: input['cursor'] as int,
          token: replicaDigest(input['token']),
          useIncoming: input['useIncoming'] as bool,
          operationId: replicaOperationId(input['operationId']),
        ),
      );
      return (
        200,
        {
          'wireVersion': 2,
          'identity': (await replication.identity()).toJson(),
          'receipt': receipt.toJson(),
        },
      );
    }
    if (tail.length == 1 && tail[0] == 'changes' && method == 'GET') {
      final status = await owner.exportLibrary(_incremental.status);
      return (
        200,
        {
          'wireVersion': 2,
          'identity': status.identity.toJson(),
          'cursor': status.cursor,
          'conflicts': status.conflicts,
          'empty': await replication.empty(),
        },
      );
    }
    if (tail.length == 2 &&
        tail[0] == 'changes' &&
        tail[1] == 'feed' &&
        method == 'POST') {
      final input = _input(raw, {'cursor', 'limit'}, version: 2);
      if (input['cursor'] is! int ||
          input['limit'] is! int ||
          (input['cursor'] as int) < 0 ||
          (input['cursor'] as int) > 9007199254740991 ||
          (input['limit'] as int) < 1 ||
          (input['limit'] as int) > 256)
        throw const FormatException();
      final entries = await owner.exportLibrary(
        () => _incremental.after(
          input['cursor'] as int,
          limit: input['limit'] as int,
        ),
      );
      return (
        200,
        {
          'wireVersion': 2,
          'identity': (await replication.identity()).toJson(),
          'changes': [
            for (final entry in entries)
              LibrarySyncChangeSummary(
                cursor: entry.cursor,
                libraryId: entry.batch.libraryId,
                sourceReplicaId: entry.batch.sourceReplicaId,
                operationId: entry.batch.operationId,
                sequence: entry.batch.sequence,
                digest: entry.batch.digest,
              ).toJson(),
          ],
        },
      );
    }
    if (tail.length == 4 &&
        tail[0] == 'changes' &&
        tail[1] == 'receipts' &&
        method == 'GET') {
      return (
        200,
        {
          'wireVersion': 2,
          'receipt': (await _incremental.receipt(
            libraryReplicaId(tail[2]),
            replicaOperationId(tail[3]),
          ))?.toJson(),
        },
      );
    }
    if (tail.length == 2 &&
        tail[0] == 'changes' &&
        tail[1] == 'receipts' &&
        method == 'POST') {
      final input = _input(raw, {'transfer'}, version: 2);
      final transfer = LibraryDeltaTransfer.fromJson(
        Map<String, dynamic>.from(input['transfer'] as Map),
      );
      if (transfer.archive.libraryId !=
          (await replication.identity()).libraryId)
        throw const StorageFailure('sync_base_changed');
      final result = await _incremental.receipt(
        transfer.sourceReplicaId,
        transfer.operationId,
        digest: transfer.archive.snapshotId,
        expectedSequence: transfer.sequence,
      );
      return (200, {'wireVersion': 2, 'receipt': result?.toJson()});
    }
    if (tail.length == 2 &&
        tail[0] == 'changes' &&
        tail[1] == 'initial-receipts' &&
        method == 'POST') {
      final input = _input(raw, {
        'operationId',
        'transfer',
        'baseline',
      }, version: 2);
      final result = await _incremental.initialReceiptManifest(
        operationId: replicaOperationId(input['operationId']),
        transfer: LibraryInitialTransfer.fromJson(
          Map<String, dynamic>.from(input['transfer'] as Map),
        ),
        baseline: LibrarySyncBaselineManifest.fromJson(
          Map<String, dynamic>.from(input['baseline'] as Map),
        ),
      );
      return (200, {'wireVersion': 2, 'receipt': result?.toJson()});
    }
    if (tail.length == 1 &&
        tail[0] == 'versioned-exports' &&
        method == 'POST') {
      final operation = replicaOperationId(
        _input(raw, {'operationId'}, version: 2)['operationId'],
      );
      final key = 'versioned:$operation';
      if (!_exports.containsKey(key)) _reserve();
      late _TransferFile result;
      try {
        result = await (_exports[key] ??= _versionedExport(operation, key));
      } on Object {
        _exports.remove(key);
        rethrow;
      }
      return (
        200,
        {
          'wireVersion': 2,
          'resourceId': result.id,
          'transfer': result.transfer.toJson(),
          'transferKey': result.key,
          'baseline': result.baseline!.manifest.toJson(),
        },
      );
    }
    if (tail.length == 1 && tail[0] == 'delta-exports' && method == 'POST') {
      final input = _input(raw, {'sourceReplicaId', 'operationId'}, version: 2);
      final source = libraryReplicaId(input['sourceReplicaId']),
          operation = replicaOperationId(input['operationId']);
      final key = 'delta:$source:$operation';
      if (!_exports.containsKey(key)) _reserve();
      late _TransferFile result;
      try {
        result = await (_exports[key] ??= _deltaExport(source, operation, key));
      } on Object {
        _exports.remove(key);
        rethrow;
      }
      return (
        200,
        {
          'wireVersion': 2,
          'resourceId': result.id,
          'transfer': result.delta!.toJson(),
          'transferKey': result.key,
        },
      );
    }
    if (tail.length == 1 && tail[0] == 'delta-imports' && method == 'POST') {
      final input = _input(raw, {'transfer'}, version: 2);
      final delta = LibraryDeltaTransfer.fromJson(
        Map<String, dynamic>.from(input['transfer'] as Map),
      );
      if (delta.archive.libraryId != (await replication.identity()).libraryId)
        throw const StorageFailure('sync_base_changed');
      final prior = await _incremental.receipt(
        delta.sourceReplicaId,
        delta.operationId,
        digest: delta.archive.snapshotId,
        expectedSequence: delta.sequence,
      );
      if (prior != null)
        return (200, {'wireVersion': 2, 'receipt': prior.toJson()});
      final key = 'delta:${delta.sourceReplicaId}:${delta.operationId}';
      final previous = _imports[key];
      if (previous != null) {
        if (jsonEncode(previous.delta?.toJson()) != jsonEncode(delta.toJson()))
          throw const StorageFailure('sync_operation_conflict');
        return (
          200,
          {
            'wireVersion': 2,
            'resourceId': previous.id,
            'offset': await previous.file.length(),
          },
        );
      }
      _reserve();
      final file = await _newFile();
      await file.create(exclusive: true);
      final transfer = _TransferFile(
        _id(),
        delta.operationId,
        file,
        delta.archive,
        _elapsed() + OwnerReplicationRoutes.lifetime,
        cacheKey: key,
        delta: delta,
      );
      _files[transfer.id] = transfer;
      _imports[key] = transfer;
      return (200, {'wireVersion': 2, 'resourceId': transfer.id, 'offset': 0});
    }
    if (tail.length == 1 &&
        tail[0] == 'versioned-imports' &&
        method == 'POST') {
      final input = _input(raw, {
        'operationId',
        'transfer',
        'baseline',
      }, version: 2);
      final operation = replicaOperationId(input['operationId']);
      final manifest = LibraryInitialTransfer.fromJson(
        Map<String, dynamic>.from(input['transfer'] as Map),
      );
      final baseline = LibrarySyncBaselineManifest.fromJson(
        Map<String, dynamic>.from(input['baseline'] as Map),
      );
      if (baseline.libraryId != manifest.libraryId ||
          baseline.snapshotId != manifest.snapshotId)
        throw const StorageFailure('sync_base_changed');
      final committed = await _incremental.initialReceiptManifest(
        operationId: operation,
        transfer: manifest,
        baseline: baseline,
      );
      if (committed != null)
        return (200, {'wireVersion': 2, 'receipt': committed.toJson()});
      // A known content receipt is not enough: the baseline digest must also
      // match. Its bounded bytes are uploaded before the final reconciliation.
      final key = 'versioned:$operation';
      final previous = _imports[key];
      if (previous != null) {
        if (jsonEncode(previous.transfer.toJson()) !=
                jsonEncode(manifest.toJson()) ||
            jsonEncode(previous.baseline?.manifest.toJson()) !=
                jsonEncode(baseline.toJson()))
          throw const StorageFailure('sync_operation_conflict');
        return (
          200,
          {
            'wireVersion': 2,
            'resourceId': previous.id,
            'offset': await previous.file.length(),
            'baselineOffset': previous.baseline!.uploaded,
          },
        );
      }
      if (!await replication.empty())
        throw const StorageFailure('recipient_not_empty');
      _reserve();
      final file = await _newFile();
      await file.create(exclusive: true);
      final transfer = _TransferFile(
        _id(),
        operation,
        file,
        manifest,
        _elapsed() + OwnerReplicationRoutes.lifetime,
        cacheKey: key,
        baseline: _BaselineTransfer.incoming(baseline),
      );
      _files[transfer.id] = transfer;
      _imports[key] = transfer;
      return (
        200,
        {
          'wireVersion': 2,
          'resourceId': transfer.id,
          'offset': 0,
          'baselineOffset': 0,
        },
      );
    }
    return (404, {'error': 'not_found'});
  }

  Future<(int, Map<String, Object?>)> _baselineChunk(
    String method,
    String action,
    _TransferFile transfer,
    Object? raw,
  ) async {
    final baseline = transfer.baseline;
    if (baseline == null || method != 'POST')
      return (404, {'error': 'not_found'});
    if (action == 'read' && transfer.key != null) {
      final input = _input(raw, {'offset', 'length'});
      final offset = input['offset'], length = input['length'];
      if (offset is! int ||
          length is! int ||
          offset < 0 ||
          length < 1 ||
          length > OwnerReplicationRoutes.chunkBytes ||
          offset + length > baseline.bytes.length)
        throw const FormatException();
      return (
        200,
        {
          'wireVersion': 1,
          'offset': offset,
          'bytesBase64': base64Encode(
            Uint8List.sublistView(baseline.bytes, offset, offset + length),
          ),
        },
      );
    }
    if (action == 'write' && transfer.key == null) {
      final input = _input(raw, {'offset', 'bytesBase64'});
      final offset = input['offset'];
      if (offset is! int ||
          offset < 0 ||
          input['bytesBase64'] is! String ||
          (input['bytesBase64'] as String).length >
              OwnerReplicationRoutes.chunkBytes * 4 ~/ 3 + 8)
        throw const FormatException();
      final bytes = base64Decode(input['bytesBase64'] as String);
      if (bytes.isEmpty ||
          bytes.length > OwnerReplicationRoutes.chunkBytes ||
          offset + bytes.length > baseline.bytes.length ||
          offset > baseline.uploaded ||
          offset < baseline.uploaded &&
              offset + bytes.length > baseline.uploaded)
        throw const StorageFailure('sync_offset_conflict');
      if (offset < baseline.uploaded) {
        for (var i = 0; i < bytes.length; i++) {
          if (baseline.bytes[offset + i] != bytes[i])
            throw const StorageFailure('sync_offset_conflict');
        }
      } else {
        baseline.bytes.setRange(offset, offset + bytes.length, bytes);
        baseline.uploaded += bytes.length;
      }
      return (200, {'wireVersion': 1, 'offset': baseline.uploaded});
    }
    return (404, {'error': 'not_found'});
  }

  Future<(int, Map<String, Object?>)> _commitIncremental(
    _TransferFile transfer,
    String key,
  ) async {
    if (transfer.delta case final LibraryDeltaTransfer delta) {
      final receipt = await owner.exportLibrary(
        () => _incremental.installDelta(
          path: transfer.file.path,
          transferKey: key,
          transfer: delta,
        ),
      );
      await _settleCommitted(transfer);
      return (200, {'wireVersion': 2, 'receipt': receipt.toJson()});
    }
    final baseline = transfer.baseline!.decode();
    final receipt = await owner.restoreLibraryOnce(
      previous: () => _incremental.initialReceipt(
        operationId: transfer.operationId,
        transfer: transfer.transfer,
        baseline: baseline,
        expectedSourceReplicaId: baseline.sourceReplicaId,
      ),
      restore: () => _incremental.installInitialWithBaseline(
        path: transfer.file.path,
        transferKey: key,
        operationId: transfer.operationId,
        transfer: transfer.transfer,
        baseline: baseline,
        expectedSourceReplicaId: baseline.sourceReplicaId,
      ),
    );
    await _settleCommitted(transfer);
    return (200, {'wireVersion': 2, 'receipt': receipt.toJson()});
  }

  Future<void> _settleCommitted(_TransferFile transfer) async {
    try {
      await _release(transfer);
    } on FileSystemException {
      // The receipt is already durable. Release its RAM/quota and retry only
      // the owned encrypted orphan on the next sweep; never replay admission.
      _files.remove(transfer.id);
      _imports.remove(transfer.cacheKey);
      _swept = false;
    }
  }
}
