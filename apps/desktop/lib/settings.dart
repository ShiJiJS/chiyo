import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'backups.dart';
import 'desktop_runtime.dart';
import 'templates.dart';
import 'ui.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.owner,
    this.runtime,
    this.backups,
    required this.files,
    this.onRestored,
  });
  final OwnerAccess owner;
  final DesktopRuntime? runtime;
  final InformationBackups? backups;
  final BackupFilePicker files;
  final VoidCallback? onRestored;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _section = 0;
  bool _checking = false;
  bool _testFailed = false;
  String? _notificationMessage;

  String get _notificationState =>
      switch (widget.runtime?.availability.notifications) {
        NotificationAvailability.enabled =>
          _testFailed ? '上次通知提交失败' : '应用提醒已开启',
        NotificationAvailability.notEnabled => '尚未开启提醒',
        NotificationAvailability.denied => '系统已拒绝通知权限',
        _ => '系统通知暂不可用',
      };

  Future<void> _checkNotifications({bool test = false}) async {
    final runtime = widget.runtime;
    if (runtime == null || _checking) return;
    setState(() {
      _checking = true;
      _notificationMessage = null;
    });
    try {
      if (test) {
        final accepted = await runtime.testNotification();
        if (mounted) {
          setState(() {
            _testFailed = !accepted;
            _notificationMessage = accepted
                ? '测试通知已提交给系统。若没有显示，请检查系统通知设置、勿扰模式或专注助手。'
                : '测试通知提交失败。请检查系统通知设置后重试；访问申请仍可在应用中处理。';
          });
        }
      } else {
        await runtime.enableNotifications();
        if (mounted) {
          setState(
            () => _notificationMessage =
                switch (runtime.availability.notifications) {
                  NotificationAvailability.enabled =>
                    _testFailed
                        ? '应用提醒已开启；上次测试未能提交，请发送测试通知重试。'
                        : '应用提醒已开启，可以发送一条测试通知检查显示情况。',
                  NotificationAvailability.denied => '请在系统设置中允许本应用发送通知，然后重试。',
                  NotificationAvailability.notEnabled => '提醒尚未开启，可以再次尝试。',
                  NotificationAvailability.unavailable =>
                    '当前无法使用系统通知。访问申请仍会保留在“访问审批”中。',
                },
          );
        }
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Widget _general() => ListView(
    children: [
      const SectionHeading('访问申请通知'),
      const Text('Agent 提交新的访问申请时，通过系统通知提醒你。通知不包含资料内容。'),
      const SizedBox(height: 12),
      StatusLabel(
        _notificationState,
        active:
            !_testFailed &&
            widget.runtime?.availability.notifications ==
                NotificationAvailability.enabled,
        attention:
            _testFailed ||
            widget.runtime?.availability.notifications ==
                NotificationAvailability.denied,
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: widget.runtime == null || _checking
                ? null
                : () => _checkNotifications(),
            child: Text(_checking ? '正在检查…' : '开启或检查提醒'),
          ),
          OutlinedButton(
            onPressed:
                widget.runtime == null ||
                    _checking ||
                    widget.runtime!.availability.notifications !=
                        NotificationAvailability.enabled
                ? null
                : () => _checkNotifications(test: true),
            child: const Text('发送测试通知'),
          ),
        ],
      ),
      if (_notificationMessage != null)
        QuietNotice(
          _notificationMessage!,
          warning:
              _testFailed ||
              widget.runtime?.availability.notifications !=
                  NotificationAvailability.enabled,
        ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 26),
        child: Divider(),
      ),
      const SectionHeading('录入模板'),
      const Text(
        '保存常用的空白字段结构，方便重复录入同类资料。例如“服务器”模板预设地址、用户名和部署说明，每次新建时填写不同的值。模板不保存字段值。',
      ),
      const SizedBox(height: 14),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TemplateLibrary(owner: widget.owner),
            ),
          ),
          child: const Text('管理录入模板'),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 26),
        child: Divider(),
      ),
      const SectionHeading('应用运行'),
      Text(
        widget.runtime?.availability.tray == true
            ? '关闭窗口后继续在后台等待申请，可从托盘或菜单栏重新打开。完全退出会停止服务，并结束当前会话的授权。'
            : '完全退出会停止服务，并结束当前会话的授权。托盘或菜单栏不可用时，关闭按钮会保留窗口。',
      ),
      const SizedBox(height: 14),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: widget.runtime == null || widget.runtime!.quitting
              ? null
              : widget.runtime!.quit,
          icon: const Icon(Icons.power_settings_new, size: 17),
          label: Text(
            widget.runtime?.quitting == true
                ? '正在退出…'
                : widget.runtime?.shutdownFailed == true
                ? '重试保存并退出'
                : '完全退出',
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: UiSpace.page,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeading('设置', subtitle: '管理通知、备份与应用。'),
        Row(
          children: [
            for (final (index, label) in [(0, '通知与应用'), (1, '备份与恢复')])
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: _section == index
                            ? UiColors.accent
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: TextButton(
                    onPressed: () => setState(() => _section = index),
                    style: TextButton.styleFrom(
                      foregroundColor: _section == index
                          ? UiColors.accent
                          : UiColors.muted,
                    ),
                    child: Text(label),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Expanded(
          child: _section == 0
              ? _general()
              : widget.backups == null
              ? const QuietNotice('当前环境未连接备份服务。')
              : BackupLibrary(
                  backups: widget.backups!,
                  owner: widget.owner,
                  files: widget.files,
                  onRestored: widget.onRestored,
                  embedded: true,
                ),
        ),
      ],
    ),
  );
}
