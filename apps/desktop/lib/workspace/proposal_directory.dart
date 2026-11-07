import 'package:flutter/material.dart';
import 'directory_picker.dart';
import 'library_widgets.dart';
import 'workspace_source.dart';
export 'directory_picker.dart' show DirectorySelection;

String proposalDirectoryId(String path) =>
    'review-directory:${path.split('/').map((p) => p.trim().toLowerCase()).join('/')}';
WorkspaceCatalog proposalDirectoryCatalog(
  WorkspaceCatalog catalog,
  Iterable<WorkspaceProposalItemReview> reviews,
) {
  final dirs = List<WorkspaceDirectory>.of(catalog.directories);
  for (final review in reviews) {
    if (review.suggestedDirectory.isEmpty) continue;
    String? parent;
    final parts = review.suggestedDirectory
        .split('/')
        .map((p) => p.trim())
        .toList();
    for (var i = 0; i < parts.length; i++) {
      final existing = dirs
          .where(
            (d) =>
                d.parentId == parent &&
                d.name.toLowerCase() == parts[i].toLowerCase(),
          )
          .firstOrNull;
      if (existing != null) {
        parent = existing.id;
        continue;
      }
      final id = proposalDirectoryId(parts.take(i + 1).join('/'));
      dirs.add(
        WorkspaceDirectory(id, parts[i], parentId: parent, proposed: true),
      );
      parent = id;
    }
  }
  return WorkspaceCatalog(
    directories: dirs,
    tags: catalog.tags,
    types: catalog.types,
    creatableTypes: catalog.creatableTypes,
    directoryCounts: catalog.directoryCounts,
    tagCounts: catalog.tagCounts,
    version: catalog.version,
    recycledCount: catalog.recycledCount,
  );
}

String? proposalReviewDirectory(
  WorkspaceCatalog catalog,
  WorkspaceProposalItemReview review,
) {
  if (review.suggestedDirectory.isEmpty) return review.directoryId;
  final path = review.suggestedDirectory
      .split('/')
      .map((p) => p.trim().toLowerCase())
      .join('/');
  return catalog.directories
      .where(
        (d) =>
            directoryPath(
              catalog,
              d.id,
            ).split('/').map((p) => p.trim().toLowerCase()).join('/') ==
            path,
      )
      .firstOrNull
      ?.id;
}

class ProposalDirectoryLocation extends StatelessWidget {
  const ProposalDirectoryLocation({
    super.key,
    required this.catalog,
    required this.directoryId,
    this.beforeId,
    this.compare = false,
    this.allowNew = false,
    this.suggestedPath = '',
    this.onChanged,
  });
  final WorkspaceCatalog catalog;
  final String? directoryId, beforeId;
  final bool compare, allowNew;
  final String suggestedPath;
  final ValueChanged<DirectorySelection>? onChanged;
  @override
  Widget build(BuildContext context) {
    final directory = catalog.directories
        .where((d) => d.id == directoryId)
        .firstOrNull;
    final path = directory == null
        ? <WorkspaceDirectory>[]
        : libraryDirectoryAncestors(catalog, directory);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('存放目录', style: libraryText(context, 13)),
          const SizedBox(height: 4),
          if (compare && beforeId != directoryId)
            Text(
              '修改前：${directoryPath(catalog, beforeId)}',
              style: libraryText(context, 13),
            ),
          SelectableText(
            directoryPath(catalog, directoryId),
            style: libraryText(context, 15),
          ),
          if (path.any((d) => d.proposed))
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final d in path)
                  Text(
                    '${d.name} · ${d.proposed ? '将新建' : '已有'}',
                    style: libraryText(context, 12),
                  ),
              ],
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                final selected = await showDirectoryPicker(
                  context,
                  catalog,
                  selected: directoryId,
                  readOnly: onChanged == null,
                  allowNew: allowNew,
                  initialPath: suggestedPath.isNotEmpty
                      ? suggestedPath
                      : directoryId == null
                      ? ''
                      : directoryPath(catalog, directoryId),
                );
                if (context.mounted && selected != null) {
                  onChanged?.call(selected);
                }
              },
              child: Text(onChanged == null ? '查看完整目录树' : '查看目录树 / 更换位置'),
            ),
          ),
        ],
      ),
    );
  }
}

class ProposalDirectorySummary extends StatelessWidget {
  const ProposalDirectorySummary({
    super.key,
    required this.catalog,
    required this.reviews,
  });
  final WorkspaceCatalog catalog;
  final List<WorkspaceProposalItemReview> reviews;
  @override
  Widget build(BuildContext context) {
    final displayCatalog = proposalDirectoryCatalog(catalog, reviews);
    final ids = <String>{};
    for (final review in reviews) {
      final directory = displayCatalog.directories
          .where((d) => d.id == proposalReviewDirectory(displayCatalog, review))
          .firstOrNull;
      if (directory == null) continue;
      ids.addAll(
        libraryDirectoryAncestors(
          displayCatalog,
          directory,
        ).where((d) => d.proposed).map((d) => d.id),
      );
    }
    if (ids.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      title: Text('本提案将新建 ${ids.length} 个目录'),
      subtitle: const Text('随整份提案一起保存，现在尚未创建。'),
      children: [
        for (final d in libraryDirectoryTree(
          displayCatalog,
        ).where((d) => ids.contains(d.id)))
          ListTile(title: Text(directoryPath(displayCatalog, d.id))),
      ],
    );
  }
}
