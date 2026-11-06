part of 'info_core.dart';

/// Explicit owner selection. Descendants are resolved when reviewing the batch,
/// never inferred from a title, a relation or a same-name directory.
class LibraryRecycleSelection {
  LibraryRecycleSelection({
    Iterable<String> directoryIds = const [],
    Iterable<String> informationIds = const [],
    Iterable<String> credentialIds = const [],
  }) : directoryIds = List.unmodifiable(directoryIds.toSet().toList()..sort()),
       informationIds = List.unmodifiable(
         informationIds.toSet().toList()..sort(),
       ),
       credentialIds = List.unmodifiable(
         credentialIds.toSet().toList()..sort(),
       );
  final List<String> directoryIds, informationIds, credentialIds;
  Map<String, Object?> toJson() => {
    'directories': directoryIds,
    'information': informationIds,
    'credentials': credentialIds,
  };
}

/// Confirmation metadata only. Field values, private notes and credential
/// material do not belong in a deletion dialog or its review token payload.
class LibraryRecycleRecord {
  LibraryRecycleRecord({
    required this.kind,
    required this.id,
    required this.name,
    required this.typeId,
    required this.version,
    required this.directoryId,
    required Iterable<String> directoryPath,
    this.materialVersion,
  }) : directoryPath = List.unmodifiable(directoryPath);
  factory LibraryRecycleRecord.fromJson(Map<String, dynamic> json) {
    final value = LibraryRecycleRecord(
      kind: json['kind'] as String,
      id: json['id'] as String,
      name: json['name'] as String,
      typeId: json['typeId'] as String,
      version: json['version'] as int,
      directoryId: json['directoryId'] as String?,
      directoryPath: (json['directoryPath'] as List).cast<String>(),
      materialVersion: json['materialVersion'] as int?,
    );
    if (json.length != (value.materialVersion == null ? 7 : 8) ||
        !{'information', 'credential'}.contains(value.kind) ||
        value.id.isEmpty ||
        value.id.length > 200 ||
        value.name.isEmpty ||
        value.name.length > 200 ||
        value.typeId.isEmpty ||
        value.typeId.length > 200 ||
        value.directoryId != null &&
            (value.directoryId!.isEmpty || value.directoryId!.length > 200) ||
        (value.directoryId == null) != value.directoryPath.isEmpty ||
        (value.kind == 'credential') != (value.materialVersion != null) ||
        value.version < 1 ||
        value.materialVersion != null && value.materialVersion! < 1 ||
        value.directoryPath.any((p) => p.isEmpty || p.length > 200)) {
      throw const FormatException('Invalid recycle record metadata');
    }
    return value;
  }
  final String kind, id, name, typeId;
  final String? directoryId;
  final List<String> directoryPath;
  final int version;
  final int? materialVersion;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'id': id,
    'name': name,
    'typeId': typeId,
    'version': version,
    'directoryId': directoryId,
    'directoryPath': directoryPath,
    if (materialVersion != null) 'materialVersion': materialVersion,
  };
}

class LibraryRecyclePreview {
  LibraryRecyclePreview({
    required this.selection,
    required Iterable<InformationDirectory> directories,
    required Iterable<LibraryRecycleRecord> records,
    required Map<String, List<String>> directoryPaths,
  }) : directories = List.unmodifiable(directories),
       records = List.unmodifiable(records),
       directoryPaths = Map.unmodifiable({
         for (final e in directoryPaths.entries)
           e.key: List<String>.unmodifiable(e.value),
       });
  final LibraryRecycleSelection selection;
  final List<InformationDirectory> directories;
  final List<LibraryRecycleRecord> records;
  final Map<String, List<String>> directoryPaths;
  int get informationCount =>
      records.where((r) => r.kind == 'information').length;
  int get credentialCount =>
      records.where((r) => r.kind == 'credential').length;

  /// Recomputed immediately before committing the whole batch. Any new child,
  /// move, rename or record edit in the reviewed scope requires a fresh review.
  late final String token = sha256
      .convert(utf8.encode(jsonEncode(toJson())))
      .toString();
  Map<String, Object?> toJson() => {
    'selection': selection.toJson(),
    'directories': [
      for (final d in directories)
        [d.id, d.name, d.parentId, d.version, directoryPaths[d.id]],
    ],
    'records': records.map((r) => r.toJson()).toList(),
  };
}

extension OwnerLibraryRecycle on OwnerAccess {
  Future<LibraryRecyclePreview> previewLibraryRecycle(
    LibraryRecycleSelection selection,
  ) => _serialize(() async => _previewLibraryRecycle(selection));

  LibraryRecyclePreview _previewLibraryRecycle(
    LibraryRecycleSelection selection,
  ) {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final requested = [
      ...selection.directoryIds,
      ...selection.informationIds,
      ...selection.credentialIds,
    ];
    if (requested.isEmpty ||
        requested.any((id) => id.isEmpty || id.length > 200)) {
      throw const AccessFailure('invalid_library_selection');
    }
    final dirs = {for (final d in directories) d.id: d};
    final items = {for (final i in information) i.id: i};
    final credentialItems = {
      for (final c in _classificationCredentials) c.id: c,
    };
    if (selection.directoryIds.any((id) => !dirs.containsKey(id)) ||
        selection.informationIds.any((id) => !items.containsKey(id)) ||
        selection.credentialIds.any((id) => !credentialItems.containsKey(id))) {
      throw const AccessFailure('library_selection_changed');
    }
    final selectedDirs = selection.directoryIds.toSet();
    bool changed;
    do {
      changed = false;
      for (final d in dirs.values) {
        if (selectedDirs.contains(d.parentId) && selectedDirs.add(d.id)) {
          changed = true;
        }
      }
    } while (changed);
    List<String> path(String? id) {
      final names = <String>[], visited = <String>{};
      while (id != null) {
        final directory = dirs[id];
        if (directory == null || !visited.add(id)) {
          throw const AccessFailure('invalid_directory_tree');
        }
        names.insert(0, directory.name);
        id = directory.parentId;
      }
      return names;
    }

    final selectedItems = {
      ...selection.informationIds,
      for (final i in items.values)
        if (selectedDirs.contains(i.directoryId)) i.id,
    }.toList()..sort();
    final selectedCredentials = {
      ...selection.credentialIds,
      for (final c in credentialItems.values)
        if (selectedDirs.contains(c.directoryId)) c.id,
    }.toList()..sort();
    final sortedDirs = selectedDirs.toList()..sort();
    return LibraryRecyclePreview(
      selection: selection,
      directories: sortedDirs.map((id) => dirs[id]!),
      directoryPaths: {for (final id in sortedDirs) id: path(id)},
      records: [
        for (final id in selectedItems)
          LibraryRecycleRecord(
            kind: 'information',
            id: id,
            name: items[id]!.name,
            typeId: items[id]!.layout?.typeId ?? 'generic',
            version: items[id]!.version,
            directoryId: items[id]!.directoryId,
            directoryPath: path(items[id]!.directoryId),
          ),
        for (final id in selectedCredentials)
          LibraryRecycleRecord(
            kind: 'credential',
            id: id,
            name: credentialItems[id]!.name,
            typeId: credentialItems[id]!.template?.typeId ?? 'credential',
            version: credentialItems[id]!.revision,
            materialVersion: credentialItems[id]!.version,
            directoryId: credentialItems[id]!.directoryId,
            directoryPath: path(credentialItems[id]!.directoryId),
          ),
      ],
    );
  }
}
