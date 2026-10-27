import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'legacy_templates_controller.dart';
import 'plugin_dialogs.dart';
import 'workspace_source.dart';

class LegacyTemplatesPanel extends StatefulWidget {
  const LegacyTemplatesPanel({
    super.key,
    required this.controller,
    required this.plugins,
    this.onCreate,
    required this.onConverted,
    this.catalog,
    this.onModalChanged,
  });
  final LegacyTemplatesController controller;
  final WorkspacePluginSource plugins;
  final ValueChanged<WorkspaceLegacyTemplate>? onCreate;
  final ValueChanged<String> onConverted;
  final WorkspacePluginCatalog? catalog;
  final ValueChanged<bool>? onModalChanged;
  @override
  State<LegacyTemplatesPanel> createState() => _LegacyTemplatesPanelState();
}

class _LegacyTemplatesPanelState extends State<LegacyTemplatesPanel> {
  late final ScrollController _scroll;
  LegacyTemplatesController get model => widget.controller;
  String? _selection;
  @override
  void initState() {
    super.initState();
    _selection = model.selection;
    _scroll = ScrollController(initialScrollOffset: model.scrollOffset)
      ..addListener(() {
        if (_scroll.hasClients) model.scrollOffset = _scroll.offset;
      });
    model.addListener(_changed);
  }

  void _changed() {
    if (_selection == model.selection) return;
    _selection = model.selection;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _convert(WorkspaceLegacyTemplate template) async {
    widget.onModalChanged?.call(true);
    try {
      final result = await showPluginInstall(context, widget.plugins, () async {
        final fresh = await model.source.read(template.id);
        return model.source.prepareConversion(fresh.id, fresh.version);
      });
      if (mounted && result != null) widget.onConverted(result.packageId);
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final c = UiPalette.of(context), selected = model.selected;
      final converted = widget.catalog?.packages
          .where(
            (p) =>
                p.id == selected?.packageId &&
                p.legacySource?['version'] == selected?.version,
          )
          .firstOrNull;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (model.failure != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  Text(
                    model.failure!.message,
                    style: libraryText(context, 14, color: c.danger),
                  ),
                  DesktopButton(
                    key: const ValueKey('legacy-retry'),
                    onPressed: () => model.load(),
                    child: const Text('重新读取'),
                  ),
                ],
              ),
            ),
          if (model.loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('正在读取旧版模板…'),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 210,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      Text(
                        model.templates == null
                            ? '尚未读取'
                            : '${model.templates!.length}个旧版模板',
                        style: libraryText(context, 13, color: c.muted),
                      ),
                      const SizedBox(height: 12),
                      for (final t
                          in model.templates ?? <WorkspaceLegacyTemplate>[])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: DesktopButton(
                            key: ValueKey('legacy-select-${t.id}'),
                            kind: DesktopButtonKind.quiet,
                            selected: model.selection == t.id,
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.all(12),
                            onPressed: () => model.select(t.id),
                            child: Text(t.name),
                          ),
                        ),
                    ],
                  ),
                ),
                VerticalDivider(width: 1, thickness: 1, color: c.line),
                Expanded(
                  child: selected == null
                      ? Center(
                          child: Text(
                            model.templates?.isEmpty == true
                                ? '还没有旧版模板。'
                                : model.loading
                                ? '正在读取旧版模板…'
                                : '选择旧版模板查看结构。',
                          ),
                        )
                      : SingleChildScrollView(
                          controller: _scroll,
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                selected.name,
                                key: const ValueKey('legacy-title'),
                                style: libraryText(
                                  context,
                                  24,
                                  weight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                selected.description,
                                style: libraryText(context, 14, color: c.muted),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                '旧版录入辅助 · 第${selected.version}版 · ${selected.fields.length}个字段',
                                style: libraryText(context, 13, color: c.muted),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                '只提供空白字段，不含字段值。每次录入都会创建独立的资料和字段身份。',
                                style: libraryText(context, 13, color: c.muted),
                              ),
                              const SizedBox(height: 18),
                              for (final field in selected.fields)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(color: c.line),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        field.name,
                                        style: libraryText(
                                          context,
                                          14,
                                          weight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        field.description,
                                        style: libraryText(
                                          context,
                                          13,
                                          color: c.muted,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        switch (field.kind) {
                                          WorkspaceLegacyFieldKind.structured =>
                                            '文本',
                                          WorkspaceLegacyFieldKind.textNote =>
                                            '多行文本',
                                          WorkspaceLegacyFieldKind.file =>
                                            '普通附件 · 录入时选择',
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
                              const SizedBox(height: 20),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  DesktopButton(
                                    key: const ValueKey('legacy-create'),
                                    kind: DesktopButtonKind.primary,
                                    onPressed:
                                        model.loading ||
                                            model.failure != null ||
                                            widget.onCreate == null
                                        ? null
                                        : () => widget.onCreate!(selected),
                                    child: const Text('用旧版模板录入'),
                                  ),
                                  DesktopButton(
                                    key: const ValueKey('legacy-convert'),
                                    onPressed:
                                        model.loading ||
                                            model.failure != null ||
                                            selected.conversionProblem != null
                                        ? null
                                        : converted != null
                                        ? () => widget.onConverted(converted.id)
                                        : () => _convert(selected),
                                    child: Text(
                                      converted != null
                                          ? '查看已转换插件'
                                          : '转换为 local 插件',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              if (selected.conversionProblem case final reason?)
                                Text(
                                  reason,
                                  style: libraryText(
                                    context,
                                    13,
                                    color: c.warning,
                                  ),
                                )
                              else
                                Text(
                                  '转换先预览来源与结构，确认后才安装；已有资料和旧模板保持原样。',
                                  style: libraryText(
                                    context,
                                    13,
                                    color: c.muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
