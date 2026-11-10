import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'workspace_plugins.dart';
import 'workspace_records.dart';

sealed class LibraryCreateChoice {
  const LibraryCreateChoice();
}

final class LibraryCreateTemplate extends LibraryCreateChoice {
  const LibraryCreateTemplate(this.type);
  final WorkspaceType type;
}

final class LibraryCreatePlugins extends LibraryCreateChoice {
  const LibraryCreatePlugins();
}

/// Package metadata adds descriptions without hiding available content forms
/// when that metadata is temporarily unavailable.
class LibraryCreateDialog extends StatefulWidget {
  const LibraryCreateDialog({
    super.key,
    required this.catalog,
    required this.plugins,
    this.directoryId,
    this.canOpenPlugins = true,
  });
  final WorkspaceCatalog catalog;
  final WorkspacePluginSource plugins;
  final String? directoryId;
  final bool canOpenPlugins;
  @override
  State<LibraryCreateDialog> createState() => _LibraryCreateDialogState();
}

class _LibraryCreateDialogState extends State<LibraryCreateDialog> {
  static const _core = ['generic', 'document', 'file', 'credential'];
  late Future<WorkspacePluginCatalog> _metadata;
  @override
  void initState() {
    super.initState();
    _metadata = widget.plugins.load();
  }

  void _choose(WorkspaceType type) =>
      Navigator.pop(context, LibraryCreateTemplate(type));

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final types = widget.catalog.creatableTypes;
    final directory =
        widget.catalog.directories
            .where((d) => d.id == widget.directoryId)
            .firstOrNull
            ?.name ??
        '未分类';
    return DesktopDialog(
      title: const Text('添加资料'),
      content: FutureBuilder<WorkspacePluginCatalog>(
        future: _metadata,
        builder: (context, snapshot) {
          final descriptions = {
            for (final package
                in snapshot.data?.packages ?? <WorkspacePlugin>[])
              if (package.enabled)
                for (final template in package.templates)
                  template.type.id:
                      template.definition['description'] as String? ??
                      '记录${(template.definition['fields'] as List? ?? []).take(3).map((f) => f['label']).join('、')}。',
          };
          final core = [
            for (final id in _core) ...types.where((type) => type.id == id),
          ];
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 20.8),
                child: Wrap(
                  key: const ValueKey('library-create-intro'),
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      '选择资料的内容形式。',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                    Text(
                      '保存到 $directory',
                      style: libraryText(context, 12, color: c.accent),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 17),
              if (snapshot.connectionState != ConnectionState.done)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    '正在读取模板说明…',
                    style: libraryText(context, 13, color: c.muted),
                  ),
                ),
              if (snapshot.hasError)
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    Text(
                      '模板说明暂不可用，仍可选择内容形式。',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                    DesktopButton(
                      key: const ValueKey('library-create-retry'),
                      onPressed: () => setState(() {
                        _metadata = widget.plugins.load();
                      }),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              for (final type in types.where((t) => !_core.contains(t.id)))
                Container(
                  key: ValueKey('library-new-type-${type.id}'),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.line)),
                  ),
                  child: DesktopButton(
                    kind: DesktopButtonKind.quiet,
                    hoverBackgroundColor: c.selected,
                    radius: 6,
                    minimumSize: const Size(0, 83.4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 16,
                    ),
                    onPressed: () => _choose(type),
                    child: Row(
                      children: [
                        RecordIcon(type, size: 37, glyphSize: 23),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                type.name,
                                style: libraryText(
                                  context,
                                  15,
                                  weight: FontWeight.w700,
                                ),
                              ),
                              if (descriptions[type.id]?.isNotEmpty ??
                                  false) ...[
                                const SizedBox(height: 4),
                                Text(
                                  descriptions[type.id]!,
                                  style: libraryText(
                                    context,
                                    13,
                                    color: c.muted,
                                    height: 1.8,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 13),
                        SizedBox(
                          width: 16,
                          height: 19,
                          child: Center(
                            child: PrototypeIcon(
                              PrototypeIconGlyph.chev,
                              size: 16,
                              color: c.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (core.isNotEmpty) ...[
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth < 420
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 10) / 2;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final type in core)
                          SizedBox(
                            width: width,
                            child: DesktopButton(
                              key: ValueKey('library-new-type-${type.id}'),
                              hoverBackgroundColor: c.selected,
                              padding: const EdgeInsets.all(14),
                              alignment: Alignment.centerLeft,
                              onPressed: () => _choose(type),
                              child: Row(
                                children: [
                                  PrototypeIcon(
                                    switch (type.id) {
                                      'document' => PrototypeIconGlyph.book,
                                      'credential' => PrototypeIconGlyph.key,
                                      _ => PrototypeIconGlyph.file,
                                    },
                                    size: 19,
                                    color: c.ink,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          type.id == 'file'
                                              ? '普通文件'
                                              : type.name,
                                          style: libraryText(context, 14),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          switch (type.id) {
                                            'document' => '说明、笔记与长文',
                                            'file' => 'PDF、图片或其他附件',
                                            'credential' => '密码、Token 与密钥',
                                            _ => '没有专用模板的简短信息',
                                          },
                                          style: libraryText(
                                            context,
                                            12,
                                            color: c.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
              if (widget.canOpenPlugins) ...[
                const SizedBox(height: 18),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Text(
                      '其他资料结构可在',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                    DesktopButton(
                      key: const ValueKey('library-create-open-plugins'),
                      kind: DesktopButtonKind.quiet,
                      fontSize: 13,
                      minimumSize: const Size(0, 36.8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 8,
                      ),
                      onPressed: () =>
                          Navigator.pop(context, const LibraryCreatePlugins()),
                      child: Text(
                        '设置 · 插件',
                        style: libraryText(
                          context,
                          13,
                          color: c.muted,
                          weight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Text(
                      '中添加。',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
