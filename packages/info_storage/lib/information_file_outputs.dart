part of 'info_storage.dart';

/// Local publication journals share the existing encrypted private journal,
/// using keys that cannot be accepted by the backup operation API. They never
/// enter portable backups and restore invalidates them with the other journals.
String _fileOutputKey(String id) =>
    'file-output:${crypto.sha256.convert(utf8.encode(id))}';

enum InformationFileOutputPhase {
  reserved,
  prepared,
  publishing,
  succeeded,
  notPublished,
}

/// Public facts only. Paths and native security-scoped capabilities stay in the
/// encrypted journal and the trusted desktop adapter, never in a page resource.
final class InformationFileOutputStatus {
  InformationFileOutputStatus._(_InformationFileOutput r)
    : operationId = r.id,
      commandDigest = r.digest,
      itemId = r.itemId,
      fieldKey = r.fieldKey,
      reference = r.reference,
      phase = r.phase,
      fileName = File(r.destination).uri.pathSegments.last,
      cleanupPending = r.cleanupPending;
  final String operationId, commandDigest, itemId, fieldKey, fileName;
  final InformationAttachmentRef reference;
  final InformationFileOutputPhase phase;
  final bool cleanupPending;
  bool get completed => phase == InformationFileOutputPhase.succeeded;
  bool get uncertain => phase == InformationFileOutputPhase.publishing;
}

final class _InformationFileOutput {
  const _InformationFileOutput({
    required this.id,
    required this.digest,
    required this.itemId,
    required this.fieldKey,
    required this.reference,
    required this.root,
    required this.destination,
    required this.length,
    required this.contentDigest,
    required this.stagingBookmark,
    this.outputBookmark = '',
    this.publication,
    this.phase = InformationFileOutputPhase.reserved,
    this.cleanupPending = true,
  });
  final String id, digest, itemId, fieldKey, destination, contentDigest;
  final String stagingBookmark, outputBookmark;
  final InformationAttachmentRef reference;
  final MacBackupStagingDirectory root;
  final int length;
  final MacBackupPublication? publication;
  final InformationFileOutputPhase phase;
  final bool cleanupPending;
  _InformationFileOutput change({
    InformationFileOutputPhase? phase,
    MacBackupPublication? publication,
    String? outputBookmark,
    bool? cleanupPending,
  }) => _InformationFileOutput(
    id: id,
    digest: digest,
    itemId: itemId,
    fieldKey: fieldKey,
    reference: reference,
    root: root,
    destination: destination,
    length: length,
    contentDigest: contentDigest,
    stagingBookmark: stagingBookmark,
    outputBookmark: outputBookmark ?? this.outputBookmark,
    publication: publication ?? this.publication,
    phase: phase ?? this.phase,
    cleanupPending: cleanupPending ?? this.cleanupPending,
  );
  Map<String, Object?> toPrivateJson() => {
    'format': 1,
    'action': 'informationFileOutput',
    'operationId': id,
    'commandDigest': digest,
    'itemId': itemId,
    'fieldKey': fieldKey,
    'attachmentId': reference.attachmentId,
    'attachmentVersion': reference.attachmentVersion,
    'root': root.toPrivateJson(),
    'destination': destination,
    'length': length,
    'contentDigest': contentDigest,
    'stagingBookmark': cleanupPending ? stagingBookmark : '',
    'outputBookmark': cleanupPending ? outputBookmark : '',
    'publication': publication?.toPrivateJson(),
    'phase': phase.name,
    'cleanupPending': cleanupPending,
  };
}

/// Owner-only output coordinator. Call under Owner.exportLibrary; callbacks must
/// not re-enter Owner writes. A fresh in-process preparation may publish once.
/// Reopen/reconciliation observes only; no path can republish an old intent.
class InformationFileOutputs {
  InformationFileOutputs._(this._repository);
  final _FileOperationContext _repository;
  final _fresh = <String>{}, _reserved = <String>{}, _active = <String>{};
  void _check(String id) {
    if (_repository._closed) throw const StorageFailure('library_closed');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw const StorageFailure('invalid_file_operation');
    }
  }

  static bool _hash(Object? s) =>
      s is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(s);
  _InformationFileOutput _decode(Map<String, dynamic> j, String id) {
    try {
      if (j.length != 17 ||
          j['format'] != 1 ||
          j['action'] != 'informationFileOutput' ||
          j['operationId'] != id ||
          !_hash(j['commandDigest']) ||
          !_hash(j['contentDigest']) ||
          j['itemId'] is! String ||
          (j['itemId'] as String).isEmpty ||
          j['fieldKey'] is! String ||
          (j['fieldKey'] as String).isEmpty ||
          j['attachmentId'] is! String ||
          (j['attachmentId'] as String).isEmpty ||
          j['attachmentVersion'] is! int ||
          (j['attachmentVersion'] as int) < 1 ||
          j['length'] is! int ||
          (j['length'] as int) < 0 ||
          (j['length'] as int) > 10 * 1024 * 1024 ||
          j['cleanupPending'] is! bool ||
          j['stagingBookmark'] is! String ||
          j['outputBookmark'] is! String) {
        throw const FormatException();
      }
      final root = MacBackupStagingDirectory.fromPrivateJson(
        j['root'] as Map<String, dynamic>,
      );
      final dest = j['destination'] as String;
      if (!dest.startsWith('/') ||
          dest.contains('\x00') ||
          dest.split('/').any((s) => s == '.' || s == '..') ||
          dest.startsWith('${root.path}/') ||
          dest.endsWith('/')) {
        throw const FormatException();
      }
      final p = j['publication'] == null
          ? null
          : MacBackupPublication.fromPrivateJson(
              j['publication'] as Map<String, dynamic>,
            );
      final phase = InformationFileOutputPhase.values.byName(
        j['phase'] as String,
      );
      if (p != null &&
          (p.source != '${root.path}/prepared' ||
              p.destination != dest ||
              p.sourceDirectoryIdentity != root.identity ||
              p.bytes != j['length'] ||
              p.digest != j['contentDigest'])) {
        throw const FormatException();
      }
      if ((phase == InformationFileOutputPhase.reserved && p != null) ||
          ({
                InformationFileOutputPhase.prepared,
                InformationFileOutputPhase.publishing,
                InformationFileOutputPhase.succeeded,
              }.contains(phase) &&
              p == null) ||
          (!j['cleanupPending'] &&
              !{
                InformationFileOutputPhase.succeeded,
                InformationFileOutputPhase.notPublished,
              }.contains(phase))) {
        throw const FormatException();
      }
      return _InformationFileOutput(
        id: id,
        digest: j['commandDigest'] as String,
        itemId: j['itemId'] as String,
        fieldKey: j['fieldKey'] as String,
        reference: InformationAttachmentRef(
          j['attachmentId'] as String,
          j['attachmentVersion'] as int,
        ),
        root: root,
        destination: dest,
        length: j['length'] as int,
        contentDigest: j['contentDigest'] as String,
        stagingBookmark: j['stagingBookmark'] as String,
        outputBookmark: j['outputBookmark'] as String,
        publication: p,
        phase: phase,
        cleanupPending: j['cleanupPending'] as bool,
      );
    } on Object {
      throw const StorageFailure('invalid_file_output_receipt');
    }
  }

  Future<_InformationFileOutput?> _read(
    String id, {
    bool invalidated = false,
  }) async {
    _check(id);
    final rows = await _repository._db
        .customSelect(
          'SELECT payload,invalidated FROM backup_operations WHERE operation_id=?',
          variables: [Variable(_fileOutputKey(id))],
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
      throw const StorageFailure('invalid_file_output_receipt');
    }
  }

  Future<void> _write(_InformationFileOutput r) =>
      _repository._db.customStatement(
        'UPDATE backup_operations SET payload=? WHERE operation_id=?',
        [jsonEncode(r.toPrivateJson()), _fileOutputKey(r.id)],
      );
  Future<InformationFileOutputStatus?> status(String id) async {
    final r = await _read(id);
    return r == null ? null : InformationFileOutputStatus._(r);
  }

  Future<List<InformationFileOutputStatus>> pending({
    bool includeInvalidated = false,
  }) async {
    if (_repository._closed) throw const StorageFailure('library_closed');
    final rows = await _repository._db
        .customSelect(
          "SELECT operation_id,payload FROM backup_operations WHERE operation_id LIKE 'file-output:%'${includeInvalidated ? '' : ' AND invalidated=0'}",
        )
        .get();
    final result = <InformationFileOutputStatus>[];
    for (final row in rows) {
      try {
        final j =
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
        final id = j['operationId'] as String;
        _check(id);
        if (row.read<String>('operation_id') != _fileOutputKey(id)) {
          throw const FormatException();
        }
        final r = _decode(j, id);
        if (r.cleanupPending) result.add(InformationFileOutputStatus._(r));
      } on StorageFailure {
        rethrow;
      } on Object {
        throw const StorageFailure('invalid_file_output_receipt');
      }
    }
    return List.unmodifiable(result);
  }

  /// Reserve an EMPTY private stage before any plaintext material is created.
  Future<void> reserve({
    required String operationId,
    required String commandDigest,
    required String itemId,
    required String fieldKey,
    required InformationAttachmentRef reference,
    required MacBackupStagingDirectory root,
    required String destination,
    required int length,
    required String contentDigest,
    String stagingBookmark = '',
  }) async {
    _check(operationId);
    final r = _InformationFileOutput(
      id: operationId,
      digest: commandDigest,
      itemId: itemId,
      fieldKey: fieldKey,
      reference: reference,
      root: root,
      destination: destination,
      length: length,
      contentDigest: contentDigest,
      stagingBookmark: stagingBookmark,
    );
    _decode(Map<String, dynamic>.from(r.toPrivateJson()), operationId);
    await _repository._db.transaction(() async {
      if (await _repository.fileOpens.status(operationId) != null ||
          await _read(operationId, invalidated: true) != null) {
        throw const StorageFailure('operation_conflict');
      }
      await _repository.checkOtherOperation(operationId);
      if (!MacBackupPublicationFiles.stagingExists(root) ||
          Directory(root.path).listSync(followLinks: false).isNotEmpty) {
        throw const StorageFailure('file_staging_changed');
      }
      await _repository._db.customStatement(
        'INSERT INTO backup_operations(operation_id,payload) VALUES(?,?)',
        [_fileOutputKey(operationId), jsonEncode(r.toPrivateJson())],
      );
    });
    _reserved.add(operationId);
  }

  Future<T> _exclusive<T>(String id, Future<T> Function() f) async {
    _check(id);
    if (!_active.add(id)) throw const StorageFailure('file_operation_busy');
    try {
      return await f();
    } finally {
      _active.remove(id);
    }
  }

  Future<void> prepare(String id, List<int> verifiedBytes) => _exclusive(
    id,
    () async {
      final r = await _read(id);
      if (!_reserved.remove(id) ||
          r == null ||
          r.phase != InformationFileOutputPhase.reserved) {
        throw const StorageFailure('operation_conflict');
      }
      if (verifiedBytes.length != r.length ||
          crypto.sha256.convert(verifiedBytes).toString() != r.contentDigest) {
        throw const StorageFailure('attachment_integrity_failed');
      }
      if (!MacBackupPublicationFiles.stagingExists(r.root)) {
        throw const StorageFailure('file_staging_changed');
      }
      MacBackupPublicationFiles.writePrivateFile(
        '${r.root.path}/prepared',
        verifiedBytes,
      );
      final p = MacBackupPublicationFiles.prepare(
        '${r.root.path}/prepared',
        r.destination,
      );
      if (p.bytes != r.length ||
          p.digest != r.contentDigest ||
          p.sourceDirectoryIdentity != r.root.identity) {
        throw const StorageFailure('attachment_integrity_failed');
      }
      await _repository._db.transaction(() async {
        final current = await _read(id);
        if (current == null ||
            current.phase != InformationFileOutputPhase.reserved) {
          throw const StorageFailure('operation_conflict');
        }
        await _write(
          current.change(
            phase: InformationFileOutputPhase.prepared,
            publication: p,
          ),
        );
      });
      _fresh.add(id);
    },
  );
  Future<InformationFileOutputStatus> _finish(String id) =>
      _repository._db.transaction(() async {
        final r = await _read(id);
        if (r == null) throw const StorageFailure('file_operation_missing');
        if (r.phase == InformationFileOutputPhase.succeeded) {
          return InformationFileOutputStatus._(r);
        }
        if (r.phase != InformationFileOutputPhase.publishing ||
            MacBackupPublicationFiles.confirmPublished(r.publication!) !=
                BackupPublicationObservation.matching) {
          throw const StorageFailure('file_outcome_unknown');
        }
        final done = r.change(phase: InformationFileOutputPhase.succeeded);
        await _write(done);
        return InformationFileOutputStatus._(done);
      });
  Future<InformationFileOutputStatus?> _reconcile(String id) async {
    final r = await _read(id);
    if (r == null) return null;
    if ({
      InformationFileOutputPhase.reserved,
      InformationFileOutputPhase.prepared,
    }.contains(r.phase)) {
      _fresh.remove(id);
      _reserved.remove(id);
      final failed = r.change(phase: InformationFileOutputPhase.notPublished);
      await _write(failed);
      return InformationFileOutputStatus._(failed);
    }
    if (r.phase == InformationFileOutputPhase.publishing) return _finish(id);
    return InformationFileOutputStatus._(r);
  }

  Future<InformationFileOutputStatus?> reconcile(String id) =>
      _exclusive(id, () => _reconcile(id));
  Future<InformationFileOutputStatus> publish(
    String id, {
    Future<void> Function()? afterPublication,
  }) => _exclusive(id, () async {
    if (!_fresh.remove(id)) {
      final result = await _reconcile(id);
      if (result == null) throw const StorageFailure('file_operation_missing');
      return result;
    }
    final r = await _repository._db.transaction(() async {
      final r = await _read(id);
      if (r == null || r.phase != InformationFileOutputPhase.prepared) {
        throw const StorageFailure('file_outcome_unknown');
      }
      await _write(r.change(phase: InformationFileOutputPhase.publishing));
      return r;
    });
    try {
      MacBackupPublicationFiles.publish(r.publication!);
    } on BackupPublicationFailure catch (e) {
      if (e.code == 'flush_failed') {
        throw const StorageFailure('file_outcome_unknown');
      }
      await _write(r.change(phase: InformationFileOutputPhase.notPublished));
      return InformationFileOutputStatus._(
        r.change(phase: InformationFileOutputPhase.notPublished),
      );
    }
    // Capture the selected output capability only after that file exists.
    await afterPublication?.call();
    return _finish(id);
  });

  /// Trusted native-adapter arguments, never page data. No implicit prompting.
  Future<Map<String, String>> access(String id) async {
    final r = await _read(id, invalidated: true);
    if (r == null || !r.cleanupPending) {
      throw const StorageFailure('file_operation_missing');
    }
    return {
      'path': r.root.path,
      'parentIdentity': r.root.parentIdentity,
      'destination': r.destination,
      'stagingBookmark': r.stagingBookmark,
      'outputBookmark': r.outputBookmark,
    };
  }

  Future<Map<String, Object?>> stagingDirectory(String id) async {
    final r = await _read(id, invalidated: true);
    if (r == null) throw const StorageFailure('file_operation_missing');
    return r.root.toPrivateJson();
  }

  Future<void> recordOutputBookmark(String id, String bookmark) async {
    if (bookmark.isEmpty || bookmark.length > 1024 * 1024) {
      throw const StorageFailure('file_access_required');
    }
    final r = await _read(id);
    if (r == null ||
        !r.cleanupPending ||
        r.phase != InformationFileOutputPhase.publishing) {
      throw const StorageFailure('operation_conflict');
    }
    await _write(r.change(outputBookmark: bookmark));
  }

  /// Success is committed before cleanup. Unknown publications preserve their
  /// inode anchor. Cleanup never removes the selected output or arbitrary files.
  Future<void> cleanup(String id, {Future<void> Function()? releaseStaging}) =>
      _exclusive(id, () async {
        var r = await _read(id, invalidated: true);
        if (r == null || !r.cleanupPending) return;
        if ({
          InformationFileOutputPhase.reserved,
          InformationFileOutputPhase.prepared,
        }.contains(r.phase)) {
          _reserved.remove(id);
          _fresh.remove(id);
          r = r.change(phase: InformationFileOutputPhase.notPublished);
          await _write(r);
        }
        if (!{
          InformationFileOutputPhase.succeeded,
          InformationFileOutputPhase.notPublished,
        }.contains(r.phase)) {
          throw const StorageFailure('file_outcome_unknown');
        }
        MacBackupPublicationFiles.cleanupStaging(
          r.root,
          generatedFiles: {'prepared', 'prepared.publish'},
        );
        await releaseStaging?.call();
        await _write(r.change(cleanupPending: false));
      });
}
