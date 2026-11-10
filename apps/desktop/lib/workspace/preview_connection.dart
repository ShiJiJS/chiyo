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
    this.embedded = false,
    this.syncEnabled = true,
    this.onModeChanged,
    required this.onBack,
    required this.onConnected,
    required this.onDisconnect,
    required this.onSettings,
  });
  final bool disconnected;
  final bool embedded, syncEnabled;
  final ValueChanged<bool>? onModeChanged;
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
  late bool _syncEnabled;
  @override
  void initState() {
    super.initState();
    _syncEnabled = widget.syncEnabled;
  }

  String? _error;
  Future<void> _connect() async {
    if (!_syncEnabled && widget.embedded) {
      widget.onModeChanged?.call(false);
      widget.onConnected();
      return;
    }
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
    if (mounted) {
      setState(() => _busy = false);
      widget.onModeChanged?.call(true);
      widget.onConnected();
    }
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
            if (!widget.embedded)
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
              child: Align(
                alignment: widget.embedded
                    ? Alignment.topLeft
                    : Alignment.center,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    32,
                    widget.embedded ? 32 : 0,
                    32,
                    40,
                  ),
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
                          widget.disconnected ? '连接已断开' : '存储与同步',
                          style: libraryHeading(context, 28),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          widget.disconnected
                              ? '恢复连接后，就能继续查看资料和处理申请。'
                              : '资料保存在本机，可选择同步到自己的服务器。',
                          style: libraryText(context, 14, color: c.muted),
                        ),
                        const SizedBox(height: 28),
                        if (widget.embedded) ...[
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '同步到服务器',
                                      style: libraryHeading(context, 16),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '关闭后，仅在这台电脑上保存资料和处理审批。',
                                      style: libraryText(
                                        context,
                                        13,
                                        color: c.muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 20),
                              DesktopToggle(
                                value: _syncEnabled,
                                onChanged: _busy
                                    ? null
                                    : (value) => setState(() {
                                        _syncEnabled = value;
                                        _error = null;
                                      }),
                              ),
                            ],
                          ),
                          const SizedBox(height: 28),
                          if (!_syncEnabled) ...[
                            Text('本地模式', style: libraryHeading(context, 16)),
                            const SizedBox(height: 8),
                            Text(
                              '资料、文件和凭据加密保存在这台电脑。无需连接服务器，也能接收 AI 申请和审批。',
                              style: libraryText(
                                context,
                                14,
                                color: c.muted,
                                height: 1.8,
                              ),
                            ),
                          ],
                        ],
                        if (widget.disconnected) ...[
                          Text('家庭 NAS', style: libraryHeading(context, 16)),
                          const SizedBox(height: 6),
                          SelectableText(
                            _address.text,
                            style: libraryText(context, 14, color: c.muted),
                          ),
                        ] else if (_syncEnabled) ...[
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
                                widget.disconnected
                                    ? '重新连接'
                                    : _syncEnabled
                                    ? '保存并连接'
                                    : '使用本地模式',
                              ),
                            ),
                            const SizedBox(width: 12),
                            if (!widget.embedded)
                              DesktopButton(
                                kind: DesktopButtonKind.quiet,
                                onPressed: _busy
                                    ? null
                                    : widget.disconnected
                                    ? widget.onSettings
                                    : widget.onBack,
                                child: Text(
                                  widget.disconnected ? '连接设置' : '取消',
                                ),
                              ),
                            if (!widget.disconnected &&
                                _syncEnabled &&
                                widget.syncEnabled) ...[
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
