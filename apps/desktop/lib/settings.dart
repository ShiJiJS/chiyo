import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'backups.dart';
import 'desktop_runtime.dart';
import 'templates.dart';
import 'ui.dart';
import 'prototype_ui.dart';
import 'settings_controls.dart';

enum SettingsSection {
  appearance,
  notifications,
  records,
  templates,
  backups,
  application,
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.owner,
    this.runtime,
    this.backups,
    required this.files,
    this.onRestored,
    this.onThemeChanged,
    this.themeBusy = false,
    this.themeError,
    this.initialSection = SettingsSection.appearance,
    this.navigationRevision = 0,
    this.onOpenApprovals,
  });
  final OwnerAccess owner;
  final DesktopRuntime? runtime;
  final InformationBackups? backups;
  final BackupFilePicker files;
  final VoidCallback? onRestored, onOpenApprovals;
  final ValueChanged<DesktopColorTheme>? onThemeChanged;
  final bool themeBusy;
  final String? themeError;
  final SettingsSection initialSection;
  final int navigationRevision;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late SettingsSection _section = widget.initialSection;
  bool _busy = false;
  String? _message, _error;
  bool? _notificationDraft;
  bool _testFailed = false;
  late int _timeout = widget.owner.requestLifetime.inMinutes;
  late int _retention = widget.owner.auditRetentionDays;
  static const _labels = ['外观', '通知', '请求与记录', '录入模板', '备份与恢复', '应用运行'];
  static const _descriptions = [
    '主题与界面颜色',
    '访问申请提醒',
    '等待时间与保留期限',
    '常用信息的字段结构',
    '加密导出与恢复密钥',
    '后台运行与本机服务',
  ];
  static const _intro = [
    '选择习惯的颜色，让每个工作区保持一致。',
    '新申请到来时及时提醒，通知中不包含信息内容。',
    '设置新申请的等待时间，以及历史记录的保留期限。',
    '保存常用字段结构，减少重复录入。',
    '使用独立恢复密钥，保存与恢复你的信息库。',
    '查看本机服务与窗口关闭后的运行方式。',
  ];
  static const _icons = [
    PrototypeIconGlyph.layers,
    PrototypeIconGlyph.inbox,
    PrototypeIconGlyph.clock,
    PrototypeIconGlyph.file,
    PrototypeIconGlyph.shield,
    PrototypeIconGlyph.tune,
  ];
  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationRevision != widget.navigationRevision) {
      _section = widget.initialSection;
    }
  }

  Future<void> _save(
    Future<void> Function() action, {
    String success = '设置已保存。',
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
      if (mounted && success.isNotEmpty) setState(() => _message = success);
    } catch (_) {
      if (mounted) setState(() => _error = '设置未保存，已保留你的选择。请检查存储或服务后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retentionSave() async {
    final days = _retention;
    if (days < widget.owner.auditRetentionDays) {
      final preview = await widget.owner.previewAuditRetention(days);
      if (!mounted) return;
      final confirmed = await showSettingsDialog<bool>(
        context: context,
        builder: (context) => SettingsDialog(
          title: '缩短记录保留期限',
          actions: [
            settingsAction(context, '取消', () => Navigator.pop(context, false)),
            settingsAction(
              context,
              '确认清理',
              () => Navigator.pop(context, true),
              primary: true,
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '将保留期限从 ${widget.owner.auditRetentionDays} 天改为 $days 天。',
                style: prototypeText(
                  context,
                  14,
                  height: 1.9,
                  color: UiPalette.of(context).muted,
                ),
              ),
              SettingsNotice(
                '将清理 ${preview.grants} 条授权、${preview.accesses} 条访问记录、${preview.requests} 条请求记录、${preview.organizations} 条已结束整理记录',
                '清理后无法从本机找回，信息库内容不受影响。',
                warning: true,
                icon: PrototypeIconGlyph.clock,
                contentPadding: const EdgeInsets.fromLTRB(19, 14, 19, 31),
                messageSize: 14,
                lineGap: 4,
                messageColor: UiPalette.of(context).muted,
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) {
        if (mounted) {
          setState(() => _retention = widget.owner.auditRetentionDays);
        }
        return;
      }
      await widget.owner.setAuditRetention(days, confirmation: preview);
    } else {
      await widget.owner.setAuditRetention(days);
    }
    if (mounted) setState(() => _message = '记录保留期限已保存。');
  }

  Widget _select(
    int value,
    Map<int, String> options,
    ValueChanged<int> changed,
    String identity,
  ) => Container(
    width: 140 * MediaQuery.textScalerOf(context).scale(1),
    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
    decoration: BoxDecoration(
      color: UiPalette.of(context).paper,
      border: Border.all(color: UiPalette.of(context).line),
      borderRadius: BorderRadius.circular(4),
    ),
    child: SizedBox(
      height: 20.5 * MediaQuery.textScalerOf(context).scale(1),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          key: ValueKey('$identity-$value'),
          value: value,
          isDense: true,
          isExpanded: true,
          style: prototypeText(context, 13),
          icon: const PrototypeSelectCaret(),
          iconSize: 10,
          dropdownColor: UiPalette.of(context).paper,
          borderRadius: BorderRadius.circular(4),
          items: options.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: _busy
              ? null
              : (v) {
                  if (v != null) changed(v);
                },
        ),
      ),
    ),
  );
  Widget _appearance() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('主题颜色', style: prototypeText(context, 16, weight: FontWeight.w700)),
      const SizedBox(height: 15),
      Text(
        '顶部颜色切换与这里同步，应用于所有页面。',
        style: prototypeText(
          context,
          13,
          color: UiPalette.of(context).muted,
          height: 1.9,
        ),
      ),
      const SizedBox(height: 21),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final theme in DesktopColorTheme.values) ...[
            if (theme.index > 0) const SizedBox(width: 18),
            Expanded(child: _themeCard(theme)),
          ],
        ],
      ),
    ],
  );
  Widget _themeCard(DesktopColorTheme theme) {
    final c = UiPalette.of(context), sample = UiPalette.forTheme(theme).accent;
    Color mix(double amount) => Color.lerp(Colors.white, sample, amount)!;
    final selected = widget.owner.colorTheme == theme;
    return TextButton(
      key: ValueKey('settings-theme-${theme.name}'),
      onPressed: widget.themeBusy || _busy
          ? null
          : () {
              if (widget.onThemeChanged != null) {
                widget.onThemeChanged!(theme);
              } else {
                _save(() => widget.owner.setColorTheme(theme));
              }
            },
      style: prototypeButton(
        context,
        size: 14,
        foreground: c.ink,
        background: c.paper,
        padding: const EdgeInsets.fromLTRB(17, 17, 17, 18),
        radius: 7,
        side: BorderSide(
          color: selected ? c.accent : c.line,
          width: selected ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 120,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: mix(.05),
              border: Border.all(color: mix(.3)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 32,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: mix(.14),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < 4; i++)
                          Container(
                            height: 5,
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: mix(.4),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 60,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: mix(.2)),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FractionallySizedBox(
                              widthFactor: .6,
                              child: Container(height: 7, color: sample),
                            ),
                            const SizedBox(height: 9),
                            Container(height: 4, color: mix(.15)),
                            const SizedBox(height: 9),
                            Container(height: 4, color: mix(.15)),
                          ],
                        ),
                        Positioned(
                          bottom: -2,
                          right: 0,
                          child: Container(
                            width: 38,
                            height: 13,
                            decoration: BoxDecoration(
                              color: sample,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              Expanded(
                child: Text(
                  ['紫棠', '松石', '雾蓝', '黑白'][theme.index],
                  style: prototypeText(context, 14),
                ),
              ),
              Flexible(
                fit: FlexFit.tight,
                child: Text(
                  selected ? '已选择' : '选择此色',
                  textAlign: TextAlign.right,
                  style: prototypeText(context, 12, color: c.muted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _inset(List<Widget> children) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
    decoration: BoxDecoration(
      color: UiPalette.of(context).paper,
      border: Border.all(color: UiPalette.of(context).line),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
  Widget _notifications() {
    final runtime = widget.runtime,
        enabled = _notificationDraft ?? widget.owner.notificationsEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _inset([
          SettingsRow(
            '访问申请通知',
            '新申请到来时发送系统提醒。关闭提醒后，仍可在访问审批中查看请求。',
            first: true,
            control: Semantics(
              toggled: enabled,
              label: '访问申请通知',
              child: SizedBox(
                width: 42,
                height: 24,
                child: TextButton(
                  key: const ValueKey('settings-notifications-switch'),
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _notificationDraft = !enabled);
                          _save(
                            () =>
                                widget.owner.setNotificationsEnabled(!enabled),
                          );
                        },
                  style: prototypeButton(
                    context,
                    background: enabled
                        ? UiPalette.of(context).accent
                        : UiPalette.of(context).line,
                    padding: const EdgeInsets.all(3),
                    radius: 20,
                  ),
                  child: AnimatedAlign(
                    duration: const Duration(milliseconds: 160),
                    alignment: enabled
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x22000000),
                            offset: Offset(0, 1),
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SettingsRow(
            _testFailed
                ? '上次通知提交失败'
                : widget.owner.notificationsEnabled
                ? '应用提醒已开启'
                : '应用提醒已关闭',
            '系统通知权限、勿扰模式和专注助手也会影响提醒是否显示。',
            control: settingsAction(
              context,
              '发送测试通知',
              _busy ||
                      !enabled ||
                      runtime == null ||
                      runtime.availability.notifications !=
                          NotificationAvailability.enabled
                  ? null
                  : () => _save(() async {
                      final ok = await runtime.testNotification();
                      if (mounted) {
                        setState(() {
                          _testFailed = !ok;
                          _message = ok
                              ? '测试通知已提交给系统；是否显示仍受系统通知设置影响。'
                              : '测试通知提交失败。访问申请仍保留在应用中。';
                        });
                      }
                    }, success: ''),
            ),
          ),
          SettingsRow(
            switch (runtime?.availability.notifications) {
              NotificationAvailability.enabled => '系统接受通知',
              NotificationAvailability.denied => '系统已拒绝通知权限',
              NotificationAvailability.notEnabled => '尚未开启系统提醒',
              _ => '系统通知暂不可用',
            },
            '通知状态与本机服务状态分别检查，通知不可用时仍可处理访问申请。',
            control: settingsAction(
              context,
              '开启或检查提醒',
              runtime == null || _busy
                  ? null
                  : () => _save(() async {
                      await runtime.enableNotifications();
                      if (mounted) {
                        setState(
                          () => _message =
                              switch (runtime.availability.notifications) {
                                NotificationAvailability.enabled =>
                                  '应用提醒已开启，可以发送一条测试通知检查显示情况。',
                                NotificationAvailability.denied =>
                                  '请在系统设置中允许本应用发送通知，然后重试。',
                                NotificationAvailability.notEnabled =>
                                  '提醒尚未开启，可以再次尝试。',
                                NotificationAvailability.unavailable =>
                                  '当前无法使用系统通知。访问申请仍会保留在“访问审批”中。',
                              },
                        );
                      }
                    }, success: ''),
            ),
          ),
        ]),
        const SettingsNotice(
          '提醒只包含请求概况',
          '不在系统通知中展示字段值、密钥或其他信息内容。打开应用后再查看申请范围。',
          icon: PrototypeIconGlyph.inbox,
          marginTop: 30,
          verticalPadding: 15.5,
        ),
      ],
    );
  }

  Widget _records() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('访问请求', style: prototypeText(context, 16, weight: FontWeight.w700)),
      const SizedBox(height: 15),
      SettingsRow(
        '等待审批时间',
        '超过等待时间，未处理的申请将自动过期。只应用于新申请。',
        control: _select(
          _timeout,
          {
            5: '5 分钟',
            15: '15 分钟',
            30: '30 分钟',
            60: '1 小时',
            120: '2 小时',
            if (![5, 15, 30, 60, 120].contains(_timeout))
              _timeout: '$_timeout 分钟',
          },
          (v) {
            setState(() => _timeout = v);
            _save(() => widget.owner.setRequestLifetime(Duration(minutes: v)));
          },
          'timeout',
        ),
      ),
      SettingsRow(
        '授权期限',
        '每次批准时单独选择，且只在申请方的当前会话中有效。整理资料的授权最长为 30 分钟。',
        control: TextButton(
          onPressed: widget.onOpenApprovals,
          style: prototypeButton(
            context,
            size: 13,
            foreground: UiPalette.of(context).strong,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          ),
          child: const Text('前往访问审批 →'),
        ),
      ),
      const SizedBox(height: 30),
      Text(
        '授权与访问记录',
        style: prototypeText(context, 16, weight: FontWeight.w700),
      ),
      const SizedBox(height: 15),
      SettingsRow(
        '记录保留期限',
        '只保留授权范围与访问事件，不记录字段值。缩短期限前会先展示要清理的记录数量。',
        control: _select(
          _retention,
          {
            for (final d in [30, 90, 180, 365]) d: '$d 天',
          },
          (v) {
            setState(() => _retention = v);
            _save(_retentionSave, success: '');
          },
          'retention',
        ),
      ),
      if (_error != null)
        Align(
          alignment: Alignment.centerRight,
          child: settingsAction(
            context,
            '重试保存设置',
            () => _save(() async {
              await widget.owner.setRequestLifetime(
                Duration(minutes: _timeout),
              );
              await _retentionSave();
            }),
          ),
        ),
      const SettingsNotice(
        '内容有独立的保留期限',
        '回收站和内容修改版本保留 30 天。这里的记录保留期限影响请求、授权、访问与已结束整理记录，不会延长内容的可恢复时间；待处理整理仍保留在请求收件箱。',
        icon: PrototypeIconGlyph.clock,
      ),
    ],
  );
  Widget _application() => _inset([
    SettingsRow(
      widget.owner.serviceAvailable ? '本机服务运行中' : '本机服务暂不可用',
      '应用为 Agent 提供访问请求入口；信息的实际读取需要你的授权。',
      first: true,
      control: Text(
        widget.owner.serviceAvailable ? '● 已连接' : '未连接',
        style: prototypeText(
          context,
          12,
          color: widget.owner.serviceAvailable
              ? UiPalette.of(context).statusLive
              : UiPalette.of(context).statusAttention,
        ),
      ),
    ),
    SettingsRow(
      '关闭窗口后继续运行',
      widget.runtime?.availability.tray == true
          ? '关闭窗口会收起到系统托盘。点击托盘图标，可以重新打开审批与信息库。'
          : '托盘或菜单栏当前不可用，关闭按钮会保留窗口，避免无法重新打开。',
      control: Text(
        widget.runtime?.availability.tray == true ? '托盘可用' : '托盘不可用',
        style: prototypeText(context, 12),
      ),
    ),
    SettingsRow(
      '完全退出应用',
      '将停止本机服务，并结束当前会话中的授权。需要时可重新启动应用。',
      control: settingsAction(
        context,
        widget.runtime?.shutdownFailed == true ? '重试保存并退出' : '完全退出',
        widget.runtime == null || widget.runtime!.quitting
            ? null
            : () async {
                final confirm = await showSettingsDialog<bool>(
                  context: context,
                  builder: (context) => SettingsDialog(
                    title: '完全退出应用',
                    actions: [
                      settingsAction(
                        context,
                        '继续运行',
                        () => Navigator.pop(context, false),
                      ),
                      settingsAction(
                        context,
                        '完全退出',
                        () => Navigator.pop(context, true),
                        primary: true,
                      ),
                    ],
                    child: const Text('将停止本机服务，并结束当前会话中的授权。'),
                  ),
                );
                if (confirm == true) await widget.runtime!.quit();
              },
      ),
    ),
  ]);
  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 260,
          padding: const EdgeInsets.fromLTRB(19, 28, 19, 28),
          decoration: BoxDecoration(
            color: c.rail,
            border: Border(right: BorderSide(color: c.line)),
          ),
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 0, 13, 24),
                child: Text(
                  '设置',
                  style: prototypeText(context, 21, weight: FontWeight.w700),
                ),
              ),
              for (final s in SettingsSection.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: TextButton(
                    key: ValueKey('settings-section-${s.name}'),
                    onPressed: () => setState(() {
                      _section = s;
                      _message = null;
                      _error = null;
                    }),
                    style: prototypeButton(
                      context,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 15,
                      ),
                      radius: 6,
                      background: _section == s
                          ? c.selected
                          : Colors.transparent,
                      foreground: _section == s ? c.strong : c.ink,
                    ),
                    child: Row(
                      children: [
                        PrototypeIcon(
                          _icons[s.index],
                          color: _section == s ? c.strong : c.ink,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _labels[s.index],
                                style: prototypeText(
                                  context,
                                  14,
                                  weight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _descriptions[s.index],
                                style: prototypeText(
                                  context,
                                  12,
                                  color: c.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 940),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.only(top: 6, bottom: 27),
                      margin: const EdgeInsets.only(bottom: 28),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: c.line)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _labels[_section.index],
                            style: prototypeText(
                              context,
                              30,
                              family: 'SimSun',
                              weight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _intro[_section.index],
                            style: prototypeText(
                              context,
                              14,
                              color: c.muted,
                              height: 1.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                    switch (_section) {
                      SettingsSection.appearance => _appearance(),
                      SettingsSection.notifications => _notifications(),
                      SettingsSection.records => _records(),
                      SettingsSection.templates => TemplateLibrary(
                        owner: widget.owner,
                        embedded: true,
                      ),
                      SettingsSection.backups =>
                        widget.backups == null
                            ? const SettingsNotice(
                                '备份服务未连接',
                                '请检查信息库与本机服务后重试。',
                                warning: true,
                              )
                            : BackupLibrary(
                                backups: widget.backups!,
                                owner: widget.owner,
                                files: widget.files,
                                onRestored: () {
                                  setState(() {
                                    _timeout =
                                        widget.owner.requestLifetime.inMinutes;
                                    _retention =
                                        widget.owner.auditRetentionDays;
                                    _notificationDraft = null;
                                  });
                                  widget.onRestored?.call();
                                },
                                embedded: true,
                              ),
                      SettingsSection.application => _application(),
                    },
                    if (_error != null || widget.themeError != null)
                      SettingsNotice(
                        '设置未保存',
                        _error ?? widget.themeError!,
                        error: true,
                      ),
                    if (_error != null &&
                        _section == SettingsSection.notifications)
                      Align(
                        alignment: Alignment.centerRight,
                        child: settingsAction(
                          context,
                          '重试保存设置',
                          () => _save(
                            () => widget.owner.setNotificationsEnabled(
                              _notificationDraft ??
                                  widget.owner.notificationsEnabled,
                            ),
                          ),
                        ),
                      ),
                    if (_message != null && _message!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _message!,
                          style: prototypeText(context, 13),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
