import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../desktop_motion.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'plugins_controller.dart';
import 'settings_controller.dart';
import 'workspace_source.dart';

class WorkspaceSettingsPage extends StatefulWidget {
  const WorkspaceSettingsPage({
    super.key,
    required this.controller,
    required this.plugins,
    required this.pluginBuilder,
    required this.onRequest,
    this.onModalChanged,
  });
  final WorkspaceSettingsController controller;
  final PluginsController plugins;
  final WidgetBuilder pluginBuilder;
  final ValueChanged<String> onRequest;
  final ValueChanged<bool>? onModalChanged;
  @override
  State<WorkspaceSettingsPage> createState() => _WorkspaceSettingsPageState();
}

class _WorkspaceSettingsPageState extends State<WorkspaceSettingsPage> {
  WorkspaceSettingsController get m => widget.controller;
  late final ScrollController _scroll;
  late WorkspaceSettingsSection _shown;
  @override
  void initState() {
    super.initState();
    _shown = m.section;
    _scroll = ScrollController(initialScrollOffset: m.positions[m.section] ?? 0)
      ..addListener(() {
        if (_scroll.hasClients) m.positions[_shown] = _scroll.offset;
      });
    m.addListener(_changed);
  }

  void _changed() {
    if (_shown == m.section) return;
    _shown = m.section;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(
          (m.positions[_shown] ?? 0).clamp(0, _scroll.position.maxScrollExtent),
        );
      }
    });
  }

  @override
  void dispose() {
    m.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _notification() async {
    if (m.frozen) return;
    widget.onModalChanged?.call(true);
    String? request;
    try {
      request = await showDesktopDialog<String>(
        context,
        builder: (_) => _NotificationPreview(source: m.source),
      );
    } finally {
      widget.onModalChanged?.call(false);
    }
    if (mounted && request != null) widget.onRequest(request);
  }

  Widget _feedback(BuildContext context) {
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (m.loading) const LinearProgressIndicator(),
        if (m.readFailure != null) ...[
          Text(
            m.readFailure!.message,
            style: libraryText(context, 14, color: c.danger, height: 1.8),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              key: const ValueKey('settings-read-retry'),
              onPressed: m.frozen ? null : m.load,
              child: const Text('重新读取设置'),
            ),
          ),
        ],
        if (m.writeFailure != null)
          Text(
            m.writeFailure!.message,
            style: libraryText(context, 14, color: c.danger, height: 1.8),
          ),
        if (m.notice != null)
          Text(
            m.notice!,
            style: libraryText(context, 13, color: c.muted, height: 1.8),
          ),
        if (m.uncertain)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              key: const ValueKey('settings-reconcile'),
              onPressed: m.busy ? null : m.reconcile,
              child: const Text('核对原设置操作'),
            ),
          ),
        if (m.conflicted)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              key: const ValueKey('settings-discard'),
              onPressed: m.frozen ? null : m.discard,
              child: const Text('采用当前保存的设置'),
            ),
          ),
        if (m.dirty && !m.uncertain && !m.conflicted)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              key: const ValueKey('settings-save'),
              onPressed: m.canSave ? m.save : null,
              child: const Text('保存保留的选择'),
            ),
          ),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _themeChoice(BuildContext context, WorkspaceTheme theme) {
    final c = UiPalette.of(context),
        p = UiPalette.zhiyu(
          theme == WorkspaceTheme.dark ? Brightness.dark : Brightness.light,
        ),
        selected = m.draft?.theme == theme;
    return DesktopButton(
      key: ValueKey('settings-theme-${theme.name}'),
      selected: selected,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.all(20),
      onPressed:
          m.frozen || m.loading || m.readFailure != null || m.draft == null
          ? null
          : () => m.setTheme(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 130,
            decoration: BoxDecoration(
              color: p.canvas,
              border: Border.all(color: p.line),
              borderRadius: BorderRadius.circular(7),
            ),
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                Container(width: 44, color: p.rail),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      Container(height: 14, color: p.paper),
                      const SizedBox(height: 13),
                      Container(height: 15, color: p.selected),
                      const SizedBox(height: 13),
                      Container(height: 14, color: p.paper),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            children: [
              Text(
                theme == WorkspaceTheme.light ? '明亮' : '黑暗',
                style: libraryText(context, 17, weight: FontWeight.w600),
              ),
              if (selected) Icon(Icons.check, size: 21, color: c.accent),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            theme == WorkspaceTheme.light ? '浅灰底色，清晰留白' : '深灰层次，柔和对比',
            style: libraryText(context, 13, color: c.muted, height: 1.7),
          ),
        ],
      ),
    );
  }

  Widget _appearance(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('界面主题', style: libraryText(context, 19, weight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text(
        '选择适合当前光线的阅读方式。',
        style: libraryText(context, 14, color: UiPalette.of(context).muted),
      ),
      const SizedBox(height: 20),
      LayoutBuilder(
        builder: (context, b) =>
            b.maxWidth < 650 || MediaQuery.textScalerOf(context).scale(1) >= 1.6
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _themeChoice(context, WorkspaceTheme.light),
                  const SizedBox(height: 18),
                  _themeChoice(context, WorkspaceTheme.dark),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _themeChoice(context, WorkspaceTheme.light)),
                  const SizedBox(width: 20),
                  Expanded(child: _themeChoice(context, WorkspaceTheme.dark)),
                ],
              ),
      ),
      const SizedBox(height: 26),
      SettingsPreferenceRow(
        title: '阅读层次',
        description: '背景、列表和详情用不同明度区分；强调色用于当前选择与主要操作。',
        control: const PrototypeIcon(PrototypeIconGlyph.layers),
      ),
      SettingsPreferenceRow(
        title: '资料识别',
        description: '保留服务器、文件和凭据的图标色，并始终显示类型名称。',
        control: const PrototypeIcon(PrototypeIconGlyph.file),
      ),
    ],
  );
  Widget _notifications(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SettingsPreferenceRow(
        title: '访问申请通知',
        description: '收到新申请时提醒。通知只显示请求概况，不包含字段值和密钥。',
        control: m.draft == null
            ? Text(
                m.readFailure == null ? '正在读取…' : '暂不可用',
                style: libraryText(
                  context,
                  13,
                  color: UiPalette.of(context).muted,
                ),
              )
            : Semantics(
                label: '访问申请通知',
                child: Switch(
                  key: const ValueKey('settings-notifications'),
                  value: m.draft!.notifications,
                  onChanged:
                      m.frozen ||
                          m.loading ||
                          m.readFailure != null ||
                          m.draft == null
                      ? null
                      : m.setNotifications,
                ),
              ),
      ),
      SettingsPreferenceRow(
        title: '检查提醒效果',
        description: '预览通知的标题、说明与点击后的去向。',
        control: DesktopButton(
          key: const ValueKey('settings-notification-preview'),
          onPressed: m.frozen ? null : _notification,
          child: const Text('预览通知'),
        ),
      ),
      const SizedBox(height: 20),
      Text(
        '系统通知由macOS管理，通知权限与专注模式会影响提醒显示。可先预览申请概况及点击去向。',
        style: libraryText(
          context,
          13,
          color: UiPalette.of(context).muted,
          height: 1.9,
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([m, widget.plugins]),
    builder: (context, _) {
      final c = UiPalette.of(context),
          large = MediaQuery.textScalerOf(context).scale(1) >= 1.6;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: large
                ? 300
                : MediaQuery.sizeOf(context).width <= 1300
                ? 220
                : 250,
            decoration: BoxDecoration(
              color: c.rail,
              border: Border(right: BorderSide(color: c.line)),
            ),
            child: ListView(
              primary: false,
              padding: const EdgeInsets.fromLTRB(18, 26, 18, 20),
              children: [
                Text(
                  '设置',
                  style: libraryText(context, 24, weight: FontWeight.w600),
                ),
                const SizedBox(height: 24),
                for (final section in WorkspaceSettingsSection.values) ...[
                  DesktopButton(
                    key: ValueKey('settings-section-${section.name}'),
                    kind: DesktopButtonKind.quiet,
                    alignment: Alignment.centerLeft,
                    leading: PrototypeIcon(switch (section) {
                      WorkspaceSettingsSection.appearance =>
                        PrototypeIconGlyph.layers,
                      WorkspaceSettingsSection.notifications =>
                        PrototypeIconGlyph.inbox,
                      WorkspaceSettingsSection.plugins =>
                        PrototypeIconGlyph.plugin,
                    }),
                    selected:
                        m.section == section &&
                        (section != WorkspaceSettingsSection.plugins ||
                            !widget.plugins.showingLegacy),
                    onPressed: m.frozen
                        ? null
                        : () {
                            m.select(section);
                            if (section == WorkspaceSettingsSection.plugins) {
                              widget.plugins.showLegacy(false);
                            }
                          },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          section.label,
                          style: libraryText(
                            context,
                            15,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          section.description,
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
                  const SizedBox(height: 10),
                  if (section == WorkspaceSettingsSection.plugins) ...[
                    DesktopButton(
                      key: const ValueKey('legacy-menu'),
                      alignment: Alignment.centerLeft,
                      selected:
                          m.section == section && widget.plugins.showingLegacy,
                      kind: DesktopButtonKind.quiet,
                      onPressed: m.frozen
                          ? null
                          : () {
                              m.select(section);
                              widget.plugins.showLegacy(true);
                            },
                      child: const Text('旧版模板'),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ],
            ),
          ),
          Expanded(
            child: m.section == WorkspaceSettingsSection.plugins
                ? widget.pluginBuilder(context)
                : SingleChildScrollView(
                    key: const ValueKey('settings-detail-scroll'),
                    controller: _scroll,
                    padding: const EdgeInsets.all(30),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1120),
                        child: DesktopEntrance(
                          key: ValueKey(m.section),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                m.section.label,
                                style: libraryText(
                                  context,
                                  26,
                                  weight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                m.section.description,
                                style: libraryText(context, 14, color: c.muted),
                              ),
                              const SizedBox(height: 28),
                              _feedback(context),
                              if (m.section ==
                                  WorkspaceSettingsSection.appearance)
                                _appearance(context)
                              else
                                _notifications(context),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      );
    },
  );
}

class SettingsPreferenceRow extends StatelessWidget {
  const SettingsPreferenceRow({
    super.key,
    required this.title,
    required this.description,
    required this.control,
  });
  final String title, description;
  final Widget control;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: libraryText(context, 16, weight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
          description,
          style: libraryText(context, 14, color: c.muted, height: 1.8),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: LayoutBuilder(
        builder: (context, b) =>
            b.maxWidth < 650 || MediaQuery.textScalerOf(context).scale(1) >= 1.6
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  text,
                  const SizedBox(height: 14),
                  Align(alignment: Alignment.centerLeft, child: control),
                ],
              )
            : Row(
                children: [
                  Expanded(child: text),
                  const SizedBox(width: 30),
                  control,
                ],
              ),
      ),
    );
  }
}

class _NotificationPreview extends StatefulWidget {
  const _NotificationPreview({required this.source});
  final WorkspaceSettingsSource source;
  @override
  State<_NotificationPreview> createState() => _NotificationPreviewState();
}

class _NotificationPreviewState extends State<_NotificationPreview> {
  WorkspaceNotificationPreview? _preview;
  WorkspaceFailure? _failure;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _preview = null;
      _failure = null;
    });
    try {
      final p = await widget.source.notificationPreview();
      if (mounted) setState(() => _preview = p);
    } catch (error) {
      if (mounted) {
        setState(
          () => _failure = error is WorkspaceFailure
              ? error
              : const WorkspaceFailure('unavailable', '暂时无法读取通知概况。'),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => DesktopDialog(
    title: const Text('通知预览'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading) const LinearProgressIndicator(),
        if (_failure != null) ...[
          Text(_failure!.message),
          DesktopButton(
            key: const ValueKey('settings-notification-retry'),
            onPressed: _read,
            child: const Text('重试预览'),
          ),
        ],
        if (_preview case final p?) ...[
          Text(
            '知予 · ${p.title}',
            style: libraryText(context, 19, weight: FontWeight.w600),
          ),
          const SizedBox(height: 15),
          Text(p.description, style: libraryText(context, 14, height: 1.8)),
          const SizedBox(height: 15),
          const Text('仅显示申请概况；点击后进入对应申请，不会自动批准。'),
        ],
      ],
    ),
    actions: [
      DesktopButton(
        key: const ValueKey('settings-notification-open'),
        onPressed: _preview?.requestId == null
            ? null
            : () => Navigator.pop(context, _preview!.requestId),
        child: const Text('前往对应申请'),
      ),
      DesktopButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
