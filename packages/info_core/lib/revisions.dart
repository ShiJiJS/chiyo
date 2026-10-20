import 'information.dart';
import 'update_proposals.dart';

/// Owner-only comparison. Missing fields require an explicit recycle restore.
class RevisionPreview {
  RevisionPreview(this.revision, this.current, this.restored)
    : changes = List.unmodifiable([
        for (final id in {
          ...current.fields.map((f) => f.id),
          ...restored.fields.map((f) => f.id),
        })
          if (!_same(
            current.fields.where((f) => f.id == id).firstOrNull,
            restored.fields.where((f) => f.id == id).firstOrNull,
          ))
            RevisionFieldChange(
              current.fields.where((f) => f.id == id).firstOrNull,
              restored.fields.where((f) => f.id == id).firstOrNull,
            ),
      ]);
  final InformationRevision revision;
  final InformationItem current, restored;
  final List<RevisionFieldChange> changes;
  List<InformationField> get missingFields => restored.fields
      .where((f) => !current.fields.any((c) => c.id == f.id))
      .toList();
  bool get requiresRecycleRestore => missingFields.isNotEmpty;
  static bool _same(InformationField? a, InformationField? b) =>
      a != null &&
      b != null &&
      a.id == b.id &&
      a.name == b.name &&
      a.description == b.description &&
      a.hasSameContent(b);
}

class RevisionFieldChange {
  const RevisionFieldChange(this.before, this.after);
  final InformationField? before, after;
}

/// Content-free deletion fact for later synchronization of retention cleanup.
class RevisionPurgeFact {
  const RevisionPurgeFact(this.itemId, this.version, this.purgedAt);
  final String itemId;
  final int version;
  final DateTime purgedAt;
}
