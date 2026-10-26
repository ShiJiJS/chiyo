import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_motion.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'plugin_dialogs.dart';
import 'plugin_widgets.dart';
import 'plugins_controller.dart';
import 'workspace_source.dart';

/// Settings owns this entry; no package gets an everyday navigation destination.
class PluginsPage extends StatefulWidget {
  const PluginsPage({
    super.key,
    required this.controller,
    required this.onRetry,
    required this.onCreate,
    required this.onRecords,
    this.picker,
    this.onModalChanged,
  });
  final PluginsController controller;
  final WorkspacePluginPicker? picker;
  final VoidCallback onRetry;
  final ValueChanged<WorkspaceType> onCreate, onRecords;
  final ValueChanged<bool>? onModalChanged;
  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  late final ScrollController _detailScroll;
  late (String?, PluginTab, String?) _shown;
  PluginsController get model => widget.controller;
  @override
  void initState() {
    super.initState();
    _detailScroll = ScrollController(initialScrollOffset: model.scrollOffset)
      ..addListener(() {
        if (_detailScroll.hasClients) model.scrollOffset = _detailScroll.offset;
      });
    _shown = (model.selection, model.tab, model.templateId);
    model.addListener(_syncSelection);
  }

  void _syncSelection() {
    final next = (model.selection, model.tab, model.templateId);
    if (_shown == next) return;
    _shown = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _detailScroll.hasClients && _shown == next) {
        _detailScroll.jumpTo(0);
      }
    });
  }

  @override
  void dispose() {
    model.removeListener(_syncSelection);
    _detailScroll.dispose();
    super.dispose();
  }

  void _top() {
    if (_detailScroll.hasClients) _detailScroll.jumpTo(0);
  }

  Future<void> _operation(WorkspacePluginAction action) async {
    widget.onModalChanged?.call(true);
    try {
      final result = action == WorkspacePluginAction.install
          ? await showPluginInstall(context, model.source, widget.picker)
          : await showPluginMaintenance(
              context,
              model.source,
              model.selected!,
              action,
            );
      if (!mounted || result == null) return;
      await model.load();
      if (mounted && action == WorkspacePluginAction.install) {
        model.setFilter(PluginFilter.all);
        model.select(result.packageId);
        _top();
      }
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  Widget _list(BuildContext context) {
    final c = UiPalette.of(context);
    return ColoredBox(
      color: c.rail,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 20),
        children: [
          Text('已安装', style: libraryText(context, 17, weight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            model.catalog == null
                ? (model.loading ? '正在读取…' : '暂不可用')
                : '${model.catalog!.packages.length}个插件',
            style: libraryText(context, 12, color: c.muted),
          ),
          const SizedBox(height: 14),
          DesktopSelect<PluginFilter>(
            key: const ValueKey('plugin-filter'),
            value: model.filter,
            items: [
              for (final f in PluginFilter.values)
                DropdownMenuItem(value: f, child: Text(f.label)),
            ],
            onChanged: (v) {
              _top();
              model.setFilter(v!);
            },
          ),
          const SizedBox(height: 12),
          for (final p in model.visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: DesktopButton(
                key: ValueKey('plugin-select-${p.id}'),
                kind: DesktopButtonKind.quiet,
                selected: model.selection == p.id,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 16,
                ),
                onPressed: () {
                  _top();
                  model.select(p.id);
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RecordIcon(p.templates.first.type, size: 33),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            p.name,
                            style: libraryText(
                              context,
                              14,
                              weight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            p.description,
                            style: libraryText(context, 12, color: c.muted),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${p.builtin ? '内置' : '本地安装'} · v${p.version} · ${p.enabled ? '已启用' : '已停用'}',
                            style: libraryText(context, 12, color: c.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (model.catalog != null && model.visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                '没有这个状态的插件。',
                style: libraryText(context, 13, color: c.muted),
              ),
            ),
          const SizedBox(height: 20),
          Text(
            '普通信息、文档、文件和凭据无需安装插件。',
            style: libraryText(context, 12, color: c.muted),
          ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context) {
    final p = model.selected,
        c = UiPalette.of(context),
        template = model.selectedTemplate;
    final ready = !model.loading && model.failure == null;
    if (p == null || template == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            model.loading
                ? '正在读取插件…'
                : model.failure != null
                ? '插件详情暂不可用，请重新读取。'
                : model.catalog?.packages.isEmpty == true
                ? '还没有安装插件。'
                : '选择一个插件查看模板与来源。',
            style: libraryText(context, 15, color: c.muted),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      controller: _detailScroll,
      primary: false,
      padding: const EdgeInsets.all(24),
      child: DesktopEntrance(
        key: ValueKey('plugin-detail-${p.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 16,
              runSpacing: 16,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RecordIcon(template.type, size: 47),
                    const SizedBox(width: 14),
                    Flexible(
                      child: Text(
                        p.name,
                        key: const ValueKey('plugin-selected-title'),
                        style: libraryText(
                          context,
                          24,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                DesktopButton(
                  key: const ValueKey('plugin-toggle'),
                  onPressed: ready
                      ? () => _operation(
                          p.enabled
                              ? WorkspacePluginAction.disable
                              : WorkspacePluginAction.enable,
                        )
                      : null,
                  child: Text(p.enabled ? '停用' : '启用'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              p.description,
              style: libraryText(context, 14, color: c.muted),
            ),
            const SizedBox(height: 10),
            Text(
              '${p.author} · ${p.builtin ? '内置' : '本地安装'} · v${p.version} · ${p.enabled ? '已启用' : '已停用'}',
              style: libraryText(context, 13, color: c.muted),
            ),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 22),
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: c.line),
                  bottom: BorderSide(color: c.line),
                ),
              ),
              child: Wrap(
                spacing: 30,
                runSpacing: 14,
                children: [
                  _fact(context, '提供模板', '${p.templates.length}个'),
                  _fact(context, '已用于', '${p.affectedRecords}项资料'),
                  _fact(context, '目录归属', '由每份资料自行选择'),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.line)),
              ),
              child: Wrap(
                spacing: 18,
                runSpacing: 8,
                children: [
                  for (final tab in PluginTab.values)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: model.tab == tab
                                ? c.accent
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: DesktopButton(
                        key: ValueKey('plugin-tab-${tab.name}'),
                        kind: DesktopButtonKind.quiet,
                        onPressed: () {
                          _top();
                          model.setTab(tab);
                        },
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          tab.label,
                          style: libraryText(
                            context,
                            14,
                            color: model.tab == tab ? c.accent : c.muted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            if (p.templates.length > 1) ...[
              DesktopSelect<String>(
                value: template.id,
                items: [
                  for (final t in p.templates)
                    DropdownMenuItem(value: t.id, child: Text(t.type.name)),
                ],
                onChanged: (id) {
                  _top();
                  model.selectTemplate(id!);
                },
              ),
              const SizedBox(height: 18),
            ],
            if (model.tab == PluginTab.instructions) ...[
              Text(
                '随插件提供的说明',
                style: libraryText(context, 17, weight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              SelectableText(
                template.definition['instructions'] as String? ?? '暂无录入说明。',
                style: libraryText(context, 14, height: 1.9),
              ),
              const SizedBox(height: 18),
              Text(
                '录入说明为来源资料，不替代访问申请与主人确认。',
                style: libraryText(context, 13, color: c.muted),
              ),
            ] else ...[
              if (model.tab == PluginTab.preview) ...[
                Wrap(
                  spacing: 14,
                  runSpacing: 12,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      template.type.name,
                      style: libraryText(context, 18, weight: FontWeight.w600),
                    ),
                    DesktopButton(
                      key: const ValueKey('plugin-create'),
                      kind: DesktopButtonKind.primary,
                      onPressed: ready && p.enabled
                          ? () => widget.onCreate(template.type)
                          : null,
                      child: const Text('用这个模板添加'),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
              ],
              PluginTemplatePreview(
                template: template,
                structure: model.tab == PluginTab.structure,
              ),
            ],
            const SizedBox(height: 18),
            DesktopButton(
              key: const ValueKey('plugin-records'),
              kind: DesktopButtonKind.quiet,
              alignment: Alignment.centerLeft,
              onPressed: () => widget.onRecords(template.type),
              child: const Text('查看使用此模板的资料 →'),
            ),
            const SizedBox(height: 22),
            Text('来源', style: libraryText(context, 13, color: c.muted)),
            const SizedBox(height: 6),
            SelectableText(
              '${p.origin}\nSHA256 ${p.digest}',
              style: libraryText(context, 12, color: c.muted),
            ),
            Container(
              margin: const EdgeInsets.only(top: 24),
              padding: const EdgeInsets.only(top: 17),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '停用或移除插件，已有资料仍可查看和编辑。',
                    style: libraryText(context, 12, color: c.muted),
                  ),
                  if (!p.builtin)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DesktopButton(
                        key: const ValueKey('plugin-remove'),
                        kind: DesktopButtonKind.quiet,
                        onPressed: ready
                            ? () => _operation(WorkspacePluginAction.remove)
                            : null,
                        child: const Text('移除插件'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fact(BuildContext context, String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: libraryText(context, 12, color: UiPalette.of(context).muted),
      ),
      const SizedBox(height: 4),
      Text(value, style: libraryText(context, 14, weight: FontWeight.w500)),
    ],
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final c = UiPalette.of(context);
      return LayoutBuilder(
        builder: (context, bounds) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: bounds.maxWidth <= 1300 ? 220 : 250,
              padding: const EdgeInsets.fromLTRB(18, 26, 18, 20),
              decoration: BoxDecoration(
                color: c.rail,
                border: Border(right: BorderSide(color: c.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '设置',
                    style: libraryText(context, 24, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 24),
                  DesktopButton(
                    selected: true,
                    alignment: Alignment.centerLeft,
                    leading: const PrototypeIcon(PrototypeIconGlyph.plugin),
                    onPressed: () {
                      _top();
                      model.setFilter(PluginFilter.all);
                    },
                    child: const Text('插件'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  bounds.maxWidth <= 1300 ? 18 : 24,
                  22,
                  bounds.maxWidth <= 1300 ? 18 : 24,
                  18,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 16,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '插件',
                          style: libraryText(
                            context,
                            26,
                            weight: FontWeight.w600,
                          ),
                        ),
                        DesktopButton(
                          key: const ValueKey('plugin-install'),
                          kind: DesktopButtonKind.primary,
                          leading: const PrototypeIcon(PrototypeIconGlyph.plus),
                          onPressed:
                              widget.picker == null ||
                                  model.loading ||
                                  model.failure != null
                              ? null
                              : () => _operation(WorkspacePluginAction.install),
                          child: const Text('安装插件包'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '管理资料模板。已有资料始终由信息库保存。',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                    const SizedBox(height: 18),
                    if (model.failure case final failure?) ...[
                      PluginFailureView(failure),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: DesktopButton(
                          onPressed: widget.onRetry,
                          child: const Text('重新读取插件'),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ] else if (model.loading)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('正在刷新插件…'),
                      ),
                    Expanded(
                      child: Container(
                        key: const ValueKey('plugin-workspace'),
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: c.paper,
                          border: Border.all(color: c.line),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: bounds.maxWidth <= 1300 ? 200 : 225,
                              child: _list(context),
                            ),
                            VerticalDivider(
                              width: 1,
                              thickness: 1,
                              color: c.line,
                            ),
                            Expanded(child: _detail(context)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
