import 'workspace_records.dart';

const libraryVirtualDirectoryIds = {'all', 'unfiled'};

/// One tree order and one path label for browsing and all assignment forms.
List<WorkspaceDirectory> libraryDirectoryTree(WorkspaceCatalog catalog) {
  final ordered = <WorkspaceDirectory>[];
  final visited = <String>{};
  final children = <String?, List<WorkspaceDirectory>>{};
  for (final d in catalog.directories) {
    if (!libraryVirtualDirectoryIds.contains(d.id)) {
      children.putIfAbsent(d.parentId, () => []).add(d);
    }
  }
  ordered.addAll(catalog.directories.where((d) => d.id == 'all'));
  final pending = (children[null] ?? const <WorkspaceDirectory>[]).reversed
      .toList();
  while (pending.isNotEmpty) {
    final d = pending.removeLast();
    if (!visited.add(d.id)) continue;
    ordered.add(d);
    pending.addAll((children[d.id] ?? const <WorkspaceDirectory>[]).reversed);
  }
  ordered.addAll(catalog.directories.where((d) => d.id == 'unfiled'));
  return ordered;
}

List<WorkspaceDirectory> libraryDirectoryAncestors(
  WorkspaceCatalog catalog,
  WorkspaceDirectory directory,
) {
  final path = <WorkspaceDirectory>[directory];
  final visited = {directory.id};
  var parent = directory.parentId;
  while (parent != null && visited.add(parent)) {
    final d = catalog.directories.where((d) => d.id == parent).firstOrNull;
    if (d == null) break;
    path.insert(0, d);
    parent = d.parentId;
  }
  return path;
}

String directoryPath(WorkspaceCatalog catalog, String? id) {
  if (id == null) return '未分类';
  final directory = catalog.directories.where((d) => d.id == id).firstOrNull;
  if (directory == null) return '原目录已移除，请重新选择';
  return libraryDirectoryAncestors(
    catalog,
    directory,
  ).map((d) => d.name).join(' / ');
}
