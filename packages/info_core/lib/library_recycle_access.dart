part of 'info_core.dart';

extension OwnerLibraryRecycleOperations on OwnerAccess {
  LibraryRecycleRepository get _libraryRecycleRepository {
    final repository = _service._repository;
    if (repository is LibraryRecycleRepository) {
      return repository as LibraryRecycleRepository;
    }
    throw const AccessFailure('unsupported_capability');
  }

  List<LibraryRecycleBatch> get libraryRecycleBatches => List.unmodifiable(
    _libraryRecycleRepository.libraryRecycleBatches.where(
      (b) =>
          b.state == RecycleState.available &&
          _service._clock().isBefore(b.expiresAt),
    ),
  );
  String _libraryRecycleState() => libraryRecycleStateToken(
    directories: directories,
    tags: tags,
    informationVersions: information.map(
      (i) => [i.id, i.version, i.directoryId],
    ),
    credentials: _vault.managedCredentials,
    materials: _vault.credentialMaterials,
    entries: _service._repository.recycleEntries,
    facts: recycleFacts,
    batches: _libraryRecycleRepository.libraryRecycleBatches,
  );
  Future<LibraryRecycleReceipt?> libraryRecycleReceipt(String operationId) =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        _validateRecordOperationId(operationId);
        return _libraryRecycleRepository.libraryRecycleReceipt(operationId);
      });
  String _libraryRecycleHash(Map<String, Object?> input) =>
      sha256.convert(utf8.encode(jsonEncode(input))).toString();
  Future<LibraryRecycleReceipt?> _previousLibraryRecycle(
    String id,
    String hash,
  ) async {
    final old = await _libraryRecycleRepository.libraryRecycleReceipt(id);
    if (old != null && old.inputHash != hash) {
      throw const AccessFailure('operation_conflict');
    }
    return old;
  }

  void _validateLibraryRecycleState(int generation, String token) {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    if (generation != _service._libraryGeneration) {
      throw const AccessFailure('library_changed');
    }
    if (_libraryRecycleState() != token) {
      throw const AccessFailure('library_selection_changed');
    }
  }

  Future<LibraryRecycleReceipt> recycleLibrarySelection(
    String operationId,
    LibraryRecycleSelection selection,
    String reviewToken,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    _validateRecordOperationId(operationId);
    final hash = _libraryRecycleHash({
      'action': 'recycle',
      'selection': selection.toJson(),
      'reviewToken': reviewToken,
    });
    final old = await _previousLibraryRecycle(operationId, hash);
    if (old != null) return old;
    final preview = _previewLibraryRecycle(selection);
    if (preview.token != reviewToken) {
      throw const AccessFailure('library_selection_changed');
    }
    final generation = _service._libraryGeneration,
        beforeToken = _libraryRecycleState(),
        now = _service._clock().toUtc();
    final itemsById = {for (final i in information) i.id: i};
    final entries = <RecycleEntry>[],
        facts = <RecycleFact>[],
        previous = <InformationRevision>[];
    final informationEntries = <String, String>{},
        credentialRevisions = <String, int>{};
    final credentials = List<ManagedCredential>.of(_vault.managedCredentials);
    var materials = List<CredentialMaterial>.of(_vault.credentialMaterials);
    for (final record in preview.records) {
      if (record.kind == 'information') {
        final item = itemsById[record.id]!;
        final entry = _recycle(item, null);
        entries.add(entry);
        facts.add(_fact(entry, RecycleFactKind.deleted, entry.version));
        previous.add(InformationRevision(item, now));
        informationEntries[item.id] = entry.id;
      } else {
        final index = credentials.indexWhere((c) => c.id == record.id);
        final next = credentialLifecycleSnapshot(
          old: credentials[index],
          materials: materials,
          action: CredentialRecordAction.recycle,
          now: now,
          directoryIds: directories.map((d) => d.id).toSet(),
          tagIds: tags.map((t) => t.id).toSet(),
        );
        credentials[index] = next.credential;
        materials = next.materials;
        credentialRevisions[record.id] = next.credential.revision;
      }
    }
    final removedDirs = preview.directories.map((d) => d.id).toSet();
    final batch = LibraryRecycleBatch(
      id: _service._secret(),
      deletedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
      directories: directories.where((d) => removedDirs.contains(d.id)),
      records: preview.records,
      directoryPaths: preview.directoryPaths,
      informationEntries: informationEntries,
      credentialRevisions: credentialRevisions,
    );
    final receipt = LibraryRecycleReceipt(
      operationId: operationId,
      inputHash: hash,
      batchId: batch.id,
      action: LibraryRecycleAction.recycle,
      batchVersion: batch.version,
    );
    final result = await _libraryRecycleRepository.commitLibraryRecycle(
      LibraryRecycleChange(
        beforeToken: beforeToken,
        batch: batch,
        receipt: receipt,
        directories: directories.where((d) => !removedDirs.contains(d.id)),
        removedInformationIds: informationEntries.keys,
        items: const [],
        previous: previous,
        entries: entries,
        facts: facts,
        credentials: credentials,
        materials: materials,
        validate: () => _validateLibraryRecycleState(generation, beforeToken),
      ),
    );
    for (final revision in previous) {
      _invalidateRemoved(revision.item, null);
    }
    return result;
  });

  LibraryRecycleBatch _libraryRecycleBatch(String id) {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final batch = _libraryRecycleRepository.libraryRecycleBatches
        .where((b) => b.id == id)
        .firstOrNull;
    if (batch == null ||
        batch.state != RecycleState.available ||
        !_service._clock().isBefore(batch.expiresAt)) {
      throw const AccessFailure('recycle_unavailable');
    }
    return batch;
  }

  Future<LibraryRecycleRestorePreview> previewLibraryRecycleRestore(
    String id, {
    LibraryRecycleRestoreOptions? options,
  }) => _serialize(
    () async => _previewLibraryRecycleRestore(
      id,
      options ?? LibraryRecycleRestoreOptions(),
    ),
  );
  LibraryRecycleRestorePreview _previewLibraryRecycleRestore(
    String id,
    LibraryRecycleRestoreOptions options,
  ) {
    final batch = _libraryRecycleBatch(id),
        ids = batch.directories.map((d) => d.id).toSet();
    final roots = batch.directories
        .where((d) => !ids.contains(d.parentId))
        .map((d) => d.id)
        .toSet();
    if (options.directoryNames.keys.any((id) => !ids.contains(id)) ||
        options.parentOverrides.keys.any((id) => !roots.contains(id))) {
      throw const AccessFailure('invalid_restoration_options');
    }
    final warnings = <String>[], conflicts = <String>[];
    final restoredDirs = [
      for (final d in batch.directories)
        InformationDirectory(
          d.id,
          options.directoryNames[d.id]?.trim() ?? d.name,
          options.parentOverrides.containsKey(d.id)
              ? options.parentOverrides[d.id]
              : d.parentId,
          d.version + 1,
        ),
    ];
    final allDirs = {
      for (final d in directories) d.id: d,
      for (final d in restoredDirs) d.id: d,
    };
    final currentIds = directories.map((d) => d.id).toSet();
    for (final d in restoredDirs) {
      if (currentIds.contains(d.id)) {
        conflicts.add('目录“${d.name}”的原身份已存在，请重新核对。');
      }
      try {
        _checkDirectoryName(d.name);
      } on AccessFailure {
        conflicts.add('请修改无效的目录名称“${d.name}”。');
      }
      if (d.parentId != null && !allDirs.containsKey(d.parentId)) {
        conflicts.add('目录“${d.name}”的原上级已不存在，请选择恢复位置。');
      }
      if (allDirs.values.any(
        (other) =>
            other.id != d.id &&
            other.parentId == d.parentId &&
            other.name.toLowerCase() == d.name.toLowerCase(),
      )) {
        conflicts.add('“${d.name}”所在位置已有同名目录，请修改恢复名称或位置。');
      }
    }
    List<String> path(String? id) {
      final names = <String>[], seen = <String>{};
      while (id != null) {
        final d = allDirs[id];
        if (d == null) break;
        if (!seen.add(id)) {
          conflicts.add('恢复目录的位置形成了循环，请重新选择。');
          break;
        }
        names.insert(0, d.name);
        id = d.parentId;
      }
      return names;
    }

    for (final d in restoredDirs) {
      final next = path(d.id), old = batch.directoryPaths[d.id]!;
      if (jsonEncode(next) != jsonEncode(old)) {
        warnings.add('目录“${old.join(' / ')}”将恢复到“${next.join(' / ')}”。');
      }
    }
    final byEntry = {
      for (final e in _service._repository.recycleEntries) e.id: e,
    };
    final credentials = {for (final c in _vault.managedCredentials) c.id: c};
    final currentItems = information.map((i) => i.id).toSet();
    final records = <LibraryRecycleRecord>[];
    for (final r in batch.records) {
      var version = r.version;
      String? directoryId = r.directoryId;
      if (r.kind == 'information') {
        final entry = byEntry[batch.informationEntries[r.id]];
        if (entry == null ||
            entry.snapshot == null ||
            !entry.wholeItem ||
            entry.state != RecycleState.available ||
            !_service._clock().isBefore(entry.expiresAt) ||
            currentItems.contains(r.id)) {
          conflicts.add('资料“${r.name}”已另行处理或超过保留时间，不能直接整体恢复。');
        } else {
          version =
              recycleFacts
                  .where((f) => f.itemId == r.id)
                  .fold<int>(entry.version, (v, f) => max(v, f.version)) +
              1;
        }
      } else {
        final c = credentials[r.id];
        if (c == null ||
            c.deletedAt == null ||
            c.purgedAt != null ||
            c.revision != batch.credentialRevisions[r.id]) {
          conflicts.add('凭据“${r.name}”已另行处理，不能直接整体恢复。');
        } else {
          try {
            _retainedMaterial(c.id, c.version);
          } on AccessFailure {
            conflicts.add('凭据“${r.name}”的内容已不可恢复。');
          }
          version = c.revision + 1;
        }
      }
      if (directoryId != null && !allDirs.containsKey(directoryId)) {
        directoryId = null;
        warnings.add('“${r.name}”的原目录已不存在，将恢复为未分类。');
      }
      records.add(
        LibraryRecycleRecord(
          kind: r.kind,
          id: r.id,
          name: r.name,
          typeId: r.typeId,
          version: version,
          materialVersion: r.kind == 'credential'
              ? (credentials[r.id]?.version ?? r.materialVersion ?? 0) + 1
              : null,
          directoryId: directoryId,
          directoryPath: path(directoryId),
        ),
      );
    }
    return LibraryRecycleRestorePreview(
      batchId: id,
      stateToken: _libraryRecycleState(),
      options: options,
      directories: restoredDirs,
      records: records,
      warnings: warnings.toSet(),
      conflicts: conflicts.toSet(),
    );
  }

  Future<LibraryRecycleReceipt> restoreLibraryRecycleBatch(
    String operationId,
    String batchId,
    String reviewToken, {
    LibraryRecycleRestoreOptions? options,
  }) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    _validateRecordOperationId(operationId);
    options ??= LibraryRecycleRestoreOptions();
    final hash = _libraryRecycleHash({
      'action': 'restore',
      'batchId': batchId,
      'reviewToken': reviewToken,
      'options': options!.toJson(),
    });
    final old = await _previousLibraryRecycle(operationId, hash);
    if (old != null) return old;
    final preview = _previewLibraryRecycleRestore(batchId, options!);
    if (preview.token != reviewToken) {
      throw const AccessFailure('library_selection_changed');
    }
    if (!preview.canRestore) throw const AccessFailure('recycle_conflict');
    final batch = _libraryRecycleBatch(batchId),
        now = _service._clock().toUtc(),
        generation = _service._libraryGeneration;
    final restoredDirectoryIds = {
      ...directories.map((d) => d.id),
      ...preview.directories.map((d) => d.id),
    };
    final items = <InformationItem>[],
        entries = <RecycleEntry>[],
        facts = <RecycleFact>[];
    final restoredItemIds = batch.informationEntries.keys.toSet(),
        restoredCredentialIds = batch.credentialRevisions.keys.toSet();
    for (final r in preview.records.where((r) => r.kind == 'information')) {
      final entry = _service._repository.recycleEntries.singleWhere(
        (e) => e.id == batch.informationEntries[r.id],
      );
      final source = entry.snapshot!,
          restoredFields = {
            for (final f in source.fields) f.id: _service._secret(),
          };
      items.add(
        InformationItem(
          source.id,
          source.name,
          source.description,
          r.version,
          [
            for (final f in source.fields)
              f.withMetadata(id: restoredFields[f.id]!, version: f.version + 1),
          ],
          directoryId: r.directoryId,
          tagIds: _existingTags(source.tagIds),
          layout: _existingLayoutRelations(
            source.layout?.restoreBindings(source.layout, restoredFields),
            additionalItems: restoredItemIds,
            additionalCredentials: restoredCredentialIds,
          ),
          createdAt: source.createdAt,
          modifiedAt: now,
        ),
      );
      entries.add(entry.finish(RecycleState.restored));
      facts.add(
        RecycleFact(
          entry.id,
          entry.itemId,
          source.fields.map((f) => f.id),
          r.version,
          RecycleFactKind.restored,
          now,
          restoredFieldIds: restoredFields,
        ),
      );
    }
    final credentials = List<ManagedCredential>.of(_vault.managedCredentials);
    var materials = List<CredentialMaterial>.of(_vault.credentialMaterials);
    for (final id in restoredCredentialIds) {
      final index = credentials.indexWhere((c) => c.id == id);
      final next = credentialLifecycleSnapshot(
        old: credentials[index],
        materials: materials,
        action: CredentialRecordAction.restoreRecycled,
        now: now,
        directoryIds: restoredDirectoryIds,
        tagIds: tags.map((t) => t.id).toSet(),
      );
      credentials[index] = next.credential;
      materials = next.materials;
    }
    final finished = batch.finish(RecycleState.restored),
        receipt = LibraryRecycleReceipt(
          operationId: operationId,
          inputHash: hash,
          batchId: batchId,
          action: LibraryRecycleAction.restore,
          batchVersion: finished.version,
        );
    return _libraryRecycleRepository.commitLibraryRecycle(
      LibraryRecycleChange(
        beforeToken: preview.stateToken,
        batch: finished,
        receipt: receipt,
        directories: [...directories, ...preview.directories],
        removedInformationIds: const [],
        items: items,
        previous: const [],
        entries: entries,
        facts: facts,
        credentials: credentials,
        materials: materials,
        validate: () {
          _validateLibraryRecycleState(generation, preview.stateToken);
          if (!_service._clock().isBefore(batch.expiresAt)) {
            throw const AccessFailure('recycle_unavailable');
          }
        },
      ),
    );
  });
}
