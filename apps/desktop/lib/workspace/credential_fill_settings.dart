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

class _CredentialFillSettingsState extends State<CredentialFillSettings>
    with WidgetsBindingObserver {
  CredentialFillPermissionState? _state;
  bool _busy = false;

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

  Future<void> _refresh({bool request = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await (request
        ? widget.permissions.request()
        : widget.permissions.read());
    if (!mounted) return;
    setState(() {
      _state = result;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = UiPalette.of(context);
    final ready = _state == CredentialFillPermissionState.ready;
    return SettingsPageContent(
      title: '凭据填写',
      description: '在这台电脑上，将已批准使用的密码填入应用或浏览器。',
      children: [
        SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('应用与浏览器密码框', style: libraryHeading(context, 18)),
                  const SizedBox(height: 12),
                  if (_busy)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(switch (_state) {
                      CredentialFillPermissionState.ready =>
                        widget.permissions.canRequest ? '填写权限已开启' : '填写模块已就绪',
                      CredentialFillPermissionState.permissionRequired =>
                        '需要开启辅助功能权限',
                      _ => '当前设备的填写功能尚不可用',
                    }, style: libraryText(context, 14)),
                  const SizedBox(height: 10),
                  Text(
                    ready
                        ? '选中目标密码框后即可申请填写。部分应用的密码框可能不支持。'
                        : '填写权限只用于向密码框输入；使用哪一项凭据仍由你审批。',
                    style: libraryText(context, 13, color: palette.muted),
                  ),
                  if (!ready) ...[
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        if (widget.permissions.canRequest)
                          DesktopButton(
                            key: const ValueKey('fill-request-permission'),
                            onPressed: _busy
                                ? null
                                : () => _refresh(request: true),
                            child: const Text('开启填写权限'),
                          ),
                        DesktopButton(
                          key: const ValueKey('fill-check-permission'),
                          onPressed: _busy ? null : _refresh,
                          child: const Text('重新检查'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
