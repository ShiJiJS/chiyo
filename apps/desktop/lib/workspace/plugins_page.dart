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
import 'host_settings.dart';
import 'legacy_templates_controller.dart';
import 'legacy_templates_panel.dart';
import 'plugin_authoring_guide.dart';

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
    this.hosts,
    this.hostChanges,
    this.onRecord,
    this.legacy,
    this.onLegacyCreate,
    this.embedded = false,
  });
  final PluginsController controller;
  final WorkspacePluginPicker? picker;
  final VoidCallback onRetry;
  final ValueChanged<WorkspaceType> onCreate, onRecords;
  final ValueChanged<bool>? onModalChanged;
  final WorkspaceHostSource? hosts;
  final Stream<WorkspaceRecordRef?>? hostChanges;
  final ValueChanged<WorkspaceRecordRef>? onRecord;
  final LegacyTemplatesController? legacy;
  final ValueChanged<WorkspaceLegacyTemplate>? onLegacyCreate;
  final bool embedded;
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
    _consumeHostRequest();
  }

  void _consumeHostRequest() {
    final target = model.takeHostRequest();
    if (target == null || widget.hosts == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openHost(target);
    });
  }

  Future<void> _openHost(WorkspaceHostTarget target) async {
    widget.onModalChanged?.call(true);
    try {
      await showHostIdentity(
        context,
        widget.hosts!,
        target,
        onRecord: widget.onRecord,
      );
    } finally {
      widget.onModalChanged?.call(false);
    }
  }

  void _syncSelection() {
    _consumeHostRequest();
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
      key: const ValueKey('plugin-sidebar'),
      color: c.rail,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已安装',
                    style: libraryText(
                      context,
                      17,
                      weight: FontWeight.w700,
                      height: 1.5,
                    ),
                  ),
                ),
                Text(
                  model.catalog == null
                      ? (model.loading ? '正在读取…' : '暂不可用')
                      : '${model.catalog!.packages.length} 个插件',
                  style: libraryText(context, 12, color: c.muted),
                ),
              ],
            ),
          ),
          Container(
            key: const ValueKey('plugin-filter'),
            margin: const EdgeInsets.fromLTRB(18, 0, 18, 15),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: c.nav,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                for (final f in PluginFilter.values)
                  Expanded(
                    child: DesktopButton(
                      key: ValueKey('plugin-filter-${f.name}'),
                      kind: DesktopButtonKind.quiet,
                      selected: model.filter == f,
                      selectedBackgroundColor: c.paper,
                      radius: 4,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 8,
                      ),
                      minimumSize: const Size(0, 0),
                      fontSize: 13,
                      onPressed: () {
                        _top();
                        model.setFilter(f);
                      },
                      child: Text(
                        f.label,
                        style: libraryText(
                          context,
                          13,
                          color: model.filter == f ? c.ink : c.muted,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 3, 10, 15),
              children: [
                for (final p in model.visible)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: DesktopButton(
                      key: ValueKey('plugin-select-${p.id}'),
                      kind: DesktopButtonKind.quiet,
                      tooltip: p.description,
                      selected: model.selection == p.id,
                      selectedBorder: true,
                      alignment: Alignment.centerLeft,
                      radius: 8,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 18,
                      ),
                      onPressed: () {
                        _top();
                        model.select(p.id);
                      },
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          RecordIcon(p.templates.first.type, size: 31),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  p.name,
                                  style: libraryText(
                                    context,
                                    15,
                                    weight: FontWeight.w600,
                                    color: model.selection == p.id
                                        ? c.accent
                                        : c.ink,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  '${p.builtin ? '内置' : '本地安装'} · v${p.version} · ${p.enabled ? '已启用' : '已停用'}',
                                  style: libraryText(
                                    context,
                                    12,
                                    color: c.muted,
                                    height: 1.7,
                                  ),
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
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      '没有这个状态的插件。',
                      style: libraryText(context, 13, color: c.muted),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const PrototypeIcon(PrototypeIconGlyph.inbox, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '普通信息、文档、文件和凭据无需安装插件。',
                    style: libraryText(context, 12, color: c.muted),
                  ),
                ),
              ],
            ),
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RecordIcon(template.type, size: 43),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            p.name,
                            key: const ValueKey('plugin-selected-title'),
                            style: libraryHeading(context, 22),
                          ),
                          LibraryPill(
                            p.enabled ? '已启用' : '已停用',
                            color: p.enabled ? c.success : c.muted,
                            background: p.enabled ? c.successSurface : c.nav,
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Text(
                        p.description,
                        style: libraryText(
                          context,
                          14,
                          color: c.muted,
                          height: 1.85,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${p.author} · ${p.builtin ? '内置' : '本地安装'} · v${p.version}',
                        style: libraryText(context, 12, color: c.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 15),
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
            if (p.legacySource case final source?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '由旧版模板第${source['version']}版转换，保留${(source['definitionIds'] as Map).length}项字段定义来源对应。',
                  style: libraryText(context, 13, color: c.muted),
                ),
              ),
            Container(
              margin: const EdgeInsets.only(top: 15, bottom: 16),
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.line)),
              ),
              child: MediaQuery.textScalerOf(context).scale(1) >= 1.6
                  ? Wrap(
                      spacing: 10,
                      runSpacing: 14,
                      children: [
                        _fact(context, '提供模板', '${p.templates.length} 个'),
                        _fact(context, '已用于', '${p.affectedRecords} 项资料'),
                        _fact(context, '目录归属', '由每份资料自行选择'),
                      ],
                    )
                  : Row(
                      children: [
                        _fact(context, '提供模板', '${p.templates.length} 个'),
                        const SizedBox(width: 10),
                        _fact(context, '已用于', '${p.affectedRecords} 项资料'),
                        const Spacer(),
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
                  for (final tab
                      in [
                        PluginTab.preview,
                        PluginTab.structure,
                        PluginTab.instructions,
                        PluginTab.settings,
                      ].where(
                        (tab) =>
                            tab != PluginTab.settings ||
                            p.panels.contains(WorkspacePluginPanel.sshTrust) &&
                                widget.hosts != null &&
                                widget.hostChanges != null,
                      ))
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
            if (model.tab != PluginTab.settings && p.templates.length > 1) ...[
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
            if (model.tab == PluginTab.settings &&
                p.panels.contains(WorkspacePluginPanel.sshTrust) &&
                widget.hosts != null &&
                widget.hostChanges != null)
              HostSettingsPanel(
                source: widget.hosts!,
                changes: widget.hostChanges!,
                readGeneration: model.readGeneration,
                onOpen: _openHost,
              )
            else if (model.tab == PluginTab.instructions) ...[
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
                      style: libraryText(context, 17, weight: FontWeight.w600),
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
                const SizedBox(height: 10),
                Text(
                  '按下方结构填写，目录和关联可以稍后补充。',
                  style: libraryText(context, 13, color: c.muted, height: 1.8),
                ),
                const SizedBox(height: 20),
              ],
              PluginTemplatePreview(
                template: template,
                structure: model.tab == PluginTab.structure,
                embedded: widget.embedded,
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

  Widget _fact(BuildContext context, String label, String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: libraryText(context, 12, color: UiPalette.of(context).muted),
      ),
      const SizedBox(width: 12),
      Text(value, style: libraryText(context, 12, weight: FontWeight.w500)),
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
            if (!widget.embedded)
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
                      selected: !model.showingLegacy,
                      alignment: Alignment.centerLeft,
                      leading: const PrototypeIcon(PrototypeIconGlyph.plugin),
                      onPressed: () {
                        _top();
                        model.showLegacy(false);
                        model.setFilter(PluginFilter.all);
                      },
                      child: const Text('插件'),
                    ),
                    if (widget.legacy != null) ...[
                      const SizedBox(height: 10),
                      DesktopButton(
                        key: const ValueKey('legacy-menu'),
                        selected: model.showingLegacy,
                        alignment: Alignment.centerLeft,
                        onPressed: () => model.showLegacy(true),
                        child: const Text('旧版模板'),
                      ),
                    ],
                  ],
                ),
              ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  MediaQuery.sizeOf(context).width <= 1300 ? 18 : 24,
                  MediaQuery.sizeOf(context).width <= 1300 ? 22 : 26,
                  MediaQuery.sizeOf(context).width <= 1300 ? 18 : 24,
                  MediaQuery.sizeOf(context).width <= 1300 ? 22 : 18,
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
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 400),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                model.showingLegacy ? '旧版模板' : '插件',
                                style: libraryHeading(context, 25),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                model.showingLegacy
                                    ? '继续使用旧录入辅助，或明确转换为声明式插件。'
                                    : '管理资料模板与插件专属设置。已有资料始终由信息库保存。',
                                style: libraryText(context, 12, color: c.muted),
                              ),
                            ],
                          ),
                        ),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            DesktopButton(
                              key: const ValueKey('plugin-authoring-guide'),
                              fontSize: 12,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              onPressed: () async {
                                widget.onModalChanged?.call(true);
                                try {
                                  await showPluginAuthoringGuide(
                                    context,
                                    model.catalog,
                                  );
                                } finally {
                                  widget.onModalChanged?.call(false);
                                }
                              },
                              child: const Text('Agent 制作指引'),
                            ),
                            if (!model.showingLegacy)
                              DesktopButton(
                                key: const ValueKey('plugin-install'),
                                fontSize: 12,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                kind: DesktopButtonKind.primary,
                                leading: const PrototypeIcon(
                                  PrototypeIconGlyph.plus,
                                ),
                                onPressed:
                                    widget.picker == null ||
                                        model.loading ||
                                        model.failure != null
                                    ? null
                                    : () => _operation(
                                        WorkspacePluginAction.install,
                                      ),
                                child: const Text('安装插件包'),
                              ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 40),
                    if (model.failure case final failure?
                        when !model.showingLegacy) ...[
                      PluginFailureView(failure),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: DesktopButton(
                          onPressed: widget.onRetry,
                          child: const Text('重新读取插件'),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ] else if (!model.showingLegacy && model.loading)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('正在刷新插件…'),
                      ),
                    Expanded(
                      child: Container(
                        key: ValueKey(
                          model.showingLegacy
                              ? 'legacy-workspace'
                              : 'plugin-workspace',
                        ),
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: c.paper,
                          border: Border.all(color: c.line),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: model.showingLegacy && widget.legacy != null
                            ? LegacyTemplatesPanel(
                                controller: widget.legacy!,
                                catalog: model.catalog,
                                plugins: model.source,
                                onCreate: widget.onLegacyCreate,
                                onConverted: (id) async {
                                  await model.load();
                                  if (mounted) model.select(id);
                                },
                                onModalChanged: widget.onModalChanged,
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    width: widget.embedded
                                        ? 250
                                        : bounds.maxWidth <= 1300
                                        ? 200
                                        : 225,
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
