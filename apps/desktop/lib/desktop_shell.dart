import 'dart:async';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'desktop_runtime.dart';
import 'ui.dart';
import 'prototype_ui.dart';
import 'desktop_scroll.dart';

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
    PrototypeIconGlyph.inbox,
    PrototypeIconGlyph.folder,
    PrototypeIconGlyph.plus,
    PrototypeIconGlyph.clock,
    PrototypeIconGlyph.tune,
  ];
  static const _themeNames = ['紫棠', '松石', '雾蓝', '黑白'];

  Widget _destination(int index) {
    final c = UiPalette.of(context);
    final selected = widget.index == index;
    final ink = selected ? c.strong : c.muted;
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: selected ? c.accent : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: TextButton(
        key: ValueKey('nav-$index'),
        onPressed: () => widget.onSelected(index),
        style: prototypeButton(context, size: 14, foreground: ink, radius: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PrototypeIcon(_icons[index], color: ink),
            const SizedBox(width: 8),
            Text(
              _labels[index],
              style: prototypeText(
                context,
                14,
                color: ink,
                weight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            if (index == 0 && _pending > 0) ...[
              const SizedBox(width: 10),
              Text(
                '$_pending',
                style: prototypeText(
                  context,
                  13,
                  color: ink,
                  family: 'Georgia',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _themes() {
    final c = UiPalette.of(context);
    return Container(
      width: 244 * MediaQuery.textScalerOf(context).scale(12) / 12,
      margin: const EdgeInsets.only(top: 1),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.canvas,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final theme in DesktopColorTheme.values) ...[
            if (theme.index > 0) const SizedBox(width: 2),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: widget.colorTheme == theme
                      ? const [
                          BoxShadow(
                            color: Color(0x06000000),
                            offset: Offset(0, 1),
                            blurRadius: 2,
                          ),
                        ]
                      : null,
                ),
                child: TextButton(
                  key: ValueKey('theme-${theme.name}'),
                  onPressed: widget.themeBusy
                      ? null
                      : () => widget.onThemeChanged(theme),
                  style: prototypeButton(
                    context,
                    foreground: widget.colorTheme == theme ? c.strong : c.muted,
                    background: widget.colorTheme == theme
                        ? c.paper
                        : Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    side: BorderSide(
                      color: widget.colorTheme == theme
                          ? c.line
                          : Colors.transparent,
                    ),
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
                      const SizedBox(width: 6),
                      Text(_themeNames[theme.index]),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

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
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final compact =
                      bounds.maxWidth < 1000 ||
                      MediaQuery.textScalerOf(context).scale(14) > 20;
                  final brand = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PrototypeIcon(
                        PrototypeIconGlyph.layers,
                        size: 26,
                        color: colors.strong,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '信息授权',
                        style: prototypeText(
                          context,
                          18,
                          color: colors.strong,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ],
                  );
                  final nav = ScrollConfiguration(
                    behavior: const DesktopScrollBehavior().copyWith(
                      scrollbars: compact,
                    ),
                    child: SingleChildScrollView(
                      primary: false,
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < 5; i++) ...[
                            if (i > 0) const SizedBox(width: 12),
                            _destination(i),
                          ],
                        ],
                      ),
                    ),
                  );
                  if (compact) {
                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [brand, const Spacer(), _themes()],
                          ),
                        ),
                        nav,
                      ],
                    );
                  }
                  return SizedBox(
                    height: 71,
                    child: Row(
                      children: [
                        brand,
                        const SizedBox(width: 24),
                        nav,
                        const Spacer(),
                        _themes(),
                        if (bounds.maxWidth + 56 > 1320) ...[
                          const SizedBox(width: 30),
                          SizedBox(
                            width: 72,
                            child: Tooltip(
                              message: '127.0.0.1:${widget.port}',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 5,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      color: runtime?.quitting == true
                                          ? colors.muted
                                          : colors.accent ==
                                                const Color(0xff333333)
                                          ? const Color(0xff59595f)
                                          : const Color(0xff56795c),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    runtime?.quitting == true
                                        ? '服务已停止'
                                        : '本机已连接',
                                    style: prototypeText(
                                      context,
                                      11,
                                      color: colors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
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
          if (runtime?.attachmentCleanupFailed == true)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: QuietNotice(
                '附件旧版本的到期清理暂时失败，请检查存储。应用会再次尝试清理。',
                warning: true,
              ),
            ),
          if (runtime?.credentialCleanupFailed == true)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: QuietNotice(
                '凭据旧版本与回收内容的到期清理暂时失败，请检查存储。超期内容无法恢复，应用会再次尝试清理。',
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
          if (runtime?.runtimeMaterialCleanupFailed == true ||
              (runtime?.runtimeMaterialChecks ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: QuietNotice(
                runtime?.runtimeMaterialCleanupFailed == true
                    ? '临时凭据材料核查暂时失败。可在设置 → 应用运行中查看并重试清理。'
                    : '有 ${runtime!.runtimeMaterialChecks} 项临时凭据材料待核查。可在设置 → 应用运行中查看，清理不会重新启动命令。',
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
