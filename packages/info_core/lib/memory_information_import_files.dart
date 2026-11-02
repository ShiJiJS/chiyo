part of 'information.dart';

extension _MemoryImportOriginals on MemoryInformationRepository {
  Future<
    Map<InformationAttachmentRef, (InformationAttachmentVersion, Uint8List?)>
  >
  _prepareImportedOriginals(
    List<InformationImportFilePromotion> promotions,
    List<ImportProposal> proposals,
    List<InformationUpdateAdmission> updates,
  ) async {
    final result =
        <
          InformationAttachmentRef,
          (InformationAttachmentVersion, Uint8List?)
        >{};
    for (final p in promotions) {
      final row = _importUploadData[p.upload.id];
      final bytes = row?.$2;
      final latest = {..._informationFiles.keys, ...result.keys}
          .where((r) => r.attachmentId == p.version.reference.attachmentId)
          .fold(0, (n, r) => n > r.attachmentVersion ? n : r.attachmentVersion);
      if (row == null ||
          row.$1.consumed ||
          bytes == null ||
          jsonEncode(row.$1.toPrivateJson()) !=
              jsonEncode(p.upload.toPrivateJson()) ||
          p.version.reference.attachmentVersion != latest + 1 ||
          !p.version.available ||
          p.version.originalName != row.$1.originalName ||
          p.version.mediaType != row.$1.mediaType ||
          p.version.byteLength != bytes.length ||
          p.version.sha256 != crypto.sha256.convert(bytes).toString()) {
        throw const AccessFailure('attachment_integrity_failed');
      }
      result[p.version.reference] = (p.version, Uint8List.fromList(bytes));
    }
    final retained = _informationFiles.values.fold(
      0,
      (n, v) => n + (v.$2?.length ?? 0),
    );
    final added = result.values.fold(0, (n, v) => n + (v.$2?.length ?? 0));
    final future = {..._proposals, for (final p in proposals) p.id: p};
    final futureUpdates = {
      ..._updates,
      for (final u in updates) u.proposal.id: u.proposal,
    };
    final used = {
      for (final p in future.values)
        for (final item in p.items)
          for (final a in item.attachments)
            for (final v in a.versions) v.uploadId,
      for (final p in futureUpdates.values)
        for (final a in p.input.attachments)
          for (final v in a.versions) v.uploadId,
    };
    final sources = _importUploadData.entries
        .where(
          (e) =>
              e.value.$2 != null &&
              (!_claimedImportUploads.contains(e.key) || used.contains(e.key)),
        )
        .fold(0, (n, e) => n + e.value.$1.byteLength);
    final owner = await _fileStages.informationFileStagingUsage();
    if (retained + added + sources + owner.bytes >
        informationFileStagingByteLimit) {
      throw const AccessFailure('attachment_capacity_exceeded');
    }
    return result;
  }

  void _claimImportOriginals(ImportProposal proposal) {
    _claimFileChanges(
      proposal.sessionBinding,
      proposal.items.expand((i) => i.attachments),
    );
  }

  void _claimFileChanges(
    String binding,
    Iterable<ImportAttachmentInput> attachments,
  ) {
    final ids = <String>[];
    for (final a in attachments) {
      for (final v in a.versions) {
        final row = _importUploadData[v.uploadId];
        if (row == null ||
            row.$2 == null ||
            row.$1.consumed ||
            row.$1.sessionBinding != binding ||
            v.upload == null ||
            jsonEncode(row.$1.toPrivateJson()) !=
                jsonEncode(v.upload!.toPrivateJson())) {
          throw const AccessFailure('upload_unavailable');
        }
        ids.add(v.uploadId);
      }
    }
    _claimedImportUploads.addAll(ids);
  }

  void _reconcileImportOriginals() {
    final retained = {
      for (final p in _proposals.values)
        for (final item in p.items)
          for (final a in item.attachments)
            for (final v in a.versions) v.uploadId,
      for (final p in _updates.values)
        for (final a in p.input.attachments)
          for (final v in a.versions) v.uploadId,
    };
    for (final id in _claimedImportUploads.difference(retained)) {
      final row = _importUploadData[id];
      if (row != null) _importUploadData[id] = (row.$1.asConsumed(), null);
    }
  }

  Future<void> _stageImportOriginal(
    InformationImportUpload upload,
    Uint8List bytes,
  ) async {
    if (upload.consumed ||
        upload.byteLength != bytes.length ||
        crypto.sha256.convert(bytes).toString() != upload.sha256) {
      throw const AccessFailure('attachment_integrity_failed');
    }
    final previous = await importFileOperation(
      upload.sessionBinding,
      upload.operationId,
    );
    if (previous != null || _importUploadData.containsKey(upload.id)) {
      throw const AccessFailure('operation_conflict');
    }
    final own = await _fileStages.informationFileStagingUsage();
    final pending = _importUploadData.values.where((v) => v.$2 != null);
    final retained = _informationFiles.values.fold(
      0,
      (n, v) => n + (v.$2?.length ?? 0),
    );
    if (own.files + pending.length >= informationFileStageLimit ||
        retained +
                own.bytes +
                pending.fold(0, (n, v) => n + v.$1.byteLength) +
                bytes.length >
            informationFileStagingByteLimit) {
      throw const AccessFailure('attachment_capacity_exceeded');
    }
    _importUploadData[upload.id] = (upload, Uint8List.fromList(bytes));
  }

  Future<T> _withImportOriginal<T>(
    String id,
    Future<T> Function(InformationImportUpload, Stream<Uint8List>) action,
  ) async {
    final row = _importUploadData[id];
    if (row == null || row.$2 == null || row.$1.consumed) {
      throw const AccessFailure('upload_unavailable');
    }
    Stream<Uint8List> chunks() async* {
      for (var at = 0; at < row.$2!.length; at += 1024 * 1024) {
        final end = at + 1024 * 1024 < row.$2!.length
            ? at + 1024 * 1024
            : row.$2!.length;
        yield Uint8List.fromList(row.$2!.sublist(at, end));
      }
    }

    return action(row.$1, chunks());
  }
}
