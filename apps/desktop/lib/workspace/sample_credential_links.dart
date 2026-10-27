import 'workspace_records.dart';

/// One source of credential↔information membership. UI relations are projections.
class SampleCredentialLinks {
  final _links = <WorkspaceRecordRef, Set<WorkspaceRecordRef>>{};
  final _initial = <WorkspaceRecordRef, Set<WorkspaceRecordRef>>{};
  Map<WorkspaceRecordRef, Set<WorkspaceRecordRef>> capturePortable() =>
      Map.unmodifiable({
        for (final e in _links.entries)
          e.key: Set<WorkspaceRecordRef>.unmodifiable(e.value),
      });
  void installPortable(
    Map<WorkspaceRecordRef, Set<WorkspaceRecordRef>> values,
  ) {
    _links
      ..clear()
      ..addAll({for (final e in values.entries) e.key: Set.of(e.value)});
  }

  Iterable<WorkspaceRecordRef> information(WorkspaceRecordRef credential) =>
      List.unmodifiable(_links[credential] ?? {});
  Iterable<WorkspaceRecordRef> credentials(WorkspaceRecordRef information) =>
      List.unmodifiable(
        _links.entries
            .where((e) => e.value.contains(information))
            .map((e) => e.key),
      );
  void seed(
    WorkspaceRecordRef credential,
    Iterable<WorkspaceRecordRef> information,
  ) {
    final values = _links.putIfAbsent(credential, () => {});
    values.addAll(information);
    _initial[credential] = Set.of(values);
  }

  Set<WorkspaceRecordRef> replaceCredential(
    WorkspaceRecordRef credential,
    Iterable<WorkspaceRecordRef> values,
  ) {
    final old = Set.of(information(credential)), next = values.toSet();
    _links[credential] = next;
    return {...old.difference(next), ...next.difference(old)};
  }

  Set<WorkspaceRecordRef> replaceInformation(
    WorkspaceRecordRef info,
    Iterable<WorkspaceRecordRef> values,
  ) {
    final old = credentials(info).toSet(), next = values.toSet();
    for (final credential in old.union(next)) {
      final links = _links.putIfAbsent(credential, () => {});
      if (next.contains(credential)) {
        links.add(info);
      } else {
        links.remove(info);
      }
    }
    return {...old.difference(next), ...next.difference(old)};
  }

  void forgetInformation(WorkspaceRecordRef info) {
    for (final links in _links.values) {
      links.remove(info);
    }
  }

  void clearCurrent() => _links.clear();
  void reset() {
    _links
      ..clear()
      ..addAll({for (final e in _initial.entries) e.key: Set.of(e.value)});
  }

  void clear() {
    _links.clear();
    _initial.clear();
  }
}
