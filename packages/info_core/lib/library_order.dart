part of 'info_core.dart';

class LibraryEntryRef {
  const LibraryEntryRef(this.kind, this.id);
  final String kind, id;
  List<String> toJson() => [kind, id];
  @override
  bool operator ==(Object other) =>
      other is LibraryEntryRef && kind == other.kind && id == other.id;
  @override
  int get hashCode => Object.hash(kind, id);
}

/// Identity-only ordering preferences. Missing identities remain as positions
/// for recycled content; they never cause a record or directory to reappear.
/// Membership comes exclusively from the current library, not these lists.
class LibraryOrderSnapshot {
  LibraryOrderSnapshot({
    required this.revision,
    required Iterable<String> directories,
    required Iterable<LibraryEntryRef> records,
  }) : directories = List.unmodifiable(directories),
       records = List.unmodifiable(records) {
    bool valid(String id) =>
        id.isNotEmpty && id.length <= 200 && !id.contains('\u0000');
    if (revision < 1 ||
        this.directories.length + this.records.length > 200000 ||
        this.directories.any((id) => !valid(id)) ||
        this.records.any(
          (r) =>
              !{'information', 'credential'}.contains(r.kind) || !valid(r.id),
        ) ||
        this.directories.toSet().length != this.directories.length ||
        this.records.toSet().length != this.records.length) {
      throw const FormatException('Invalid library order');
    }
  }
  final int revision;
  final List<String> directories;
  final List<LibraryEntryRef> records;
  Map<String, Object?> toJson() => {
    'format': 1,
    'revision': revision,
    'directories': directories,
    'records': records.map((r) => r.toJson()).toList(),
  };
  factory LibraryOrderSnapshot.fromJson(Map<String, dynamic> json) {
    try {
      if (json.length != 4 || json['format'] != 1) {
        throw const FormatException();
      }
      return LibraryOrderSnapshot(
        revision: json['revision'] as int,
        directories: (json['directories'] as List).cast<String>(),
        records: [
          for (final row in json['records'] as List)
            (() {
              final r = row as List;
              if (r.length != 2) throw const FormatException();
              return LibraryEntryRef(r[0] as String, r[1] as String);
            })(),
        ],
      );
    } on Object {
      throw const FormatException('Invalid library order');
    }
  }
  late final String digest = sha256
      .convert(utf8.encode(jsonEncode(toJson())))
      .toString();
}

abstract interface class LibraryOrderRepository {
  LibraryOrderSnapshot? get libraryOrder;
}

/// Placement is relative to one current sibling, never an index into a partial
/// page/search result. The target parent is separately validated by the move.
class LibraryMovePosition {
  const LibraryMovePosition(this.anchor, {this.after = false});
  final LibraryEntryRef anchor;
  final bool after;
  Map<String, Object?> toJson() => {'anchor': anchor.toJson(), 'after': after};
}

List<T> _completeLibraryOrder<T>(Iterable<T> saved, Iterable<T> current) =>
    {...saved, ...current}.toList();

extension OwnerLibraryOrder on OwnerAccess {
  bool get libraryOrderSupported =>
      _service._repository is LibraryOrderRepository;
  LibraryOrderSnapshot? get _savedLibraryOrder =>
      _service._repository is LibraryOrderRepository
      ? (_service._repository as LibraryOrderRepository).libraryOrder
      : null;
  int get libraryOrderRevision => _savedLibraryOrder?.revision ?? 0;
  List<InformationDirectory> _orderedLibraryDirectories() {
    final current = {for (final d in _service._repository.directories) d.id: d};
    return List.unmodifiable([
      for (final id in _completeLibraryOrder(
        _savedLibraryOrder?.directories ?? const <String>[],
        current.keys,
      ))
        if (current[id] != null) current[id]!,
    ]);
  }

  List<LibraryEntryRef> get libraryRecordsInOrder {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final current = {
      for (final i in information) LibraryEntryRef('information', i.id),
      for (final c in _classificationCredentials)
        LibraryEntryRef('credential', c.id),
    };
    return List.unmodifiable(
      _completeLibraryOrder(
        _savedLibraryOrder?.records ?? const <LibraryEntryRef>[],
        current,
      ).where(current.contains),
    );
  }

  LibraryOrderSnapshot _captureLibraryOrder({
    Iterable<InformationDirectory> additionalDirectories = const [],
    Iterable<InformationItem> additionalItems = const [],
    Iterable<ManagedCredential> additionalCredentials = const [],
  }) => LibraryOrderSnapshot(
    revision: libraryOrderRevision + 1,
    directories: _completeLibraryOrder(
      _savedLibraryOrder?.directories ?? const <String>[],
      [
        for (final d in _service._repository.directories) d.id,
        for (final d in additionalDirectories) d.id,
      ],
    ),
    records: _completeLibraryOrder(
      _savedLibraryOrder?.records ?? const <LibraryEntryRef>[],
      [
        for (final i in [...information, ...additionalItems])
          LibraryEntryRef('information', i.id),
        for (final c in [
          ..._classificationCredentials,
          ...additionalCredentials,
        ])
          LibraryEntryRef('credential', c.id),
      ],
    ),
  );

  LibraryOrderSnapshot _placedLibraryOrder({
    required Iterable<String> directoryIds,
    required Iterable<LibraryEntryRef> recordRefs,
    required String? targetId,
    LibraryMovePosition? position,
    LibraryOrderSnapshot? captured,
    Iterable<InformationDirectory> additionalDirectories = const [],
    Iterable<InformationItem> additionalItems = const [],
    Iterable<ManagedCredential> additionalCredentials = const [],
  }) {
    final snapshot = captured ?? _captureLibraryOrder();
    List<T> place<T>(List<T> order, Set<T> moving, Set<T> siblings, T? anchor) {
      if (moving.isEmpty) return order;
      final selected = order.where(moving.contains).toList();
      final remaining = order.where((r) => !moving.contains(r)).toList();
      final index = anchor == null
          ? remaining.lastIndexWhere(siblings.contains) + 1
          : remaining.indexOf(anchor) + (position!.after ? 1 : 0);
      // A parent with no current siblings appends to the saved identity list.
      remaining.insertAll(
        anchor == null && index == 0 ? remaining.length : index,
        selected,
      );
      return remaining;
    }

    final rootIds = directoryIds.toSet(), records = recordRefs.toSet();
    final allDirectories = {
      for (final d in [...directories, ...additionalDirectories]) d.id: d,
    };
    final allItems = {
      for (final i in [...information, ...additionalItems]) i.id: i,
    };
    final allCredentials = {
      for (final c in [..._classificationCredentials, ...additionalCredentials])
        c.id: c,
    };
    return LibraryOrderSnapshot(
      revision: snapshot.revision,
      directories: place(snapshot.directories, rootIds, {
        for (final d in allDirectories.values)
          if (d.parentId == targetId) d.id,
      }, position?.anchor.kind == 'directory' ? position!.anchor.id : null),
      records: place(
        snapshot.records,
        records,
        {
          for (final i in allItems.values)
            if (i.directoryId == targetId) LibraryEntryRef('information', i.id),
          for (final c in allCredentials.values)
            if (c.directoryId == targetId) LibraryEntryRef('credential', c.id),
        },
        position != null && position.anchor.kind != 'directory'
            ? position.anchor
            : null,
      ),
    );
  }
}
