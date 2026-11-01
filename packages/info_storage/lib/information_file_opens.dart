part of 'info_storage.dart';

String _fileOpenKey(String id) =>
    'file-open:${crypto.sha256.convert(utf8.encode(id))}';

enum OwnerFileDispatchOutcome { pending, opened, notOpened }

/// A trusted desktop bridge, never exposed over Agent transport. Null from a
/// native process cache is absence from that cache, NOT proof of no dispatch.
abstract interface class OwnerFileOpenDispatcher {
  Future<OwnerFileDispatchOutcome> open(
    String id,
    String digest,
    InformationDeliveryLease lease,
    int length,
    String sha256,
  );
  Future<OwnerFileDispatchOutcome?> status(String id, String digest);
}

enum InformationFileOpenPhase { reserved, prepared, opening, opened, notOpened }

final class InformationFileOpenStatus {
  InformationFileOpenStatus._(_FileOpen r, {this.invalidated = false})
    : operationId = r.id,
      commandDigest = r.digest,
      itemId = r.itemId,
      fieldKey = r.fieldKey,
      reference = r.reference,
      fileName = r.fileName,
      phase = r.phase,
      closed = r.closed,
      cleanupPending = r.cleanupPending;
  final String operationId, commandDigest, itemId, fieldKey, fileName;
  final InformationAttachmentRef reference;
  final InformationFileOpenPhase phase;
  final bool closed, cleanupPending, invalidated;
  bool get uncertain => phase == InformationFileOpenPhase.opening;
  bool get completed => phase == InformationFileOpenPhase.opened;
}

final class _FileOpen {
  const _FileOpen({
    required this.id,
    required this.digest,
    required this.itemId,
    required this.fieldKey,
    required this.reference,
    required this.fileName,
    required this.length,
    required this.sha256,
    required this.lease,
    this.phase = InformationFileOpenPhase.reserved,
    this.closed = false,
    this.cleanupPending = true,
  });
  final String id, digest, itemId, fieldKey, fileName, sha256;
  final InformationAttachmentRef reference;
  final InformationDeliveryLease lease;
  final int length;
  final InformationFileOpenPhase phase;
  final bool closed, cleanupPending;
  _FileOpen change({
    InformationFileOpenPhase? phase,
    bool? closed,
    bool? cleanupPending,
  }) => _FileOpen(
    id: id,
    digest: digest,
    itemId: itemId,
    fieldKey: fieldKey,
    reference: reference,
    fileName: fileName,
    length: length,
    sha256: sha256,
    lease: lease,
    phase: phase ?? this.phase,
    closed: closed ?? this.closed,
    cleanupPending: cleanupPending ?? this.cleanupPending,
  );
  Map<String, Object?> json() => {
    'format': 1,
    'action': 'informationFileOpen',
    'operationId': id,
    'commandDigest': digest,
    'itemId': itemId,
    'fieldKey': fieldKey,
    'reference': reference.toJson(),
    'fileName': fileName,
    'length': length,
    'sha256': sha256,
    'lease': lease.toPrivateJson(),
    'phase': phase.name,
    'closed': closed,
    'cleanupPending': cleanupPending,
  };
}

/// Owns ephemeral Owner copies independently of Agent grants/deliveries. Reuses
/// their descriptor-relative file driver, but never creates an Agent authority.
/// Call under the Owner snapshot barrier. Runtime maintenance/close run before
/// the repository is closed and must not overlap Owner work.
class InformationFileOpens {
  InformationFileOpens._(this._repository);
  final EncryptedInformationRepository _repository;
  final InformationDeliveryFiles _files = NativeInformationDeliveryFiles();
  final _fresh = <String>{}, _owned = <String>{}, _active = <String>{};
  void _check(String id) {
    if (_repository._closed) throw const StorageFailure('library_closed');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw const StorageFailure('invalid_file_operation');
    }
  }

  _FileOpen _decode(Map<String, dynamic> j, String id) {
    try {
      if (j.length != 14 ||
          j['format'] != 1 ||
          j['action'] != 'informationFileOpen' ||
          j['operationId'] != id ||
          !InformationFileOutputs._hash(j['commandDigest']) ||
          !InformationFileOutputs._hash(j['sha256']) ||
          j['length'] is! int ||
          (j['length'] as int) < 0 ||
          (j['length'] as int) > 10 * 1024 * 1024 ||
          j['closed'] is! bool ||
          j['cleanupPending'] is! bool) {
        throw const FormatException();
      }
      final item = j['itemId'] as String,
          key = j['fieldKey'] as String,
          name = j['fileName'] as String;
      if (item.isEmpty ||
          key.isEmpty ||
          name.isEmpty ||
          name.length > 4096 ||
          name.contains('\x00')) {
        throw const FormatException();
      }
      final phase = InformationFileOpenPhase.values.byName(
        j['phase'] as String,
      );
      if (!j['cleanupPending'] && !j['closed']) throw const FormatException();
      return _FileOpen(
        id: id,
        digest: j['commandDigest'] as String,
        itemId: item,
        fieldKey: key,
        reference: InformationAttachmentRef.fromJson(
          j['reference'] as Map<String, dynamic>,
        ),
        fileName: name,
        length: j['length'] as int,
        sha256: j['sha256'] as String,
        lease: InformationDeliveryLease.fromPrivateJson(
          j['lease'] as Map<String, dynamic>,
        ),
        phase: phase,
        closed: j['closed'] as bool,
        cleanupPending: j['cleanupPending'] as bool,
      );
    } on Object {
      throw const StorageFailure('invalid_file_open_receipt');
    }
  }

  Future<_FileOpen?> _read(String id, {bool invalidated = false}) async {
    _check(id);
    final rows = await _repository._db
        .customSelect(
          'SELECT payload,invalidated FROM backup_operations WHERE operation_id=?',
          variables: [Variable(_fileOpenKey(id))],
        )
        .get();
    if (rows.isEmpty) return null;
    if (!invalidated && rows.single.read<int>('invalidated') != 0) {
      throw const StorageFailure('library_changed');
    }
    try {
      return _decode(
        jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
        id,
      );
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('invalid_file_open_receipt');
    }
  }

  Future<void> _write(_FileOpen r) => _repository._db.customStatement(
    'UPDATE backup_operations SET payload=? WHERE operation_id=?',
    [jsonEncode(r.json()), _fileOpenKey(r.id)],
  );
  Future<T> _exclusive<T>(String id, Future<T> Function() f) async {
    _check(id);
    if (!_active.add(id)) throw const StorageFailure('file_operation_busy');
    try {
      return await f();
    } finally {
      _active.remove(id);
    }
  }

  Future<InformationFileOpenStatus?> status(String id) async {
    final r = await _read(id);
    return r == null ? null : InformationFileOpenStatus._(r);
  }

  Future<List<InformationFileOpenStatus>> copies({
    bool includeInvalidated = false,
  }) async {
    final rows = await _scan(includeInvalidated: includeInvalidated);
    return List.unmodifiable(
      rows
          .where((r) => r.$1.cleanupPending)
          .map((r) => InformationFileOpenStatus._(r.$1, invalidated: r.$2)),
    );
  }

  Future<List<(_FileOpen, bool)>> _scan({
    bool includeInvalidated = true,
  }) async {
    if (_repository._closed) throw const StorageFailure('library_closed');
    final rows = await _repository._db
        .customSelect(
          "SELECT operation_id,payload,invalidated FROM backup_operations WHERE operation_id LIKE 'file-open:%'${includeInvalidated ? '' : ' AND invalidated=0'}",
        )
        .get();
    final result = <(_FileOpen, bool)>[];
    for (final row in rows) {
      try {
        final j =
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
        final id = j['operationId'] as String;
        _check(id);
        if (row.read<String>('operation_id') != _fileOpenKey(id)) {
          throw const FormatException();
        }
        result.add((_decode(j, id), row.read<int>('invalidated') != 0));
      } on StorageFailure {
        rethrow;
      } on Object {
        throw const StorageFailure('invalid_file_open_receipt');
      }
    }
    return result;
  }

  /// Reserves only an empty generated file, persists its identity first, and
  /// writes the already verified bytes. Any failed cleanup remains registered.
  Future<void> prepare({
    required String operationId,
    required String commandDigest,
    required String itemId,
    required String fieldKey,
    required InformationAttachmentRef reference,
    required String fileName,
    required String safeName,
    required Uint8List bytes,
    required String sha256,
  }) => _exclusive(operationId, () async {
    if (!InformationFileOutputs._hash(commandDigest) ||
        bytes.length > 10 * 1024 * 1024 ||
        crypto.sha256.convert(bytes).toString() != sha256) {
      throw const StorageFailure('attachment_integrity_failed');
    }
    if (await _read(operationId, invalidated: true) != null) {
      throw const StorageFailure('operation_conflict');
    }
    final lease = await _files.reserve(safeName);
    var registered = false;
    try {
      final r = _FileOpen(
        id: operationId,
        digest: commandDigest,
        itemId: itemId,
        fieldKey: fieldKey,
        reference: reference,
        fileName: fileName,
        length: bytes.length,
        sha256: sha256,
        lease: lease,
      );
      _decode(Map<String, dynamic>.from(r.json()), operationId);
      await _repository._db.transaction(() async {
        for (final table in [
          'information_record_operations',
          'information_lifecycle_operations',
        ]) {
          if ((await _repository._db
                  .customSelect(
                    'SELECT 1 FROM $table WHERE operation_id=?',
                    variables: [Variable(operationId)],
                  )
                  .get())
              .isNotEmpty) {
            throw const StorageFailure('operation_conflict');
          }
        }
        if (await _repository.fileOutputs.status(operationId) != null) {
          throw const StorageFailure('operation_conflict');
        }
        final held = (await _scan()).where((r) => r.$1.cleanupPending).toList();
        if (held.length >= 32 ||
            held.fold<int>(0, (n, r) => n + r.$1.length) + bytes.length >
                100 * 1024 * 1024) {
          throw const StorageFailure('file_open_capacity');
        }
        await _repository._db.customStatement(
          'INSERT INTO backup_operations(operation_id,payload) VALUES(?,?)',
          [_fileOpenKey(operationId), jsonEncode(r.json())],
        );
      });
      registered = true;
      _owned.add(operationId);
      await _files.write(lease, bytes);
      await _files.verify(lease, bytes.length, sha256);
      await _write(r.change(phase: InformationFileOpenPhase.prepared));
      _fresh.add(operationId);
    } catch (_) {
      if (registered) {
        try {
          await _close(operationId);
        } catch (_) {
          /* Durable cleanup queue. */
        }
      } else {
        try {
          await _files.cleanup(lease);
        } catch (_) {
          /* Only an unregistered empty file exists. */
        }
      }
      rethrow;
    }
  });
  Future<InformationFileOpenStatus> _recordOutcome(
    _FileOpen r,
    OwnerFileDispatchOutcome outcome,
  ) async {
    if (outcome == OwnerFileDispatchOutcome.pending) {
      throw const StorageFailure('file_outcome_unknown');
    }
    final next = r.change(
      phase: outcome == OwnerFileDispatchOutcome.opened
          ? InformationFileOpenPhase.opened
          : InformationFileOpenPhase.notOpened,
    );
    await _write(next);
    return InformationFileOpenStatus._(next);
  }

  Future<InformationFileOpenStatus?> _reconcile(
    String id,
    OwnerFileOpenDispatcher dispatcher,
  ) async {
    final r = await _read(id);
    if (r == null) return null;
    if (r.phase == InformationFileOpenPhase.opening) {
      final outcome = await dispatcher.status(id, r.digest);
      if (outcome == null) throw const StorageFailure('file_outcome_unknown');
      return _recordOutcome(r, outcome);
    }
    if ({
      InformationFileOpenPhase.reserved,
      InformationFileOpenPhase.prepared,
    }.contains(r.phase)) {
      _fresh.remove(id);
      final next = r.change(phase: InformationFileOpenPhase.notOpened);
      await _write(next);
      await _close(id);
      return InformationFileOpenStatus._((await _read(id))!);
    }
    return InformationFileOpenStatus._(r);
  }

  Future<InformationFileOpenStatus?> reconcile(
    String id,
    OwnerFileOpenDispatcher dispatcher,
  ) => _exclusive(id, () => _reconcile(id, dispatcher));
  Future<InformationFileOpenStatus> open(
    String id,
    OwnerFileOpenDispatcher dispatcher,
  ) => _exclusive(id, () async {
    if (!_fresh.remove(id)) {
      final s = await _reconcile(id, dispatcher);
      if (s == null) throw const StorageFailure('file_operation_missing');
      return s;
    }
    final r = await _read(id);
    if (r == null || r.closed || r.phase != InformationFileOpenPhase.prepared) {
      throw const StorageFailure('operation_conflict');
    }
    await _files.verify(r.lease, r.length, r.sha256);
    final opening = r.change(phase: InformationFileOpenPhase.opening);
    await _write(opening);
    final outcome = await dispatcher.open(
      id,
      r.digest,
      r.lease,
      r.length,
      r.sha256,
    );
    final result = await _recordOutcome(opening, outcome);
    if (!result.completed) await _close(id);
    return InformationFileOpenStatus._((await _read(id))!);
  });
  Future<void> _close(String id) async {
    var r = await _read(id, invalidated: true);
    if (r == null || !r.cleanupPending) return;
    _fresh.remove(id);
    _owned.remove(id);
    r = r.change(closed: true);
    await _write(r); // Revokes future opens before unlink.
    await _files.cleanup(r.lease);
    await _write(r.change(cleanupPending: false));
  }

  /// Explicit Owner end-use or runtime shutdown. Unknown dispatch remains
  /// unknown in history; cleaning its copy must never invent a launch result.
  Future<void> close(String id) => _exclusive(id, () => _close(id));
  Future<int> maintain({
    bool closeAll = false,
    bool closePrevious = false,
  }) async {
    var failed = 0;
    for (final (r, invalidated) in await _scan()) {
      if (!r.cleanupPending ||
          !(closeAll ||
              invalidated ||
              r.closed ||
              closePrevious && !_owned.contains(r.id))) {
        continue;
      }
      try {
        await close(r.id);
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }
}
