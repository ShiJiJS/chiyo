part of 'info_core.dart';

class InformationPage {
  InformationPage(
    Iterable<InformationItem> items,
    this.total,
    this.offset,
    this.limit,
  ) : items = List.unmodifiable(items);
  final List<InformationItem> items;
  final int total, offset, limit;
}

extension OwnerLibrary on OwnerAccess {
  /// Public metadata search; tags use AND. The page has a deterministic name/ID
  /// order and includes zero-field items. Directory membership never grants access.
  InformationPage queryInformation({
    String search = '',
    String? directoryId,
    bool includeDescendants = true,
    bool unclassifiedOnly = false,
    bool sortDescending = false,
    Iterable<String> tagIds = const [],
    int offset = 0,
    int limit = 20,
    String? focusItemId,
  }) {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final selectedTags = tagIds.toSet();
    if (search.length > 2000 ||
        offset < 0 ||
        offset > 1000000 ||
        limit < 1 ||
        limit > 100 ||
        selectedTags.length > 100 ||
        selectedTags.any((id) => !tags.any((t) => t.id == id))) {
      throw const AccessFailure('invalid_query');
    }
    _checkParent(directoryId);
    final included = directoryId == null
        ? null
        : includeDescendants
        ? _descendantDirectories(directoryId)
        : {directoryId};
    final needle = search.trim().toLowerCase();
    final matches =
        information
            .where(
              (i) =>
                  (included == null || included.contains(i.directoryId)) &&
                  (!unclassifiedOnly || i.directoryId == null) &&
                  selectedTags.every(i.tagIds.contains) &&
                  [
                    i.name,
                    i.description,
                    for (final f in i.fields) ...[f.name, f.description],
                  ].join('\n').toLowerCase().contains(needle),
            )
            .toList()
          ..sort((a, b) {
            final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
            final result = name == 0 ? a.id.compareTo(b.id) : name;
            return sortDescending ? -result : result;
          });
    if (focusItemId != null) {
      final index = matches.indexWhere((i) => i.id == focusItemId);
      if (index >= 0) offset = index ~/ limit * limit;
    }
    final lastOffset = matches.isEmpty
        ? 0
        : (matches.length - 1) ~/ limit * limit;
    offset = min(offset, lastOffset);
    return InformationPage(
      matches.skip(offset).take(limit),
      matches.length,
      offset,
      limit,
    );
  }

  /// One owner transaction for the form. No Agent session or proposal is created.
  Future<InformationItem> editInformation(
    String itemId,
    int expectedVersion, {
    required String name,
    required String description,
    String? directoryId,
    Iterable<String> tagIds = const [],
    List<FieldChange> changes = const [],
    Map<String, String> fieldDescriptions = const {},
  }) => _serialize(() async {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final before = information.where((i) => i.id == itemId).firstOrNull;
    if (before == null || before.version != expectedVersion) {
      throw const AccessFailure('information_conflict');
    }
    _checkOrganizationName(name);
    _checkParent(directoryId);
    final selectedTags = tagIds.toSet();
    if (selectedTags.length > 100 ||
        selectedTags.any((id) => !tags.any((t) => t.id == id)) ||
        fieldDescriptions.length > 200 ||
        fieldDescriptions.values.any((d) => d.length > 2000)) {
      throw const AccessFailure('invalid_information');
    }
    final updated = _applyUpdate(
      before,
      UpdateInput(
        itemId,
        expectedVersion,
        changes,
        name: name,
        description: description,
      ),
    );
    if (fieldDescriptions.keys.any(
      (id) => !updated.fields.any((f) => f.id == id),
    )) {
      throw const AccessFailure('invalid_information');
    }
    final item = InformationItem(
      updated.id,
      updated.name,
      updated.description,
      updated.version,
      [
        for (final field in updated.fields)
          if (fieldDescriptions.containsKey(field.id) &&
              fieldDescriptions[field.id] != field.description)
            field.withMetadata(
              description: fieldDescriptions[field.id]!,
              version: field.version + 1,
            )
          else
            field,
      ],
      directoryId: directoryId,
      tagIds: selectedTags,
      createdAt: updated.createdAt,
      modifiedAt: updated.modifiedAt,
    );
    final removed = before.fields.any(
      (f) => !item.fields.any((n) => n.id == f.id),
    );
    final recycled = removed ? _recycle(before, item) : null;
    await _service._repository.commitRecycleChange(
      itemId: item.id,
      item: item,
      previous: InformationRevision(before, _service._clock()),
      entries: recycled == null ? const [] : [recycled],
      facts: recycled == null
          ? const []
          : [_fact(recycled, RecycleFactKind.deleted, item.version)],
    );
    _invalidateRemoved(before, item);
    return item;
  });
}
