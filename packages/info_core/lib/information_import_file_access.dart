part of 'info_core.dart';

InformationImportFileRepository _importFiles(
  InformationRepository repository,
) => switch (repository) {
  final InformationImportFileRepository files => files,
  _ => throw const AccessFailure('unsupported_capability'),
};

Set<String> _pendingImportUploads(Iterable<ImportProposal> proposals) => {
  for (final p in proposals.where(
    (p) => p.state == ImportProposalState.pending,
  ))
    for (final i in p.items)
      for (final a in i.attachments)
        for (final v in a.versions) v.uploadId,
};

extension AgentInformationImportFiles on AgentAccess {
  bool get informationImportFilesAvailable =>
      informationTemplatesAvailable &&
      _service._repository is InformationImportFileRepository;
  Future<InformationImportUpload> uploadImportFile(
    String session, {
    required String operationId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  }) {
    if (bytes.length > informationFileByteLimit) {
      throw const AccessFailure('file_too_large');
    }
    final copy = Uint8List.fromList(bytes);
    return _service.owner._serialize(() async {
      _service._requireSession(session);
      if (!RegExp(
        r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
      ).hasMatch(operationId)) {
        throw const AccessFailure('invalid_operation_id');
      }
      final repository = _importFiles(_service._repository);
      final binding = _service._sessionBindings[session]!;
      final digest = sha256.convert(copy).toString();
      final prior = await repository.importFileOperation(binding, operationId);
      if (prior != null) {
        if (prior.originalName != originalName ||
            prior.mediaType != mediaType ||
            prior.byteLength != copy.length ||
            prior.sha256 != digest) {
          throw const AccessFailure('operation_conflict');
        }
        return prior;
      }
      InformationImportUpload upload;
      try {
        upload = InformationImportUpload(
          id: _service._secret(),
          sessionBinding: binding,
          operationId: operationId,
          originalName: originalName,
          mediaType: mediaType,
          byteLength: copy.length,
          sha256: digest,
          createdAt: _service._clock().toUtc(),
        );
      } on FormatException {
        throw const AccessFailure('invalid_information_file');
      }
      await repository.pruneImportFiles(
        _service._clock().toUtc().subtract(const Duration(minutes: 30)),
        _pendingImportUploads(_service._repository.importProposals),
      );
      _service._requireSession(session);
      await repository.stageImportFile(upload, copy);
      return upload;
    });
  }

  Future<Map<String, Object?>> importFileStatus(
    String session,
    String operationId,
  ) => _service.owner._serialize(() async {
    _service._requireSession(session);
    final upload = await _importFiles(
      _service._repository,
    ).importFileOperation(_service._sessionBindings[session]!, operationId);
    return upload == null
        ? {'status': 'not_found'}
        : {'status': 'ok', ...upload.metadata};
  });
}

extension OwnerImportFiles on OwnerAccess {
  Future<OwnerImportOriginal> readImportOriginal(
    String proposalId,
    String itemKey,
    String attachmentKey,
    int version, {
    int? proposalVersion,
  }) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final p = importProposals
        .where(
          (p) => p.id == proposalId && p.state == ImportProposalState.pending,
        )
        .firstOrNull;
    final item = p?.items.where((i) => i.key == itemKey).firstOrNull;
    if (proposalVersion != null && p?.version != proposalVersion) {
      throw const AccessFailure('proposal_changed');
    }
    final attachment = item?.attachments
        .where((a) => a.key == attachmentKey)
        .firstOrNull;
    if (attachment == null ||
        version < 1 ||
        version > attachment.versions.length) {
      throw const AccessFailure('proposal_changed');
    }
    final expected = attachment.versions[version - 1].upload;
    final scope = captureLibraryScope();
    return _importFiles(_service._repository).withImportFile(
      attachment.versions[version - 1].uploadId,
      (upload, chunks) async {
        if (expected == null ||
            upload.sessionBinding != p!.sessionBinding ||
            jsonEncode(upload.toPrivateJson()) !=
                jsonEncode(expected.toPrivateJson())) {
          throw const AccessFailure('upload_unavailable');
        }
        final builder = BytesBuilder(copy: true);
        final digest = _InformationFileDigest();
        // One bounded original is available only to the trusted owner preview.
        final receiver = sha256.startChunkedConversion(digest);
        try {
          await for (final chunk in chunks) {
            if (chunk.length > 1024 * 1024 ||
                builder.length + chunk.length > upload.byteLength) {
              throw const AccessFailure('attachment_integrity_failed');
            }
            builder.add(chunk);
            receiver.add(chunk);
          }
        } finally {
          receiver.close();
        }
        if (!scope.isCurrent ||
            builder.length != upload.byteLength ||
            digest.value.toString() != upload.sha256) {
          throw const AccessFailure('attachment_integrity_failed');
        }
        return OwnerImportOriginal._(upload, builder.takeBytes());
      },
    );
  });
  ({
    List<InformationField> fields,
    Map<String, String> bindings,
    List<InformationImportFilePromotion> promotions,
  })
  _prepareNewImportFiles(ImportItemInput input, String binding) {
    final fields = <InformationField>[],
        bindings = <String, String>{},
        promotions = <InformationImportFilePromotion>[];
    final now = _service._clock().toUtc();
    for (final a in input.attachments) {
      if (a.fieldId != null || a.currentVersion == null) {
        throw const AccessFailure('invalid_proposal');
      }
      final attachmentId = _service._secret(), fieldId = _service._secret();
      for (final (index, version) in a.versions.indexed) {
        final upload = version.upload;
        if (upload == null ||
            upload.consumed ||
            upload.sessionBinding != binding) {
          throw const AccessFailure('upload_unavailable');
        }
        promotions.add(
          InformationImportFilePromotion(
            upload,
            InformationAttachmentVersion(
              reference: InformationAttachmentRef(attachmentId, index + 1),
              originalName: upload.originalName,
              mediaType: upload.mediaType,
              byteLength: upload.byteLength,
              sha256: upload.sha256,
              createdAt: now,
              retiredAt: a.currentVersion == index + 1 ? null : now,
              label: version.label,
              sourceNote: version.sourceNote,
            ),
          ),
        );
      }
      fields.add(
        InformationField.file(
          fieldId,
          a.name.trim(),
          a.description,
          InformationAttachmentRef(attachmentId, a.currentVersion!),
          1,
        ),
      );
      if (a.templateField != null) {
        bindings[jsonEncode(['field', a.templateField])] = fieldId;
      }
    }
    return (fields: fields, bindings: bindings, promotions: promotions);
  }

  Future<List<ImportItemInput>> _resolveImportFiles(
    String binding,
    List<ImportItemInput> items,
  ) async {
    final result = <ImportItemInput>[];
    for (final item in items) {
      final attachments = <ImportAttachmentInput>[];
      for (final a in item.attachments) {
        final versions = <ImportAttachmentVersionInput>[];
        for (final v in a.versions) {
          final upload = await _importFiles(
            _service._repository,
          ).importFileUpload(v.uploadId);
          if (upload == null ||
              upload.consumed ||
              upload.sessionBinding != binding) {
            throw const AccessFailure('upload_unavailable');
          }
          versions.add(v.resolved(upload));
        }
        attachments.add(a.resolved(versions));
      }
      result.add(
        ImportItemInput.fromPrivateJson({
          ...item.toJson(),
          'attachments': [for (final a in attachments) a.toPrivateJson()],
        }),
      );
    }
    return result;
  }
}

final class OwnerImportOriginal {
  OwnerImportOriginal._(this.upload, Uint8List value)
    : bytes = value.asUnmodifiableView();
  final InformationImportUpload upload;
  final Uint8List bytes;
}
