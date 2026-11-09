import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../prototype_icons.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'classification_controller.dart';
import 'backup_controller.dart';
import 'backup_page.dart';
import 'runtime_controller.dart';
import 'runtime_page.dart';
import 'agents_controller.dart';
import 'agents_page.dart';
import 'classification_page.dart';
import 'plugins_controller.dart';
import 'settings_controller.dart';
import 'settings_layout.dart';
import 'workspace_source.dart';

class WorkspaceSettingsPage extends StatefulWidget {
  const WorkspaceSettingsPage({
    super.key,
    required this.controller,
    required this.plugins,
    required this.classifications,
    required this.backups,
    required this.runtime,
    required this.agents,
    required this.backupPicker,
    required this.onLibrary,
    required this.pluginBuilder,
    required this.onRequest,
    this.onModalChanged,
  });
  final WorkspaceSettingsController controller;
  final PluginsController plugins;
  final ClassificationController classifications;
  final BackupController backups;
  final WorkspaceRuntimeController runtime;
  final WorkspaceAgentsController agents;
  final WorkspaceBackupPicker backupPicker;
  final VoidCallback onLibrary;
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

  Future<void> _savePreferences() async {
    if (!m.canPrepareSave) return;
    if (!m.needsRetentionReview) {
      await m.save();
      return;
    }
    widget.onModalChanged?.call(true);
    bool? confirmed;
    try {
      confirmed = await showDesktopDialog<bool>(
        context,
        builder: (_) => _RetentionReview(controller: m),
      );
    } finally {
      widget.onModalChanged?.call(false);
    }
    if (!mounted) return;
    if (confirmed == true) {
      await m.save();
    } else {
      m.cancelRetention();
    }
  }

  Widget _feedback(BuildContext context) {
    if (!m.loading &&
        m.readFailure == null &&
        m.writeFailure == null &&
        m.notice == null &&
        !m.dirty) {
      return const SizedBox.shrink();
    }
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
        if (m.dirty &&
            !m.uncertain &&
            !m.conflicted &&
            m.section != WorkspaceSettingsSection.records)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              key: const ValueKey('settings-save'),
              onPressed: m.canPrepareSave ? _savePreferences : null,
              child: Text(m.needsRetentionReview ? '核对清理范围并保存' : '保存保留的选择'),
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
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: selected
            ? [BoxShadow(color: c.selected, spreadRadius: 2)]
            : null,
      ),
      child: DesktopButton(
        key: ValueKey('settings-theme-${theme.name}'),
        selected: selected,
        selectedBorder: true,
        selectedBorderColor: c.accent,
        selectedBackgroundColor: c.paper,
        hoverBackgroundColor: c.paper,
        hoverBorderColor: c.lineStrong,
        alignment: Alignment.centerLeft,
        radius: 10,
        padding: const EdgeInsets.all(15),
        onPressed:
            m.frozen || m.loading || m.readFailure != null || m.draft == null
            ? null
            : () => m.setTheme(theme),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsThemePreview(brightness: p.brightness),
            const SizedBox(height: 19),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        theme == WorkspaceTheme.light ? '明亮' : '黑暗',
                        style: libraryText(
                          context,
                          15,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        theme == WorkspaceTheme.light
                            ? '浅灰底色，清晰留白'
                            : '深灰层次，柔和对比',
                        style: libraryText(context, 12, color: c.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Container(
                  width: 21,
                  height: 21,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? c.accent : Colors.transparent,
                    border: Border.all(color: selected ? c.accent : c.muted),
                  ),
                  child: selected
                      ? Icon(Icons.check, size: 14, color: c.onAccent)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _appearance(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '界面主题',
        style: libraryText(context, 17, weight: FontWeight.w700, height: 1.5),
      ),
      const SizedBox(height: 9),
      Text(
        '选择适合当前光线的阅读方式。',
        style: libraryText(
          context,
          13,
          color: UiPalette.of(context).muted,
          height: 1.8,
        ),
      ),
      const SizedBox(height: 22),
      Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: LayoutBuilder(
            builder: (context, b) =>
                b.maxWidth < 650 ||
                    MediaQuery.textScalerOf(context).scale(1) >= 1.6
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
                      Expanded(
                        child: _themeChoice(context, WorkspaceTheme.light),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: _themeChoice(context, WorkspaceTheme.dark),
                      ),
                    ],
                  ),
          ),
        ),
      ),
      const SizedBox(height: 32),
      SettingsCard(
        children: [
          SettingsPreferenceRow(
            title: '阅读层次',
            description: '背景、列表和详情用不同明度区分；强调色用于当前选择与主要操作。',
            control: const PrototypeIcon(PrototypeIconGlyph.layers),
          ),
          SettingsPreferenceRow(
            title: '资料识别',
            divider: false,
            description: '保留服务器、文件和凭据的图标色，并始终显示类型名称。',
            control: const PrototypeIcon(PrototypeIconGlyph.file),
          ),
        ],
      ),
    ],
  );
  Widget _records(BuildContext context) {
    final enabled =
        !m.frozen && !m.loading && m.readFailure == null && m.draft != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          children: [
            SettingsPreferenceRow(
              title: '新申请等待时间',
              description: '超过等待时间仍未处理的申请将到期。只影响之后提交的新申请；已有申请和已批准授权的到期时间不变。',
              control: m.draft == null
                  ? const Text('尚未读取')
                  : DesktopSelect<int>(
                      key: const ValueKey('settings-request-minutes'),
                      value: m.draft!.requestMinutes,
                      items: [
                        for (final n in {
                          ...[5, 15, 30, 60, 120],
                          m.draft!.requestMinutes,
                          if (m.value != null) m.value!.requestMinutes,
                        }.toList()..sort())
                          DropdownMenuItem(value: n, child: Text('$n 分钟')),
                      ],
                      onChanged: !enabled
                          ? null
                          : (n) {
                              if (n != null) {
                                m.stage(m.draft!.copyWith(requestMinutes: n));
                              }
                            },
                    ),
            ),
            SettingsPreferenceRow(
              title: '记录保留期限',
              divider: false,
              description:
                  '管理申请、授权和操作结果记录。缩短期限前会显示清理范围；当前资料、文件原文、凭据材料、修订和回收站不随记录清理删除。',
              control: m.draft == null
                  ? const Text('尚未读取')
                  : DesktopSelect<int>(
                      key: const ValueKey('settings-retention-days'),
                      value: m.draft!.retentionDays,
                      items: [
                        for (final n in [30, 90, 180, 365])
                          DropdownMenuItem(value: n, child: Text('$n 天')),
                      ],
                      onChanged: !enabled
                          ? null
                          : (n) {
                              if (n != null) {
                                m.stage(m.draft!.copyWith(retentionDays: n));
                              }
                            },
                    ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          '仍有效的授权、进行中的任务、未确认的执行结果和待清理材料会保留，不能通过缩短期限结束这些操作。',
          style: libraryText(
            context,
            14,
            color: UiPalette.of(context).muted,
            height: 1.9,
          ),
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButton(
            key: const ValueKey('settings-records-save'),
            onPressed: m.canPrepareSave ? _savePreferences : null,
            child: Text(m.needsRetentionReview ? '核对清理范围并保存' : '保存设置'),
          ),
        ),
      ],
    );
  }

  Widget _notifications(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SettingsCard(
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
                    child: DesktopToggle(
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
            divider: false,
            description: '预览通知的标题、说明与点击后的去向。',
            control: DesktopButton(
              key: const ValueKey('settings-notification-preview'),
              onPressed: m.frozen ? null : _notification,
              child: const Text('预览通知'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      Text(
        Theme.of(context).platform == TargetPlatform.windows
            ? '系统通知由 Windows 管理，通知设置与勿扰模式会影响提醒显示。可先预览申请概况及点击去向。'
            : '系统通知由macOS管理，通知权限与专注模式会影响提醒显示。可先预览申请概况及点击去向。',
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
    listenable: Listenable.merge([
      m,
      widget.plugins,
      widget.backups,
      widget.runtime,
    ]),
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
              key: const ValueKey('settings-sidebar-scroll'),
              primary: false,
              padding: const EdgeInsets.fromLTRB(17, 26, 17, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('设置', style: libraryHeading(context, 24)),
                ),
                const SizedBox(height: 23),
                for (final section in WorkspaceSettingsSection.values) ...[
                  DesktopButton(
                    key: ValueKey('settings-section-${section.name}'),
                    kind: DesktopButtonKind.quiet,
                    radius: 8,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                    leadingGap: 11,
                    alignment: Alignment.centerLeft,
                    leading: PrototypeIcon(switch (section) {
                      WorkspaceSettingsSection.appearance =>
                        PrototypeIconGlyph.layers,
                      WorkspaceSettingsSection.notifications =>
                        PrototypeIconGlyph.inbox,
                      WorkspaceSettingsSection.records =>
                        PrototypeIconGlyph.clock,
                      WorkspaceSettingsSection.plugins =>
                        PrototypeIconGlyph.plugin,
                      WorkspaceSettingsSection.classifications =>
                        PrototypeIconGlyph.folder,
                      WorkspaceSettingsSection.backups =>
                        PrototypeIconGlyph.shield,
                      WorkspaceSettingsSection.runtime =>
                        PrototypeIconGlyph.tune,
                      WorkspaceSettingsSection.agents =>
                        PrototypeIconGlyph.link,
                    }),
                    selected:
                        m.section == section &&
                        (section != WorkspaceSettingsSection.plugins ||
                            !widget.plugins.showingLegacy),
                    onPressed:
                        m.frozen ||
                            widget.backups.frozen ||
                            widget.runtime.frozen ||
                            widget.runtime.shutdownGate
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
                            14,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          section.description,
                          style: libraryText(
                            context,
                            12,
                            color: c.muted,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (section == WorkspaceSettingsSection.plugins) ...[
                    DesktopButton(
                      key: const ValueKey('legacy-menu'),
                      alignment: Alignment.centerLeft,
                      selected:
                          m.section == section && widget.plugins.showingLegacy,
                      kind: DesktopButtonKind.quiet,
                      onPressed:
                          m.frozen ||
                              widget.backups.frozen ||
                              widget.runtime.frozen ||
                              widget.runtime.shutdownGate
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
                : m.section == WorkspaceSettingsSection.classifications
                ? ClassificationPage(
                    controller: widget.classifications,
                    onModalChanged: widget.onModalChanged,
                  )
                : m.section == WorkspaceSettingsSection.backups
                ? WorkspaceBackupPage(
                    controller: widget.backups,
                    picker: widget.backupPicker,
                    onLibrary: widget.onLibrary,
                    onModalChanged: widget.onModalChanged,
                  )
                : m.section == WorkspaceSettingsSection.runtime
                ? WorkspaceRuntimePage(
                    controller: widget.runtime,
                    preferences: m,
                    onRequest: widget.onRequest,
                    onModalChanged: widget.onModalChanged,
                  )
                : m.section == WorkspaceSettingsSection.agents
                ? WorkspaceAgentsPage(
                    controller: widget.agents,
                    onRequest: widget.onRequest,
                    onModalChanged: widget.onModalChanged,
                  )
                : SettingsPageContent(
                    scrollKey: const ValueKey('settings-detail-scroll'),
                    controller: _scroll,
                    entranceKey: ValueKey(m.section),
                    title: m.section.label,
                    description: m.section.description,
                    children: [
                      _feedback(context),
                      if (m.section == WorkspaceSettingsSection.appearance)
                        _appearance(context)
                      else if (m.section ==
                          WorkspaceSettingsSection.notifications)
                        _notifications(context)
                      else
                        _records(context),
                    ],
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
    this.divider = true,
  });
  final String title, description;
  final Widget control;
  final bool divider;
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: libraryText(context, 15, weight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
          description,
          style: libraryText(context, 13, color: c.muted, height: 1.85),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 26),
      decoration: BoxDecoration(
        border: divider ? Border(bottom: BorderSide(color: c.line)) : null,
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

class _RetentionReview extends StatefulWidget {
  const _RetentionReview({required this.controller});
  final WorkspaceSettingsController controller;
  @override
  State<_RetentionReview> createState() => _RetentionReviewState();
}

class _RetentionReviewState extends State<_RetentionReview> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(widget.controller.prepareRetention);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final m = widget.controller, p = m.retentionPreview;
      return DesktopDialog(
        title: const Text('核对记录清理范围'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (m.busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 16),
              const Text('正在读取准确清理范围…'),
            ],
            if (m.retentionFailure != null) ...[
              Text(m.retentionFailure!.message),
              DesktopButton(
                key: const ValueKey('settings-retention-retry'),
                onPressed: m.busy ? null : m.prepareRetention,
                child: const Text('重新读取范围'),
              ),
            ],
            if (p != null) ...[
              Text(
                '将保留最近 ${p.days} 天的记录',
                style: libraryText(context, 19, weight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                '截止时间：${p.cutoff.toLocal().toString().split(".").first}',
                style: libraryText(context, 14),
              ),
              const SizedBox(height: 16),
              Text(
                '清理 ${p.requests} 条申请、${p.grants} 条授权、${p.operations} 条操作结果。',
                style: libraryText(context, 15, height: 1.9),
              ),
              Text(
                '另有 ${p.preserved} 条活动或需继续核对的记录保留。',
                style: libraryText(context, 14, height: 1.9),
              ),
              const SizedBox(height: 16),
              const Text('清理后不能从记录页找回这些记录。资料内容、修订、回收站与凭据材料不会删除。范围变化时需要重新确认。'),
            ],
          ],
        ),
        actions: [
          DesktopButton(
            key: const ValueKey('settings-retention-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          DesktopButton(
            key: const ValueKey('settings-retention-confirm'),
            onPressed: m.busy || p == null
                ? null
                : () {
                    m.confirmRetention(p);
                    Navigator.pop(context, true);
                  },
            child: const Text('清理并保存'),
          ),
        ],
      );
    },
  );
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
