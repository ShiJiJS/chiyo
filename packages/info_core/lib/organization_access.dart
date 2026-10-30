part of 'info_core.dart';

/// Builds labels without publishing them until the surrounding batch commits.
class _OrganizationPlan {
  _OrganizationPlan(this.owner);
  final OwnerAccess owner;
  final newDirectories = <InformationDirectory>[];
  final newTags = <InformationTag>[];
  (String?, Set<String>) resolve(
    String? id,
    Iterable<String> tags,
    String suggestedDirectory,
    Iterable<String> suggestedTags,
  ) {
    owner._checkParent(id);
    final selected = tags.toSet();
    if (selected.any((id) => !owner.tags.any((t) => t.id == id))) {
      throw const AccessFailure('invalid_proposal');
    }
    final name = suggestedDirectory.trim();
    if (id == null && name.isNotEmpty) {
      owner._checkDirectoryName(name);
      final found = [...owner.directories, ...newDirectories].where(
        (d) => d.parentId == null && d.name.toLowerCase() == name.toLowerCase(),
      );
      if (found.isNotEmpty) {
        id = found.first.id;
      } else {
        final directory = InformationDirectory(
          owner._service._secret(),
          name,
          null,
          1,
        );
        newDirectories.add(directory);
        id = directory.id;
      }
    }
    for (final raw in suggestedTags) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      owner._checkOrganizationName(name);
      final found = [
        ...owner.tags,
        ...newTags,
      ].where((t) => t.name.toLowerCase() == name.toLowerCase());
      if (found.isNotEmpty) {
        selected.add(found.first.id);
      } else {
        final tag = InformationTag(owner._service._secret(), name, 1);
        newTags.add(tag);
        selected.add(tag.id);
      }
    }
    if (selected.length > 100) throw const AccessFailure('invalid_proposal');
    return (id, selected);
  }
}

extension OwnerOrganization on OwnerAccess {
  List<InformationDirectory> get directories =>
      _service._repository.directories;
  List<InformationTag> get tags => _service._repository.tags;

  void _checkOrganizationName(String name) {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    if (name.trim().isEmpty || name.length > 200) {
      throw const AccessFailure('invalid_information');
    }
  }

  void _checkParent(String? parentId, [String? self]) {
    final visited = <String>{?self};
    var cursor = parentId;
    while (cursor != null) {
      if (!visited.add(cursor)) {
        throw const AccessFailure('invalid_information');
      }
      final found = directories.where((d) => d.id == cursor);
      if (found.isEmpty) throw const AccessFailure('invalid_information');
      cursor = found.single.parentId;
    }
  }

  void _checkDirectoryName(String name) {
    _checkOrganizationName(name);
    if (name.contains('/') || name.contains(r'\')) {
      throw const AccessFailure('invalid_directory_name');
    }
  }

  void _uniqueDirectory(String name, String? parentId, [String? except]) {
    if (directories.any(
      (d) =>
          d.id != except &&
          d.parentId == parentId &&
          d.name.trim().toLowerCase() == name.trim().toLowerCase(),
    )) {
      throw const AccessFailure('duplicate_directory');
    }
  }

  void _uniqueTag(String name, [String? except]) {
    if (tags.any(
      (t) =>
          t.id != except &&
          t.name.trim().toLowerCase() == name.trim().toLowerCase(),
    )) {
      throw const AccessFailure('duplicate_tag');
    }
  }

  String? _existingDirectory(String? id) =>
      directories.any((d) => d.id == id) ? id : null;
  Iterable<String> _existingTags(Iterable<String> ids) =>
      ids.where((id) => tags.any((t) => t.id == id));

  Future<InformationDirectory> createDirectory(
    String name, {
    String? parentId,
  }) => _serialize(() async {
    _checkDirectoryName(name);
    _checkParent(parentId);
    _uniqueDirectory(name, parentId);
    final result = InformationDirectory(
      _service._secret(),
      name.trim(),
      parentId,
      1,
    );
    await _service._repository.saveDirectory(result);
    return result;
  });

  Future<InformationDirectory> updateDirectory(
    String id,
    String name, {
    String? parentId,
    int? expectedVersion,
  }) => _serialize(() async {
    _checkParent(parentId, id);
    final previous = directories.where((d) => d.id == id);
    if (previous.isEmpty) throw const AccessFailure('invalid_information');
    if (expectedVersion != null && previous.single.version != expectedVersion) {
      throw const AccessFailure('organization_conflict');
    }
    if (name.trim() == previous.single.name) {
      _checkOrganizationName(name);
    } else {
      _checkDirectoryName(name);
    }
    _uniqueDirectory(name, parentId, id);
    final result = InformationDirectory(
      id,
      name.trim(),
      parentId,
      previous.single.version + 1,
    );
    await _service._repository.saveDirectory(result);
    return result;
  });

  Future<InformationTag> createTag(String name) => _serialize(() async {
    _checkOrganizationName(name);
    _uniqueTag(name);
    final result = InformationTag(_service._secret(), name.trim(), 1);
    await _service._repository.saveTag(result);
    return result;
  });

  Future<InformationTag> updateTag(
    String id,
    String name, {
    int? expectedVersion,
  }) => _serialize(() async {
    _checkOrganizationName(name);
    final previous = tags.where((t) => t.id == id);
    if (previous.isEmpty) throw const AccessFailure('invalid_information');
    if (expectedVersion != null && previous.single.version != expectedVersion) {
      throw const AccessFailure('organization_conflict');
    }
    _uniqueTag(name, id);
    final result = InformationTag(id, name.trim(), previous.single.version + 1);
    await _service._repository.saveTag(result);
    return result;
  });

  Future<void> deleteDirectory(String id, int expectedVersion) => _serialize(
    () async {
      void validate() {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        final directory = directories.where((d) => d.id == id).firstOrNull;
        if (directory == null || directory.version != expectedVersion) {
          throw const AccessFailure('organization_conflict');
        }
        if (directories.any((d) => d.parentId == id) ||
            information.any((i) => i.directoryId == id)) {
          throw const AccessFailure('directory_not_empty');
        }
      }

      validate();
      await _service._repository.commitOrganizationRemoval(
        directoryId: id,
        validate: validate,
      );
    },
  );

  Future<void> deleteTag(
    String id,
    int expectedVersion, {
    Map<String, int>? reviewedInformation,
  }) => _serialize(() async {
    final originals = information.where((i) => i.tagIds.contains(id)).toList();
    if (reviewedInformation != null &&
        (reviewedInformation.length != originals.length ||
            originals.any((i) => reviewedInformation[i.id] != i.version))) {
      throw const AccessFailure('organization_conflict');
    }
    void validate() {
      if (!serviceAvailable) throw const AccessFailure('service_unavailable');
      final tag = tags.where((t) => t.id == id).firstOrNull;
      if (tag == null ||
          tag.version != expectedVersion ||
          information.where((i) => i.tagIds.contains(id)).length !=
              originals.length ||
          originals.any(
            (old) => !information.any(
              (i) => i.id == old.id && i.version == old.version,
            ),
          )) {
        throw const AccessFailure('organization_conflict');
      }
    }

    validate();
    final now = _service._clock();
    await _service._repository.commitOrganizationRemoval(
      tagId: id,
      items: [
        for (final old in originals)
          InformationItem(
            old.id,
            old.name,
            old.description,
            old.version + 1,
            old.fields,
            directoryId: old.directoryId,
            tagIds: old.tagIds.where((t) => t != id),
            layout: old.layout,
            createdAt: old.createdAt,
            modifiedAt: now,
          ),
      ],
      previous: [for (final old in originals) InformationRevision(old, now)],
      validate: validate,
    );
  });

  /// Only descriptions can change for an existing field. Changing its meaning
  /// requires a new field identity, never a rename behind an existing grant.
  Future<InformationItem> updateCatalogMetadata(
    String id, {
    required String name,
    required String description,
    required Map<String, String> fieldDescriptions,
  }) => _serialize(() async {
    _checkOrganizationName(name);
    final found = information.where((i) => i.id == id);
    if (found.isEmpty ||
        description.length > 2000 ||
        fieldDescriptions.length > 200 ||
        fieldDescriptions.values.any((d) => d.length > 2000)) {
      throw const AccessFailure('invalid_information');
    }
    final old = found.single;
    if (fieldDescriptions.keys.any(
      (id) => !old.fields.any((f) => f.id == id),
    )) {
      throw const AccessFailure('invalid_information');
    }
    final item = InformationItem(
      old.id,
      name.trim(),
      description,
      old.version + 1,
      [
        for (final field in old.fields)
          if (fieldDescriptions.containsKey(field.id))
            field.withMetadata(
              description: fieldDescriptions[field.id]!,
              version: field.version + 1,
            )
          else
            field,
      ],
      directoryId: old.directoryId,
      tagIds: old.tagIds,
      layout: old.layout,
      createdAt: old.createdAt,
      modifiedAt: _service._clock(),
    );
    await _service._repository.saveInformationRevision(
      item,
      InformationRevision(old, _service._clock()),
    );
    return item;
  });

  Future<InformationItem> organizeInformation(
    String id, {
    String? directoryId,
    Iterable<String> tagIds = const [],
    int? expectedVersion,
  }) => _serialize(() async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    _checkParent(directoryId);
    final selectedTags = tagIds.toSet();
    final previous = information.where((i) => i.id == id);
    if (previous.isEmpty ||
        selectedTags.length > 100 ||
        selectedTags.any((id) => !tags.any((t) => t.id == id))) {
      throw const AccessFailure('invalid_information');
    }
    final old = previous.single;
    if (expectedVersion != null && old.version != expectedVersion) {
      throw const AccessFailure('information_conflict');
    }
    final item = InformationItem(
      old.id,
      old.name,
      old.description,
      old.version + 1,
      old.fields,
      directoryId: directoryId,
      tagIds: selectedTags,
      layout: old.layout,
      createdAt: old.createdAt,
      modifiedAt: _service._clock(),
    );
    await _service._repository.saveInformationRevision(
      item,
      InformationRevision(old, _service._clock()),
    );
    return item;
  });

  /// A snapshot of explicit identities, never a grant over a dynamic directory.
  List<FieldRef> fieldsInDirectory(String id) {
    _checkParent(id);
    final included = _descendantDirectories(id);
    return List.unmodifiable([
      for (final item in information.where(
        (i) => included.contains(i.directoryId),
      ))
        for (final field in item.fields) FieldRef(item.id, field.id),
    ]);
  }

  Set<String> _descendantDirectories(String id) {
    final included = <String>{id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final directory in directories) {
        if (included.contains(directory.parentId) &&
            included.add(directory.id)) {
          changed = true;
        }
      }
    }
    return included;
  }
}

class CatalogPage {
  CatalogPage(Iterable<Map<String, Object?>> items, this.total, this.nextOffset)
    : items = List.unmodifiable(items.map(Map<String, Object?>.unmodifiable));
  final List<Map<String, Object?>> items;
  final int total;
  final int? nextOffset;
}

extension AgentCatalog on AgentAccess {
  CatalogPage searchCatalog({
    String query = '',
    String? directoryId,
    String? tagId,
    int offset = 0,
    int limit = 20,
  }) {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    if (query.length > 200 ||
        offset < 0 ||
        offset > 1000000 ||
        limit < 1 ||
        limit > 100 ||
        [
          directoryId,
          tagId,
        ].any((id) => id != null && (id.isEmpty || id.length > 200))) {
      throw const AccessFailure('invalid_request');
    }
    final queryText = query.trim().toLowerCase();
    final includedDirectories = directoryId == null
        ? null
        : _service.owner._descendantDirectories(directoryId);
    final matches = _catalogMetadata().where((item) {
      if (includedDirectories != null &&
          !includedDirectories.contains(item['directoryId'])) {
        return false;
      }
      if (tagId != null && !(item['tagIds'] as List<String>).contains(tagId)) {
        return false;
      }
      // Explicit allowlist: no values, owner labels, notes, or search snippets.
      final publicText = [
        item['name'],
        item['description'],
        for (final field in item['fields'] as List<Map<String, String>>) ...[
          field['name'],
          field['description'],
        ],
      ].join('\n').toLowerCase();
      return publicText.contains(queryText);
    }).toList();
    final page = matches.skip(offset).take(limit).toList();
    final next = offset + page.length;
    return CatalogPage(
      page,
      matches.length,
      next < matches.length ? next : null,
    );
  }
}
