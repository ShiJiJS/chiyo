import 'package:flutter/material.dart';
import '../desktop_controls.dart';
import '../ui_palette.dart';
import 'library_widgets.dart';

/// Presentation-only connection states for the isolated native prototype.
/// This widget never creates an HTTP client or stores connection credentials.
class PreviewConnection extends StatefulWidget {
  const PreviewConnection({
    super.key,
    required this.disconnected,
    required this.onBack,
    required this.onConnected,
    required this.onDisconnect,
    required this.onSettings,
  });
  final bool disconnected;
  final VoidCallback onBack, onConnected, onDisconnect, onSettings;
  @override
  State<PreviewConnection> createState() => _PreviewConnectionState();
}

class _PreviewConnectionState extends State<PreviewConnection> {
  final _address = TextEditingController(
    text: 'https://nas.example.local:47126',
  );
  final _token = TextEditingController(text: 'preview-connection-token');
  bool _busy = false, _visible = false;
  String? _error;
  Future<void> _connect() async {
    final uri = Uri.tryParse(_address.text);
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      setState(() => _error = '请填写完整的服务器地址，例如 https://nas.local:47126');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Only a simulated delay; no user-entered address is contacted.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) widget.onConnected();
  }

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context);
    return Scaffold(
      backgroundColor: c.rail,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  DesktopButton(
                    kind: DesktopButtonKind.quiet,
                    leading: const Icon(Icons.arrow_back, size: 18),
                    onPressed: _busy ? null : widget.onBack,
                    child: const Text('返回工作区'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: c.selected,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(
                              widget.disconnected
                                  ? Icons.cloud_off_outlined
                                  : Icons.dns_outlined,
                              color: c.accent,
                              size: 30,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          widget.disconnected ? '连接已断开' : '服务器连接',
                          style: libraryHeading(context, 28),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          widget.disconnected
                              ? '恢复连接后，就能继续查看资料和处理申请。'
                              : '资料和审批保存在这台服务器上。',
                          style: libraryText(context, 14, color: c.muted),
                        ),
                        const SizedBox(height: 28),
                        if (widget.disconnected) ...[
                          Text('家庭 NAS', style: libraryHeading(context, 16)),
                          const SizedBox(height: 6),
                          SelectableText(
                            _address.text,
                            style: libraryText(context, 14, color: c.muted),
                          ),
                        ] else ...[
                          Text(
                            '服务器地址',
                            style: libraryText(
                              context,
                              14,
                              weight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          DesktopTextField(
                            controller: _address,
                            enabled: !_busy,
                            decoration: const InputDecoration(
                              hintText: 'https://nas.local:47126',
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            '连接 Token',
                            style: libraryText(
                              context,
                              14,
                              weight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _token,
                            enabled: !_busy,
                            obscureText: !_visible,
                            decoration: InputDecoration(
                              suffixIcon: IconButton(
                                tooltip: _visible ? '隐藏 Token' : '显示 Token',
                                onPressed: () =>
                                    setState(() => _visible = !_visible),
                                icon: Icon(
                                  _visible
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            shape: const Border(),
                            collapsedShape: const Border(),
                            title: Text('证书', style: libraryText(context, 13)),
                            children: [
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  Icons.verified_user_outlined,
                                  color: c.success,
                                ),
                                title: const Text('已信任此服务器证书'),
                                subtitle: const Text('连接时核对服务器身份。'),
                              ),
                            ],
                          ),
                        ],
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              _error!,
                              style: libraryText(context, 13, color: c.danger),
                            ),
                          ),
                        const SizedBox(height: 28),
                        Row(
                          children: [
                            DesktopButton(
                              kind: DesktopButtonKind.primary,
                              busy: _busy,
                              onPressed: _busy ? null : _connect,
                              child: Text(
                                widget.disconnected ? '重新连接' : '保存并连接',
                              ),
                            ),
                            const SizedBox(width: 12),
                            DesktopButton(
                              kind: DesktopButtonKind.quiet,
                              onPressed: _busy
                                  ? null
                                  : widget.disconnected
                                  ? widget.onSettings
                                  : widget.onBack,
                              child: Text(widget.disconnected ? '连接设置' : '取消'),
                            ),
                            if (!widget.disconnected) ...[
                              const Spacer(),
                              TextButton(
                                onPressed: _busy ? null : widget.onDisconnect,
                                child: Text(
                                  '断开连接',
                                  style: TextStyle(color: c.danger),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
