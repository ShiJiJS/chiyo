part of 'info_core.dart';

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

  Future<InformationDirectory> createDirectory(
    String name, {
    String? parentId,
  }) => _serialize(() async {
    _checkOrganizationName(name);
    _checkParent(parentId);
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
  }) => _serialize(() async {
    _checkOrganizationName(name);
    _checkParent(parentId, id);
    final previous = directories.where((d) => d.id == id);
    if (previous.isEmpty) throw const AccessFailure('invalid_information');
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
    final result = InformationTag(_service._secret(), name.trim(), 1);
    await _service._repository.saveTag(result);
    return result;
  });

  Future<InformationTag> updateTag(String id, String name) =>
      _serialize(() async {
        _checkOrganizationName(name);
        final previous = tags.where((t) => t.id == id);
        if (previous.isEmpty) throw const AccessFailure('invalid_information');
        final result = InformationTag(
          id,
          name.trim(),
          previous.single.version + 1,
        );
        await _service._repository.saveTag(result);
        return result;
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
            InformationField(
              field.id,
              field.name,
              fieldDescriptions[field.id]!,
              field.value,
              field.version + 1,
            )
          else
            field,
      ],
      directoryId: old.directoryId,
      tagIds: old.tagIds,
    );
    await _service._repository.save(item);
    return item;
  });

  Future<InformationItem> organizeInformation(
    String id, {
    String? directoryId,
    Iterable<String> tagIds = const [],
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
    final item = InformationItem(
      old.id,
      old.name,
      old.description,
      old.version + 1,
      old.fields,
      directoryId: directoryId,
      tagIds: selectedTags,
    );
    await _service._repository.save(item);
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
