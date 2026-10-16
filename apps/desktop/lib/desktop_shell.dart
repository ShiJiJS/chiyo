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
    _pending = _pendingCount;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final count = _pendingCount;
      if (mounted && count != _pending) setState(() => _pending = count);
    });
  }

  int get _pendingCount => widget.service.owner.requests
      .where((r) => r.state == AccessRequestState.pending)
      .length;
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static const _labels = ['访问审批', '资料库', '录入提案', '授权历史', '设置'];
  static const _icons = [
    Icons.rule_outlined,
    Icons.folder_open_outlined,
    Icons.playlist_add_outlined,
    Icons.history_outlined,
    Icons.settings_outlined,
  ];

  Widget _status(bool compact) {
    final runtime = widget.runtime;
    final stopped =
        runtime?.quitting == true || runtime?.shutdownFailed == true;
    return Tooltip(
      message:
          '127.0.0.1:${widget.port}。${runtime?.availability.tray == true ? '关窗后继续运行，可从托盘或菜单栏打开审批。' : '托盘或菜单栏不可用，关闭按钮将保留窗口。'}',
      child: compact
          ? Icon(
              stopped ? Icons.link_off : Icons.circle,
              size: 9,
              color: UiColors.muted,
            )
          : StatusLabel(stopped ? '服务已停止' : '本机服务已启动'),
    );
  }

  Widget _navigationRail() => Material(
    color: UiColors.rail,
    child: SizedBox(
      width: 194,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 16, 24),
            child: Row(
              children: [
                const Icon(
                  Icons.layers_outlined,
                  color: UiColors.brand,
                  size: 27,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '信息授权',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < 5; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: _destination(i, _labels[i], rail: true),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 16, 14),
            child: _status(false),
          ),
        ],
      ),
    ),
  );

  Widget _compactNavigation() => Material(
    color: UiColors.rail,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: UiColors.line)),
      ),
      child: Row(
        children: [
          const Tooltip(
            message: '信息授权',
            child: Icon(Icons.layers_outlined, color: UiColors.brand, size: 26),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < 5; i++) _destination(i, _labels[i]),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          _status(true),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final runtime = widget.runtime;
      final rail =
          box.maxWidth >= 1120 &&
          MediaQuery.textScalerOf(context).scale(14) <= 20;
      final workspace = Column(
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
      );
      return Scaffold(
        backgroundColor: Colors.white,
        body: rail
            ? Row(
                children: [
                  _navigationRail(),
                  const VerticalDivider(width: 1),
                  Expanded(child: workspace),
                ],
              )
            : Column(
                children: [
                  _compactNavigation(),
                  Expanded(child: workspace),
                ],
              ),
      );
    },
  );

  Widget _destination(int index, String label, {bool rail = false}) {
    final selected = index == widget.index;
    return Padding(
      padding: EdgeInsets.only(right: rail ? 0 : 5),
      child: Semantics(
        selected: selected,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? UiColors.selected : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: TextButton(
            key: ValueKey('nav-$index'),
            onPressed: () => widget.onSelected(index),
            style: TextButton.styleFrom(
              animationDuration: Duration.zero,
              overlayColor: const Color(0x0a000000),
              alignment: rail ? Alignment.centerLeft : null,
              foregroundColor: selected ? UiColors.accent : UiColors.muted,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            ),
            child: Row(
              mainAxisSize: rail ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (rail) ...[
                  Icon(_icons[index], size: 18),
                  const SizedBox(width: 12),
                ],
                Flexible(child: Text(label)),
                if (index == 0 && _pending > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '$_pending',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: selected ? UiColors.accent : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
