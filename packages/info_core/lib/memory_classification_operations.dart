part of 'information.dart';

extension _MemoryClassification on MemoryInformationRepository {
  int _classificationVersion() {
    final dirs = _directories.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final tags = _tags.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    final fingerprint = jsonEncode([
      [
        for (final d in dirs) [d.id, d.name, d.parentId, d.version],
      ],
      [
        for (final t in tags) [t.id, t.name, t.version],
      ],
      [
        for (final c in _credentials.where((c) => c.deletedAt == null))
          [c.id, c.directoryId, c.tagIds],
      ],
    ]);
    if (_classificationFingerprint != fingerprint) {
      if (_classificationFingerprint != null) _classificationRevision++;
      _classificationFingerprint = fingerprint;
    }
    return _classificationRevision;
  }
}
