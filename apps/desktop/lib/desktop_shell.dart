import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'desktop_runtime.dart';
import 'ui.dart';

class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.service,
    required this.port,
    required this.index,
    required this.onSelected,
    required this.child,
    required this.hasBackups,
    this.runtime,
    this.colorTheme = DesktopColorTheme.purple,
    required this.onThemeChanged,
    this.themeBusy = false,
    this.themeError,
  });
  final InformationService service;
  final int port, index;
  final ValueChanged<int> onSelected;
  final Widget child;
  final bool hasBackups;
  final DesktopRuntime? runtime;
  final DesktopColorTheme colorTheme;
  final ValueChanged<DesktopColorTheme> onThemeChanged;
  final bool themeBusy;
  final String? themeError;
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  Timer? _timer;
  int _pending = 0;
  @override
  void initState() {
    super.initState();
    _updateCount();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateCount());
  }

  void _updateCount() {
    if (!widget.service.owner.serviceAvailable) return;
    final count = widget.service.owner.queryInbox(limit: 1).pendingCount;
    if (count != _pending && mounted) setState(() => _pending = count);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static const _labels = ['访问审批', '信息库', '录入提案', '授权历史', '设置'];
  static const _icons = [
    Icons.rule_outlined,
    Icons.folder_open_outlined,
    Icons.playlist_add_outlined,
    Icons.history_outlined,
    Icons.settings_outlined,
  ];
  static const _themeNames = ['紫棠', '松石', '雾蓝', '黑白'];

  Widget _destination(int index) {
    final colors = UiPalette.of(context);
    final selected = widget.index == index;
    return Container(
      decoration: BoxDecoration(
        color: selected ? colors.selected : Colors.transparent,
        border: Border(
          bottom: BorderSide(
            color: selected ? colors.accent : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: TextButton(
        key: ValueKey('nav-$index'),
        onPressed: () => widget.onSelected(index),
        style: TextButton.styleFrom(
          foregroundColor: selected ? colors.strong : colors.muted,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 16),
          shape: const RoundedRectangleBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icons[index], size: 17),
            const SizedBox(width: 7),
            Text(_labels[index]),
            if (index == 0 && _pending > 0) ...[
              const SizedBox(width: 5),
              Text('$_pending'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _themes() => Wrap(
    spacing: 2,
    children: [
      for (final theme in DesktopColorTheme.values)
        Tooltip(
          message: '切换为${_themeNames[theme.index]}',
          child: TextButton(
            key: ValueKey('theme-${theme.name}'),
            onPressed: widget.themeBusy
                ? null
                : () => widget.onThemeChanged(theme),
            style: TextButton.styleFrom(
              backgroundColor: widget.colorTheme == theme
                  ? UiPalette.of(context).selected
                  : Colors.transparent,
              minimumSize: const Size(32, 32),
              padding: const EdgeInsets.symmetric(horizontal: 7),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: UiPalette.forTheme(theme).accent,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _themeNames[theme.index],
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final colors = UiPalette.of(context);
    final runtime = widget.runtime;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: Column(
        children: [
          Material(
            color: colors.paper,
            child: Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.line)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final compact =
                      bounds.maxWidth < 1100 ||
                      MediaQuery.textScalerOf(context).scale(14) > 20;
                  final brand = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.layers_outlined,
                        size: 26,
                        color: colors.strong,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '信息授权',
                        style: Theme.of(
                          context,
                        ).textTheme.titleMedium?.copyWith(color: colors.strong),
                      ),
                    ],
                  );
                  final nav = SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [for (var i = 0; i < 5; i++) _destination(i)],
                    ),
                  );
                  return compact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                children: [
                                  brand,
                                  const Spacer(),
                                  Flexible(child: _themes()),
                                ],
                              ),
                            ),
                            nav,
                          ],
                        )
                      : Row(
                          children: [
                            brand,
                            const SizedBox(width: 28),
                            Expanded(child: nav),
                            const SizedBox(width: 12),
                            _themes(),
                            if (bounds.maxWidth > 1300) ...[
                              const SizedBox(width: 18),
                              Tooltip(
                                message: '127.0.0.1:${widget.port}',
                                child: StatusLabel(
                                  runtime?.quitting == true ? '服务已停止' : '本机已连接',
                                  active: runtime?.quitting != true,
                                ),
                              ),
                            ],
                          ],
                        );
                },
              ),
            ),
          ),
          if (widget.themeError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: QuietNotice(widget.themeError!, warning: true),
            ),
          if (runtime != null &&
              (!runtime.availability.tray ||
                  runtime.availability.notifications ==
                      NotificationAvailability.denied))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: QuietNotice(
                '${!runtime.availability.tray ? '托盘或菜单栏不可用，关闭按钮将保留窗口。' : ''}${runtime.availability.notifications == NotificationAvailability.denied ? '系统通知已被拒绝，待办仍可在应用内处理。' : ''}',
              ),
            ),
          if (runtime?.recycleCleanupFailed == true)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: QuietNotice(
                '回收站到期清理暂时失败，请检查存储。到期内容无法恢复，应用会再次尝试清理。',
                warning: true,
              ),
            ),
          if (runtime?.revisionCleanupFailed == true)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: QuietNotice(
                '修改历史到期清理暂时失败，请检查存储。到期版本无法查看或恢复，应用会再次尝试清理。',
                warning: true,
              ),
            ),
          if (runtime?.shutdownFailed == true)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: QuietNotice(
                '访问服务已停止，但记录尚未保存，应用未退出。请修复存储后重试保存并退出；重新启动后需要重新申请授权。',
                warning: true,
              ),
            ),
          Expanded(
            key: const ValueKey('desktop-workspace'),
            child: WorkspaceEntrance(child: widget.child),
          ),
        ],
      ),
    );
  }
}
