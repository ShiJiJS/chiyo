part of 'info_core.dart';

/// A move keeps selected subtrees intact. Explicit records already inside a
/// selected subtree are part of that subtree, not moved a second time.
class LibraryMovePreview {
  LibraryMovePreview({
    required this.scope,
    required this.targetId,
    required Iterable<String> targetPath,
    required Iterable<String> roots,
    required Iterable<LibraryRecycleRecord> records,
    required Iterable<String> conflicts,
    required this.token,
  }) : targetPath = List.unmodifiable(targetPath),
       roots = List.unmodifiable(roots),
       records = List.unmodifiable(records),
       conflicts = List.unmodifiable(conflicts);
  final LibraryRecyclePreview scope;
  final String? targetId;
  final List<String> targetPath, roots, conflicts;
  final List<LibraryRecycleRecord> records;
  final String token;
  bool get canMove => conflicts.isEmpty;
}

/// Local acknowledgement contains identities and placement, never contents or
/// credential bytes. A retry returns the original result after later edits.
class LibraryMoveReceipt {
  LibraryMoveReceipt({
    required this.operationId,
    required this.inputHash,
    required this.targetId,
    required Iterable<String> targetPath,
    required Iterable<String> directoryIds,
    required Iterable<String> informationIds,
    required Iterable<String> credentialIds,
  }) : targetPath = List.unmodifiable(targetPath),
       directoryIds = List.unmodifiable(directoryIds),
       informationIds = List.unmodifiable(informationIds),
       credentialIds = List.unmodifiable(credentialIds);
  final String operationId, inputHash;
  final String? targetId;
  final List<String> targetPath, directoryIds, informationIds, credentialIds;
  Map<String, Object?> toJson() => {
    'format': 1,
    'operationId': operationId,
    'inputHash': inputHash,
    'targetId': targetId,
    'targetPath': targetPath,
    'directories': directoryIds,
    'information': informationIds,
    'credentials': credentialIds,
  };
  factory LibraryMoveReceipt.fromJson(Map<String, dynamic> json) {
    try {
      final value = LibraryMoveReceipt(
        operationId: json['operationId'] as String,
        inputHash: json['inputHash'] as String,
        targetId: json['targetId'] as String?,
        targetPath: (json['targetPath'] as List).cast<String>(),
        directoryIds: (json['directories'] as List).cast<String>(),
        informationIds: (json['information'] as List).cast<String>(),
        credentialIds: (json['credentials'] as List).cast<String>(),
      );
      _validateRecordOperationId(value.operationId);
      bool valid(String id) =>
          id.isNotEmpty && id.length <= 200 && !id.contains('\u0000');
      if (json.length != 8 ||
          json['format'] != 1 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(value.inputHash) ||
          value.targetId != null && !valid(value.targetId!) ||
          (value.targetId == null) != value.targetPath.isEmpty ||
          value.targetPath.any((p) => !valid(p)) ||
          [value.directoryIds, value.informationIds, value.credentialIds].any(
            (ids) =>
                ids.any((id) => !valid(id)) || ids.toSet().length != ids.length,
          )) {
        throw const FormatException();
      }
      return value;
    } on Object {
      throw const FormatException('Invalid library move receipt');
    }
  }
}

class LibraryMoveChange {
  LibraryMoveChange({
    required this.beforeToken,
    required this.receipt,
    required Iterable<InformationDirectory> directories,
    required Iterable<InformationItem> items,
    required Iterable<InformationRevision> previous,
    required Iterable<ManagedCredential> credentials,
    required this.validate,
  }) : directories = List.unmodifiable(directories),
       items = List.unmodifiable(items),
       previous = List.unmodifiable(previous),
       credentials = List.unmodifiable(credentials);
  final String beforeToken;
  final LibraryMoveReceipt receipt;
  final List<InformationDirectory> directories;
  final List<InformationItem> items;
  final List<InformationRevision> previous;
  final List<ManagedCredential> credentials;
  final void Function() validate;
}

abstract interface class LibraryMoveRepository {
  Future<LibraryMoveReceipt?> libraryMoveReceipt(String operationId);
  Future<LibraryMoveReceipt> commitLibraryMove(LibraryMoveChange change);
}

extension OwnerLibraryMove on OwnerAccess {
  bool get libraryMoveSupported =>
      _service._repository is LibraryMoveRepository && libraryRecycleSupported;
  LibraryMoveRepository get _libraryMoveRepository {
    if (_service._repository case final LibraryMoveRepository repository) {
      return repository;
    }
    throw const AccessFailure('unsupported_capability');
  }

  Future<LibraryMoveReceipt?> libraryMoveReceipt(String operationId) =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        _validateRecordOperationId(operationId);
        return _libraryMoveRepository.libraryMoveReceipt(operationId);
      });

  Future<LibraryMovePreview> previewLibraryMove(
    LibrarySelection selection,
    String? targetId,
  ) => _serialize(() async => _previewLibraryMove(selection, targetId));

  LibraryMovePreview _previewLibraryMove(
    LibrarySelection selection,
    String? targetId,
  ) {
    final scope = _previewLibraryRecycle(selection);
    final dirs = {for (final d in directories) d.id: d};
    final included = scope.directories.map((d) => d.id).toSet();
    final roots =
        scope.directories
            .where((d) => !included.contains(d.parentId))
            .map((d) => d.id)
            .toList()
          ..sort();
    final records = scope.records
        .where((r) => !included.contains(r.directoryId))
        .toList();
    final conflicts = <String>[];
    final targetPath = <String>[];
    final visited = <String>{};
    var cursor = targetId;
    while (cursor != null) {
      final d = dirs[cursor];
      if (d == null || !visited.add(cursor)) {
        throw const AccessFailure('move_target_missing');
      }
      targetPath.insert(0, d.name);
      cursor = d.parentId;
    }
    if (included.contains(targetId)) {
      conflicts.add('目录不能移进自己或自己的子目录。');
    }
    final names = <String, String>{};
    for (final d in dirs.values.where(
      (d) => d.parentId == targetId && !roots.contains(d.id),
    )) {
      names[d.name.trim().toLowerCase()] = d.id;
    }
    for (final id in roots) {
      final d = dirs[id]!, key = d.name.trim().toLowerCase();
      if (names.containsKey(key)) {
        conflicts.add('目标位置已有同名目录“${d.name}”，请先更名或选择其他位置。');
      }
      names[key] = id;
    }
    final sortedDirs = dirs.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final token = _libraryRecycleHash({
      'action': 'move',
      'scope': scope.toJson(),
      'targetId': targetId,
      'directories': [
        for (final d in sortedDirs) [d.id, d.name, d.parentId, d.version],
      ],
    });
    return LibraryMovePreview(
      scope: scope,
      targetId: targetId,
      targetPath: targetPath,
      roots: roots,
      records: records,
      conflicts: conflicts,
      token: token,
    );
  }

  Future<LibraryMoveReceipt> moveLibrarySelection(
    String operationId,
    LibrarySelection selection,
    String? targetId,
    String reviewToken,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    _validateRecordOperationId(operationId);
    final inputHash = _libraryRecycleHash({
      'action': 'move',
      'selection': selection.toJson(),
      'targetId': targetId,
      'reviewToken': reviewToken,
    });
    final repository = _libraryMoveRepository;
    final old = await repository.libraryMoveReceipt(operationId);
    if (old != null) {
      if (old.inputHash != inputHash) {
        throw const AccessFailure('operation_conflict');
      }
      return old;
    }
    final preview = _previewLibraryMove(selection, targetId);
    if (preview.token != reviewToken) {
      throw const AccessFailure('library_selection_changed');
    }
    if (!preview.canMove) throw const AccessFailure('library_move_conflict');
    final generation = _service._libraryGeneration,
        beforeToken = _libraryRecycleState(),
        now = _service._clock().toUtc();
    final roots = preview.roots.toSet();
    final changedDirectories = [
      for (final d in directories)
        if (roots.contains(d.id) && d.parentId != targetId)
          InformationDirectory(d.id, d.name, targetId, d.version + 1),
    ];
    final records = preview.records;
    final movedInformation = records
        .where((r) => r.kind == 'information')
        .map((r) => r.id)
        .toSet();
    final originals = information
        .where(
          (i) => movedInformation.contains(i.id) && i.directoryId != targetId,
        )
        .toList();
    final items = [
      for (final i in originals)
        InformationItem(
          i.id,
          i.name,
          i.description,
          i.version + 1,
          i.fields,
          directoryId: targetId,
          tagIds: i.tagIds,
          layout: i.layout,
          createdAt: i.createdAt,
          modifiedAt: now,
        ),
    ];
    final movedCredentials = records
        .where((r) => r.kind == 'credential')
        .map((r) => r.id)
        .toSet();
    final credentials = [
      for (final c in _vault.managedCredentials)
        if (movedCredentials.contains(c.id) && c.directoryId != targetId)
          c.copy(
            directoryId: targetId,
            clearDirectory: targetId == null,
            modifiedAt: now,
          )
        else
          c,
    ];
    final receipt = LibraryMoveReceipt(
      operationId: operationId,
      inputHash: inputHash,
      targetId: targetId,
      targetPath: preview.targetPath,
      directoryIds: changedDirectories.map((d) => d.id),
      informationIds: items.map((i) => i.id),
      credentialIds: _vault.managedCredentials
          .where(
            (c) => movedCredentials.contains(c.id) && c.directoryId != targetId,
          )
          .map((c) => c.id),
    );
    return repository.commitLibraryMove(
      LibraryMoveChange(
        beforeToken: beforeToken,
        receipt: receipt,
        directories: changedDirectories,
        items: items,
        previous: originals.map((i) => InformationRevision(i, now)),
        credentials: credentials,
        validate: () => _validateLibraryRecycleState(generation, beforeToken),
      ),
    );
  });
}
