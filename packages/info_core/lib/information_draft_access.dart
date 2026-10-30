part of 'info_core.dart';

extension OwnerInformationDrafts on OwnerAccess {
  InformationAttachmentRepository get _attachments {
    if (_service._repository case final InformationAttachmentRepository repo) {
      return repo;
    }
    throw const AccessFailure('unsupported_capability');
  }

  Future<List<InformationAttachmentVersion>> informationAttachmentVersions(
    String id,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    return _attachments.informationAttachmentVersions(id);
  });

  Future<InformationItem> commitInformationDraft(
    InformationFileDraft draft,
    String operationId,
    InformationDraftInput input,
  ) => _serialize(() => _commitInformationDraft(draft, operationId, input));

  Future<InformationItem> _commitInformationDraft(
    InformationFileDraft draft,
    String operationId,
    InformationDraftInput input, {
    bool durableReceipt = false,
  }) async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    if (!identical(draft._owner, this) ||
        draft._generation != _service._libraryGeneration) {
      throw const AccessFailure('stage_unavailable');
    }
    if (operationId.isEmpty ||
        operationId.length > 200 ||
        operationId.codeUnits.any((c) => c < 33 || c > 126)) {
      throw const AccessFailure('invalid_information');
    }
    if (input.name.length > 200 ||
        input.description.length > 2000 ||
        input.fields.isEmpty ||
        input.fields.length > 200 ||
        input.tagIds.length > 100 ||
        input.tagIds.toSet().length != input.tagIds.length ||
        input.fields.any(
          (f) =>
              f.name.length > 200 ||
              f.description.length > 2000 ||
              (f.text?.length ?? 0) > 1000000,
        )) {
      throw const AccessFailure('invalid_information');
    }
    final hash = sha256
        .convert(utf8.encode(jsonEncode(input.toPrivateJson())))
        .toString();
    final previousReceipt = await _attachments.informationDraftReceipt(
      draft.id,
      operationId,
    );
    if (previousReceipt != null) {
      if (previousReceipt.inputHash != hash) {
        throw const AccessFailure('operation_conflict');
      }
      return previousReceipt.item;
    }
    _checkInformationFileDraft(draft);
    final before = input.itemId == null
        ? null
        : information.where((i) => i.id == input.itemId).firstOrNull;
    if (input.itemId == null
        ? input.baseVersion != null
        : before == null || before.version != input.baseVersion) {
      throw const AccessFailure('version_conflict');
    }
    _checkOrganizationName(input.name);
    _checkParent(input.directoryId);
    if (input.description.length > 2000 ||
        input.fields.isEmpty ||
        input.fields.length > 200 ||
        input.tagIds.length > 100 ||
        input.tagIds.toSet().length != input.tagIds.length ||
        input.tagIds.any((id) => !tags.any((t) => t.id == id))) {
      throw const AccessFailure('invalid_information');
    }
    final seen = <String>{}, seenStages = <String>{};
    final fields = <InformationField>[],
        promotions = <InformationAttachmentPromotion>[];
    final now = _service._clock().toUtc();
    for (final f in input.fields) {
      final old = f.fieldId == null
          ? null
          : before?.fields.where((a) => a.id == f.fieldId).firstOrNull;
      if (f.name.trim().isEmpty ||
          f.name.length > 200 ||
          f.description.length > 2000 ||
          (f.fieldId != null && (old == null || !seen.add(f.fieldId!)))) {
        throw const AccessFailure('invalid_information');
      }
      final retain =
          old != null &&
          !f.replaceIdentity &&
          old.kind == f.kind &&
          old.name == f.name.trim();
      final id = retain ? old.id : _service._secret();
      InformationField field;
      if (f.kind != FieldKind.file) {
        if (f.text == null ||
            f.text!.length > 1000000 ||
            f.stageId != null ||
            f.attachment != null) {
          throw const AccessFailure('invalid_information');
        }
        field = InformationField(
          id,
          f.name.trim(),
          f.description,
          f.text!,
          1,
          kind: f.kind,
        );
      } else {
        InformationAttachmentRef reference;
        if (f.stageId != null) {
          if (f.attachment != null || !seenStages.add(f.stageId!)) {
            throw const AccessFailure('stage_unavailable');
          }
          final stage = await _attachments.informationStage(
            draft.id,
            f.stageId!,
          );
          final attachmentId = retain && old.kind == FieldKind.file
              ? old.attachment!.attachmentId
              : _service._secret();
          final versions = await _attachments.informationAttachmentVersions(
            attachmentId,
          );
          final number =
              versions.fold<int>(
                0,
                (n, v) => max(n, v.reference.attachmentVersion),
              ) +
              1;
          if (number > 2147483647) {
            throw const AccessFailure('invalid_information');
          }
          reference = InformationAttachmentRef(attachmentId, number);
          promotions.add(
            InformationAttachmentPromotion(
              stage.id,
              InformationAttachmentVersion(
                reference: reference,
                originalName: stage.originalName,
                mediaType: stage.mediaType,
                byteLength: stage.byteLength,
                sha256: stage.sha256,
                createdAt: now,
              ),
            ),
          );
        } else {
          if (old == null ||
              old.kind != FieldKind.file ||
              f.attachment == null ||
              f.attachment != old.attachment) {
            throw const AccessFailure('stage_unavailable');
          }
          reference = f.attachment!;
        }
        field = InformationField.file(
          id,
          f.name.trim(),
          f.description,
          reference,
          1,
        );
      }
      if (retain) {
        final changed =
            old.description != field.description || !old.hasSameContent(field);
        field = field.withMetadata(version: old.version + (changed ? 1 : 0));
      }
      fields.add(field);
    }
    final item = InformationItem(
      before?.id ?? _service._secret(),
      input.name.trim(),
      input.description,
      (before?.version ?? 0) + 1,
      fields,
      directoryId: input.directoryId,
      tagIds: input.tagIds,
      createdAt: before?.createdAt ?? (before == null ? now : null),
      modifiedAt: now,
    );
    final removed =
        before != null &&
        before.fields.any((f) => !fields.any((a) => a.id == f.id));
    final recycled = removed ? _recycle(before, item) : null;
    final receipt = await _attachments.commitInformationDraft(
      InformationDraftChange(
        draftId: draft.id,
        operationId: operationId,
        receipt: InformationDraftReceipt(hash, item),
        promotions: promotions,
        previous: before == null ? null : InformationRevision(before, now),
        entries: recycled == null ? const [] : [recycled],
        facts: recycled == null
            ? const []
            : [_fact(recycled, RecycleFactKind.deleted, item.version)],
        validate: () => _checkInformationFileDraft(draft),
        operationReceipt: durableReceipt
            ? InformationRecordReceipt(
                operationId: operationId,
                inputHash: hash,
                itemId: item.id,
                version: item.version,
                baseVersion: input.baseVersion,
              )
            : null,
      ),
    );
    if (before != null) _invalidateRemoved(before, receipt.item);
    return receipt.item;
  }
}
