import 'package:flutter/material.dart';
import '../credential_fill_permissions.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';
import 'settings_layout.dart';

class CredentialFillSettings extends StatefulWidget {
  const CredentialFillSettings({
    super.key,
    this.permissions = const CredentialFillPermissions(),
  });
  final CredentialFillPermissions permissions;
  @override
  State<CredentialFillSettings> createState() => _CredentialFillSettingsState();
}

enum _Action { read, native, focus }

class _CredentialFillSettingsState extends State<CredentialFillSettings>
    with WidgetsBindingObserver {
  CredentialFillPermissionReport? _report;
  bool _busy = false, _readAgain = false, _help = false, _focus = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh([_Action action = _Action.read]) async {
    if (_busy) {
      _readAgain = true;
      return;
    }
    do {
      _readAgain = false;
      setState(() {
        _busy = true;
        _actionError = null;
      });
      CredentialFillPermissionReport result;
      try {
        result = await switch (action) {
          _Action.read => widget.permissions.readReport(),
          _Action.native => widget.permissions.requestNative(),
          _Action.focus => widget.permissions.requestFocus(),
        };
      } on Object {
        result = const CredentialFillPermissionReport.unavailable();
      }
      if (!mounted) return;
      final needsSettings = switch (action) {
        _Action.native =>
          result.native == CredentialFillPermissionState.permissionRequired,
        _Action.focus =>
          result.focus == CredentialFillPermissionState.permissionRequired,
        _ => false,
      };
      setState(() {
        _report = result;
        if (needsSettings) _help = true;
      });
      if (needsSettings && !await widget.permissions.openSettings()) {
        if (!mounted) return;
        setState(() => _actionError = '未能打开系统设置，请手动进入“隐私与安全性”中的辅助功能设置。');
      }
      if (!mounted) return;
      setState(() => _busy = false);
      action = _Action.read;
    } while (_readAgain);
  }

  Future<void> _reveal() async {
    final opened = await widget.permissions.revealApplication();
    if (!mounted) return;
    setState(() => _actionError = opened ? null : '未能定位当前程序，请核对下方安装位置。');
  }

  Widget _text(String value, {bool muted = false}) => Text(
    value,
    style: libraryText(
      context,
      13,
      color: muted ? UiPalette.of(context).muted : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final native = _report?.native, mac = widget.permissions.canRequest;
    final ready = native == CredentialFillPermissionState.ready;
    return SettingsPageContent(
      title: '凭据填写',
      description: '检查本机应用的后台填写权限。浏览器通过各自的连接接口填写；使用凭据仍需你批准。',
      children: [
        SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('原生应用后台填写', style: libraryHeading(context, 18)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (_busy) ...[
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 9),
                      ],
                      Expanded(
                        child: Text(
                          _busy
                              ? '正在检查填写权限…'
                              : switch (native) {
                                  CredentialFillPermissionState.ready =>
                                    mac ? '后台填写权限已开启' : '填写模块已就绪',
                                  CredentialFillPermissionState
                                      .permissionRequired =>
                                    '尚未获得辅助功能权限',
                                  _ =>
                                    _report?.errorCode == 'busy'
                                        ? '填写任务进行中，稍后可重新检查'
                                        : '无法连接填写组件',
                                },
                          style: libraryText(context, 14),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _text(
                    native == null
                        ? '正在读取实际填写组件的权限状态。'
                        : ready
                        ? '选定密码框后，知予还会检查它是否支持后台填写；填写过程不切换前台应用或输入焦点。'
                        : native == CredentialFillPermissionState.unavailable
                        ? '当前还无法确认权限状态。请先重新检查；这不表示你没有打开系统开关。'
                        : 'macOS 需要允许知予访问其他应用的密码框。知予只会在你批准后填写，不会自动提交。',
                    muted: true,
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (mac &&
                          native ==
                              CredentialFillPermissionState.permissionRequired)
                        DesktopButton(
                          key: const ValueKey('fill-request-permission'),
                          onPressed: _busy
                              ? null
                              : () => _refresh(_Action.native),
                          child: const Text('前往系统设置'),
                        ),
                      DesktopButton(
                        key: const ValueKey('fill-check-permission'),
                        onPressed: _busy ? null : () => _refresh(),
                        child: const Text('重新检查'),
                      ),
                      if (mac &&
                          native !=
                              CredentialFillPermissionState.permissionRequired)
                        DesktopButton(
                          onPressed: () => setState(() => _help = !_help),
                          child: Text(_help ? '收起授权说明' : '查看授权说明'),
                        ),
                    ],
                  ),
                  if (mac &&
                      (_help ||
                          native ==
                              CredentialFillPermissionState
                                  .permissionRequired)) ...[
                    const SizedBox(height: 22),
                    Text('在系统中允许当前版本的知予', style: libraryHeading(context, 14)),
                    const SizedBox(height: 10),
                    _text(
                      '1. 在系统设置的“隐私与安全性”中，找到 ${_report?.applicationName ?? 'chiyo'}。\n2. 打开它的开关。系统页面可能显示为“辅助功能”或“设备控制和数据访问”。\n3. 回到知予后会自动检查，也可以点击“重新检查”。',
                    ),
                    if (_report?.applicationPath case final String path) ...[
                      const SizedBox(height: 12),
                      Text(
                        '当前安装位置',
                        style: libraryText(
                          context,
                          12,
                          color: UiPalette.of(context).muted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(path, style: libraryText(context, 13)),
                      const SizedBox(height: 8),
                      DesktopButton(
                        key: const ValueKey('fill-reveal-application'),
                        onPressed: _busy ? null : _reveal,
                        child: const Text('在访达中显示当前程序'),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Text('已经开启，仍未识别？', style: libraryHeading(context, 14)),
                    const SizedBox(height: 7),
                    _text(
                      '更新版本后，macOS 可能仍保留旧程序的授权记录。核对当前安装位置；如有旧的 chiyo 记录，在系统列表移除它后，用“＋”重新添加当前程序，再回到这里检查。',
                      muted: true,
                    ),
                  ],
                  if (_actionError case final String error) ...[
                    const SizedBox(height: 12),
                    _text(error),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('浏览器表单填写', style: libraryHeading(context, 18)),
                  const SizedBox(height: 10),
                  _text(
                    'Chrome 和 Ego 使用各自的浏览器连接接口，不需要上方的辅助功能权限。使用时会检查浏览器连接、页面和表单。',
                    muted: true,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        DesktopButton(
          key: const ValueKey('fill-focus-details'),
          onPressed: () => setState(() => _focus = !_focus),
          child: Text(_focus ? '收起兼容填写方式' : '兼容方式：按焦点输入'),
        ),
        if (_focus) ...[
          const SizedBox(height: 12),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('按焦点输入', style: libraryHeading(context, 16)),
                    const SizedBox(height: 10),
                    _text('这种方式向当前选中的密码框发送输入，系统要求与后台填写分别检查。', muted: true),
                    const SizedBox(height: 10),
                    _text(switch (_report?.focus) {
                      CredentialFillPermissionState.ready => '兼容填写已就绪',
                      CredentialFillPermissionState.permissionRequired =>
                        '兼容填写所需的系统权限尚未就绪',
                      _ => '无法确认兼容填写状态',
                    }),
                    if (mac &&
                        _report?.focus ==
                            CredentialFillPermissionState
                                .permissionRequired) ...[
                      const SizedBox(height: 14),
                      DesktopButton(
                        key: const ValueKey('fill-request-focus-permission'),
                        onPressed: _busy ? null : () => _refresh(_Action.focus),
                        child: const Text('设置兼容填写权限'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
