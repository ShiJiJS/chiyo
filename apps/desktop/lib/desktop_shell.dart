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
  });
  final InformationService service;
  final int port, index;
  final ValueChanged<int> onSelected;
  final Widget child;
  final bool hasBackups;
  final DesktopRuntime? runtime;
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  Timer? _timer;
  int _pending = 0;
  @override
  void initState() {
    super.initState();
    _pending = widget.service.owner.requests
        .where((r) => r.state == AccessRequestState.pending)
        .length;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final count = widget.service.owner.requests
          .where((r) => r.state == AccessRequestState.pending)
          .length;
      if (mounted && count != _pending) setState(() => _pending = count);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
      final compact =
          constraints.maxWidth < 720 ||
          (largeText && constraints.maxWidth < 1100);
      final runtime = widget.runtime;
      final stopped =
          runtime?.quitting == true || runtime?.shutdownFailed == true;
      return Scaffold(
        body: Row(
          children: [
            Container(
              width: compact
                  ? 64
                  : largeText
                  ? 232
                  : 184,
              decoration: const BoxDecoration(
                color: UiColors.rail,
                border: Border(right: BorderSide(color: UiColors.line)),
              ),
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 20 : 18,
                        24,
                        12,
                        30,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.layers_outlined,
                            size: 23,
                            color: UiColors.green,
                          ),
                          if (!compact) ...[
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                '信息授权',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    _destination(
                      0,
                      '访问审批',
                      Icons.inbox_outlined,
                      compact,
                      count: _pending,
                    ),
                    _destination(1, '我的信息', Icons.folder_outlined, compact),
                    _destination(
                      2,
                      '录入提案',
                      Icons.playlist_add_outlined,
                      compact,
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 15,
                      ),
                      child: Divider(),
                    ),
                    _destination(3, '授权历史', Icons.history_outlined, compact),
                    if (widget.hasBackups)
                      _destination(4, '备份恢复', Icons.backup_outlined, compact),
                    const Spacer(),
                    if (runtime != null) ...[
                      _utility(
                        '通知权限',
                        Icons.notifications_outlined,
                        runtime.quitting ? null : runtime.enableNotifications,
                        compact,
                        tooltip: '启用或检查通知',
                      ),
                      _utility(
                        runtime.quitting
                            ? '正在退出…'
                            : runtime.shutdownFailed
                            ? '重试保存并退出'
                            : '完全退出',
                        Icons.power_settings_new,
                        runtime.quitting ? null : runtime.quit,
                        compact,
                      ),
                    ],
                    const SizedBox(height: 16),
                    Tooltip(
                      message:
                          '127.0.0.1:${widget.port}。${runtime?.availability.tray == true ? '关窗后继续运行，可从托盘或菜单栏打开审批。' : '托盘或菜单栏不可用，关闭按钮将保留窗口。'}',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: compact
                            ? Icon(
                                stopped ? Icons.link_off : Icons.circle,
                                size: 12,
                                color: stopped
                                    ? UiColors.muted
                                    : UiColors.green,
                              )
                            : StatusLabel(
                                stopped ? '服务已停止' : '服务已启动',
                                active: !stopped,
                              ),
                      ),
                    ),
                    if (!compact)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(18, 12, 18, 20),
                        child: Text(
                          '开发预览\n请只使用虚构资料',
                          style: TextStyle(
                            color: UiColors.muted,
                            fontSize: 12,
                            height: 1.6,
                          ),
                        ),
                      ),
                    if (compact) const SizedBox(height: 22),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Column(
                children: [
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
                  Expanded(child: WorkspaceEntrance(child: widget.child)),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _destination(
    int index,
    String label,
    IconData icon,
    bool compact, {
    int count = 0,
  }) {
    final selected = widget.index == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Tooltip(
        message: compact ? label : '',
        child: Semantics(
          selected: selected,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 160),
            decoration: BoxDecoration(
              color: selected ? UiColors.selected : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: InkWell(
              key: ValueKey('nav-$index'),
              borderRadius: BorderRadius.circular(7),
              onTap: () => widget.onSelected(index),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 12 : 11,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 19,
                      color: selected ? UiColors.green : UiColors.muted,
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: selected ? UiColors.green : UiColors.ink,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (count > 0)
                        Text(
                          '$count',
                          style: const TextStyle(
                            color: UiColors.green,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _utility(
    String label,
    IconData icon,
    VoidCallback? action,
    bool compact, {
    String? tooltip,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 9),
    child: compact
        ? IconButton(
            tooltip: tooltip ?? label,
            onPressed: action,
            icon: Icon(icon, size: 19),
          )
        : Tooltip(
            message: tooltip ?? label,
            child: TextButton.icon(
              onPressed: action,
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                foregroundColor: UiColors.muted,
              ),
              icon: Icon(icon, size: 17),
              label: Text(label, style: const TextStyle(fontSize: 13)),
            ),
          ),
  );
}
