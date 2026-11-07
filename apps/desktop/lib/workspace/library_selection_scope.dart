import 'package:flutter/material.dart';
import 'directory_tree.dart';
import 'workspace_source.dart';

List<WorkspaceDirectory> orderedLibrarySelectionDirectories(
  WorkspaceLibraryRecyclePreview p,
  WorkspaceCatalog? catalog,
) {
  final ids = p.directories.map((d) => d.id).toSet();
  final all = <String, WorkspaceDirectory>{
    for (final d in catalog?.directories ?? <WorkspaceDirectory>[]) d.id: d,
    for (final d in p.directories) d.id: d,
  };
  final ordered = libraryDirectoryTree(
    WorkspaceCatalog(directories: all.values, tags: const [], types: const []),
  ).where((d) => ids.contains(d.id)).toList();
  final seen = ordered.map((d) => d.id).toSet();
  return [...ordered, ...p.directories.where((d) => !seen.contains(d.id))];
}

class LibrarySelectionScope extends StatelessWidget {
  const LibrarySelectionScope({
    super.key,
    required this.preview,
    this.catalog,
    this.listKey = const ValueKey('batch-recycle-scope'),
  });
  final WorkspaceLibraryRecyclePreview preview;
  final WorkspaceCatalog? catalog;
  final Key listKey;
  @override
  Widget build(BuildContext context) {
    final dirs = orderedLibrarySelectionDirectories(preview, catalog);
    final p = preview;
    return ExpansionTile(
      title: const Text('查看完整范围'),
      children: [
        SizedBox(
          height: 280,
          child: ListView.builder(
            key: listKey,
            itemCount: dirs.length + p.records.length,
            itemBuilder: (context, index) {
              if (index < dirs.length) {
                final d = dirs[index];
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(d.name),
                  subtitle: Text(
                    '目录 · ${(p.paths[d.id] ?? [d.name]).join(' / ')}',
                  ),
                );
              }
              final r = p.records[index - dirs.length];
              return ListTile(
                title: Text(r.name),
                subtitle: Text(
                  '${r.type} · ${r.path.isEmpty ? '未分类' : r.path.join(' / ')}',
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
