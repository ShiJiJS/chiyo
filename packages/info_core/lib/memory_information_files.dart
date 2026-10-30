part of 'information.dart';

extension _MemoryInformationAttachments on MemoryInformationRepository {
  Future<T> _withInformationFile<T>(
    InformationAttachmentRef ref,
    Future<T> Function(InformationAttachmentVersion, Stream<Uint8List>) action,
  ) async {
    final value = _informationFiles[ref];
    if (value == null || !value.$1.available || value.$2 == null) {
      throw const AccessFailure('attachment_missing');
    }
    Stream<Uint8List> chunks() async* {
      final bytes = value.$2!;
      for (var offset = 0; offset < bytes.length; offset += 1024 * 1024) {
        final end = offset + 1024 * 1024 < bytes.length
            ? offset + 1024 * 1024
            : bytes.length;
        yield Uint8List.fromList(bytes.sublist(offset, end));
      }
    }

    return action(value.$1, chunks());
  }

  void _reconcileInformationFiles(DateTime now) {
    if (_informationFiles.isEmpty) return;
    Set<InformationAttachmentRef> refs(Iterable<InformationItem> items) => {
      for (final item in items)
        for (final f in item.fields)
          if (f.attachment != null) f.attachment!,
    };
    final planned = retainInformationAttachments(
      versions: _informationFiles.values.map((v) => v.$1),
      current: refs(_items.values),
      retained: refs([
        ..._revisions.map((r) => r.item),
        ..._recycle.values.map((e) => e.snapshot).whereType<InformationItem>(),
      ]),
      now: now,
    );
    for (final v in planned) {
      _informationFiles[v.reference] = (
        v,
        v.available ? _informationFiles[v.reference]!.$2 : null,
      );
    }
  }

  Uint8List _readInformationFile(
    InformationAttachmentRef ref,
    int offset,
    int length,
  ) {
    final value = _informationFiles[ref];
    if (value == null || value.$2 == null || !value.$1.available) {
      throw const AccessFailure('attachment_missing');
    }
    if (offset < 0 ||
        length < 0 ||
        length > 1024 * 1024 ||
        offset + length > value.$1.byteLength) {
      throw const AccessFailure('invalid_information');
    }
    return Uint8List.fromList(value.$2!.sublist(offset, offset + length));
  }

  InformationDraftReceipt _commitInformationDraft(
    InformationDraftChange change,
  ) {
    final key = jsonEncode([change.draftId, change.operationId]);
    final receipt = change.receipt, item = receipt.item;
    if (change.operationReceipt != null &&
        _informationRecordReceipts.containsKey(change.operationId)) {
      throw const AccessFailure('operation_conflict');
    }
    final old = _informationCommits[key];
    if (old != null) {
      if (old.inputHash != receipt.inputHash) {
        throw const AccessFailure('operation_conflict');
      }
      return old;
    }
    final current = _items[item.id];
    if (change.previous == null
        ? current != null || item.version != 1
        : current == null ||
              current.version != change.previous!.item.version ||
              item.version != current.version + 1) {
      throw const AccessFailure('version_conflict');
    }
    final promotions =
        <
          InformationAttachmentRef,
          (InformationAttachmentVersion, Uint8List?)
        >{};
    final stageIds = <String>{};
    for (final p in change.promotions) {
      if (!stageIds.add(p.stageId) ||
          promotions.containsKey(p.version.reference)) {
        throw const AccessFailure('stage_unavailable');
      }
      final (stage, bytes) = _fileStages.stageBody(change.draftId, p.stageId);
      final v = p.version;
      final latest = _informationFiles.keys
          .where((r) => r.attachmentId == v.reference.attachmentId)
          .fold<int>(
            0,
            (n, r) => r.attachmentVersion > n ? r.attachmentVersion : n,
          );
      if (v.reference.attachmentVersion != latest + 1 ||
          stage.originalName != v.originalName ||
          stage.mediaType != v.mediaType ||
          stage.byteLength != v.byteLength ||
          stage.sha256 != v.sha256 ||
          crypto.sha256.convert(bytes).toString() != v.sha256 ||
          !v.available ||
          v.retiredAt != null) {
        throw const AccessFailure('attachment_integrity_failed');
      }
      promotions[v.reference] = (v, bytes);
    }
    for (final field in item.fields.where((f) => f.kind == FieldKind.file)) {
      final value =
          promotions[field.attachment] ?? _informationFiles[field.attachment];
      if (value == null || value.$2 == null || !value.$1.available) {
        throw const AccessFailure('attachment_missing');
      }
    }
    change.validate();
    _informationFiles.addAll(promotions);
    _items[item.id] = item;
    if (change.previous != null) _revisions.add(change.previous!);
    for (final entry in change.entries) {
      _recycle[entry.id] = entry;
    }
    _recycleFacts.addAll(change.facts);
    if (change.operationReceipt case final operation?) {
      _informationRecordReceipts[change.operationId] = operation;
    } else {
      _informationCommits[key] = receipt;
    }
    _fileStages.consume(change.draftId, stageIds);
    _reconcileInformationFiles(item.modifiedAt!.toUtc());
    return receipt;
  }
}
