import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../desktop_controls.dart';
import '../desktop_interaction_host.dart';
import '../desktop_motion.dart';
import '../desktop_scroll.dart';
import '../prototype_dialog.dart';
import '../ui_palette.dart';
import '../window_frame.dart';
import '../workspace/library_widgets.dart';
import '../workspace/workspace_sync.dart';
import '../workspace/zhiyu_theme.dart';

enum SetupStorageMode { local, server }

enum _Panel { mode, connection, initialization }

/// All configuration in this prototype lives in memory. Import, connection,
/// initialization and Token replacement are simulated, never OS/network calls.
class SetupPreviewDraft extends ChangeNotifier implements WorkspaceSync {
  final address = TextEditingController();
  final token = TextEditingController();
  final host = TextEditingController(text: '192.168.1.20');
  final port = TextEditingController(text: '47126');
  SetupStorageMode selected = SetupStorageMode.local;
  SetupStorageMode saved = SetupStorageMode.local;
  bool hasCertificate = false;
  bool verified = false;
  String? connectionFile;
  @override
  bool busy = false;
  @override
  DateTime? updatedAt;
  bool _disposed = false;
  int _tokenRevision = 0;

  @override
  bool get enabled => saved == SetupStorageMode.server;
  @override
  bool get needsReview => false;
  @override
  Object? get failure => null;

  void importConnection() {
    address.text = 'https://${host.text.trim()}:${port.text.trim()}';
    token.text = 'chiyo_preview_connection_token_not_a_real_credential';
    selected = SetupStorageMode.server;
    hasCertificate = true;
    verified = false;
    connectionFile = '家庭 NAS.chiyo-connection';
    notifyListeners();
  }

  void replaceToken() {
    _tokenRevision++;
    token.text = 'chiyo_preview_replaced_token_$_tokenRevision';
    notifyListeners();
  }

  Future<void> finish() async {
    if (selected == SetupStorageMode.server) await synchronize();
    if (_disposed) return;
    saved = selected;
    verified = enabled;
    notifyListeners();
  }

  @override
  Future<void> synchronize() async {
    if (busy) return;
    busy = true;
    notifyListeners();
    // A short in-memory transition lets the loading state be reviewed. There
    // is deliberately no OwnerClient or fake production success receipt.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (_disposed) return;
    busy = false;
    updatedAt = DateTime.now();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final controller in [address, token, host, port]) {
      controller.dispose();
    }
    super.dispose();
  }
}

class SetupConfigurationPreview extends StatefulWidget {
  const SetupConfigurationPreview({
    super.key,
    required this.draft,
    required this.onComplete,
    this.onBack,
    this.embedded = false,
  });
  final SetupPreviewDraft draft;
  final VoidCallback onComplete;
  final VoidCallback? onBack;
  final bool embedded;

  @override
  State<SetupConfigurationPreview> createState() =>
      _SetupConfigurationPreviewState();
}

class _SetupConfigurationPreviewState extends State<SetupConfigurationPreview> {
  _Panel _panel = _Panel.mode;
  bool _visible = false, _certificateDetails = false, _copied = false;
  String? _error;
  SetupPreviewDraft get d => widget.draft;

  void _go(_Panel panel) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _panel = panel;
      _error = null;
    });
  }

  Future<void> _finish() async {
    if (d.busy) return;
    if (d.selected == SetupStorageMode.server) {
      final uri = Uri.tryParse(d.address.text.trim());
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        setState(() => _error = '请填写完整的 HTTPS 服务器地址。');
        return;
      }
      if (d.token.text.trim().isEmpty) {
        setState(() => _error = '请填写服务器初始化时生成的 Token。');
        return;
      }
    }
    setState(() => _error = null);
    await d.finish();
    if (mounted) widget.onComplete();
  }

  Future<void> _import(BuildContext surfaceContext) async {
    final imported = await showDesktopDialog<bool>(
      surfaceContext,
      builder: (context) => PrototypeDialog(
        title: '导入连接文件',
        onClose: () => Navigator.pop(context),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _note(context, '选择服务器初始化时导出的连接文件。'),
            const SizedBox(height: 20),
            _InfoRow(
              icon: Icons.description_outlined,
              title: '家庭 NAS.chiyo-connection',
              description: '服务器地址、接入 Token 和公开证书',
            ),
          ],
        ),
        actions: [
          DesktopButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          DesktopButton(
            key: const ValueKey('setup-import-confirm'),
            kind: DesktopButtonKind.primary,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (imported != true || !mounted) return;
    d.importConnection();
    _go(_Panel.connection);
  }

  Future<void> _replaceToken(BuildContext surfaceContext) async {
    final replace = await showDesktopDialog<bool>(
      surfaceContext,
      builder: (context) => PrototypeDialog(
        title: '更换服务器 Token',
        onClose: () => Navigator.pop(context),
        body: _note(
          context,
          '自动生成新的接入 Token，并更新这台电脑的连接。其他电脑需要重新导入连接配置；已有资料和凭据不受影响。',
        ),
        actions: [
          DesktopButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          DesktopButton(
            key: const ValueKey('setup-replace-confirm'),
            kind: DesktopButtonKind.primary,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('生成并更换'),
          ),
        ],
      ),
    );
    if (replace != true || !mounted) return;
    d.replaceToken();
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: d,
    builder: (context, _) {
      if (widget.embedded) return _surface(context);
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '知予 · 配置预览',
        theme: zhiyuTheme(Brightness.light),
        darkTheme: zhiyuTheme(Brightness.dark),
        scrollBehavior: const DesktopScrollBehavior(scrollbarGutter: 9),
        builder: (_, child) =>
            DesktopInteractionHost(child: DesktopWindowFrame(child: child!)),
        home: Builder(builder: _standalone),
      );
    },
  );

  Widget _standalone(BuildContext context) {
    final c = UiPalette.of(context);
    final wide =
        MediaQuery.sizeOf(context).width >= 1000 &&
        MediaQuery.textScalerOf(context).scale(1) < 1.6;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(wide ? 36 : 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Column(
                children: [
                  Row(
                    children: [
                      Image.asset(
                        'assets/branding/chiyo-icon.png',
                        width: 32,
                        height: 32,
                      ),
                      const SizedBox(width: 12),
                      Text('知予', style: libraryHeading(context, 22)),
                      const Spacer(),
                      _note(context, '首次配置'),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: c.paper,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: c.line),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (wide) _rail(context),
                          Expanded(child: _surface(context)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rail(BuildContext context) {
    final c = UiPalette.of(context);
    return Container(
      width: 232,
      padding: const EdgeInsets.fromLTRB(28, 34, 28, 28),
      decoration: BoxDecoration(
        color: c.rail,
        border: Border(right: BorderSide(color: c.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('从这里开始', style: libraryHeading(context, 18)),
          const SizedBox(height: 12),
          _note(context, '选择资料的保存方式，\n随时可以在设置里调整。'),
          const SizedBox(height: 38),
          for (final (index, title) in ['使用方式', '连接设置'].indexed) ...[
            Row(
              children: [
                AnimatedContainer(
                  duration: DesktopMotion.feedbackOf(context),
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (index == 0) == (_panel == _Panel.mode)
                        ? c.accent
                        : c.paper,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.line),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: libraryText(
                      context,
                      13,
                      color: (index == 0) == (_panel == _Panel.mode)
                          ? c.onAccent
                          : c.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(title, style: libraryText(context, 14)),
              ],
            ),
            const SizedBox(height: 22),
          ],
          const Spacer(),
          Icon(Icons.lock_outline, size: 21, color: c.muted),
          const SizedBox(height: 10),
          _note(context, '资料、文件和凭据\n均加密保存。'),
        ],
      ),
    );
  }

  Widget _surface(BuildContext context) {
    final title = switch (_panel) {
      _Panel.mode => widget.embedded ? '存储与同步' : '你的资料，放在哪里？',
      _Panel.connection => '连接你的服务器',
      _Panel.initialization => '初始化服务器',
    };
    final subtitle = switch (_panel) {
      _Panel.mode => '先在本机使用，或连接自己的 NAS／服务器同步资料。',
      _Panel.connection => '导入连接文件即可，也可以手动填写。',
      _Panel.initialization => '在 NAS 或服务器上运行一次，自动准备证书和接入 Token。',
    };
    return ColoredBox(
      color: UiPalette.of(context).paper,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('setup-body'),
              padding: const EdgeInsets.all(32),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 690),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(title, style: libraryHeading(context, 28)),
                      const SizedBox(height: 10),
                      _note(context, subtitle),
                      const SizedBox(height: 30),
                      DesktopEntrance(
                        key: ValueKey(_panel),
                        child: switch (_panel) {
                          _Panel.mode => _mode(context),
                          _Panel.connection => _connection(context),
                          _Panel.initialization => _initialization(context),
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          key: const ValueKey('setup-error'),
                          style: libraryText(
                            context,
                            14,
                            color: UiPalette.of(context).danger,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          _footer(context),
        ],
      ),
    );
  }

  Widget _mode(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final mode in SetupStorageMode.values) ...[
        _ModeChoice(
          mode: mode,
          selected: d.selected == mode,
          onSelect: () => setState(() {
            d.selected = mode;
            _error = null;
          }),
        ),
        const SizedBox(height: 16),
      ],
      const SizedBox(height: 8),
      _InfoRow(
        icon: Icons.smart_toy_outlined,
        title: '两种方式都能接收 AI 申请',
        description: '由 AI 发起，你在 App 中审批和管理资料。',
      ),
    ],
  );

  Widget _connection(BuildContext context) {
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            DesktopButton(
              key: const ValueKey('setup-import'),
              leading: const Icon(Icons.file_open_outlined),
              onPressed: d.busy ? null : () => _import(context),
              child: const Text('导入连接文件'),
            ),
            if (d.connectionFile != null) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  d.connectionFile!,
                  overflow: TextOverflow.ellipsis,
                  style: libraryText(context, 13, color: c.muted),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
        DesktopTextField(
          controller: d.address,
          enabled: !d.busy,
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: 'https://192.168.1.20:47126',
          ),
        ),
        const SizedBox(height: 4),
        DesktopTextField(
          controller: d.token,
          enabled: !d.busy,
          obscureText: !_visible,
          inlineSecret: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '接入 Token',
            hintText: '从服务器初始化结果中获取',
            suffixIcon: IconButton(
              key: const ValueKey('setup-token-eye'),
              tooltip: _visible ? '隐藏 Token' : '显示 Token',
              onPressed: d.busy
                  ? null
                  : () => setState(() => _visible = !_visible),
              icon: Icon(
                _visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
              ),
            ),
          ),
        ),
        if (widget.embedded && d.verified)
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopButton(
              key: const ValueKey('setup-replace-token'),
              leading: const Icon(Icons.autorenew),
              onPressed: d.busy ? null : () => _replaceToken(context),
              child: const Text('更换服务器 Token'),
            ),
          ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DesktopButton(
                kind: DesktopButtonKind.quiet,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.all(14),
                leading: Icon(
                  Icons.verified_user_outlined,
                  color: d.hasCertificate ? c.success : c.muted,
                ),
                onPressed: () =>
                    setState(() => _certificateDetails = !_certificateDetails),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(d.hasCertificate ? '已导入服务器证书' : '服务器证书'),
                    ),
                    Icon(
                      _certificateDetails
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 18,
                    ),
                  ],
                ),
              ),
              if (_certificateDetails)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _note(
                        context,
                        d.hasCertificate
                            ? '家庭 NAS 的公开证书，仅用于核对这台服务器。'
                            : '有效的公开证书可直接连接；自建证书请从服务器导入公开 CA 证书。',
                      ),
                      const SizedBox(height: 12),
                      DesktopButton(
                        onPressed: () =>
                            setState(() => d.hasCertificate = true),
                        child: Text(d.hasCertificate ? '更换公开证书' : '导入公开证书'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            _note(context, '还没部署服务器？'),
            DesktopButton(
              key: const ValueKey('setup-initialize'),
              onPressed: d.busy ? null : () => _go(_Panel.initialization),
              child: const Text('查看初始化步骤'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _initialization(BuildContext context) {
    final c = UiPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopTextField(
          controller: d.host,
          onChanged: (_) => setState(() => _copied = false),
          decoration: const InputDecoration(
            labelText: '服务器 IP 或域名',
            helperText: '填写这台电脑实际连接的地址，证书也会按此生成。',
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 180,
            child: DesktopTextField(
              controller: d.port,
              onChanged: (_) => setState(() => _copied = false),
              decoration: const InputDecoration(labelText: '连接端口'),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('在服务器的 Docker 终端执行', style: libraryHeading(context, 16)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.rail,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.line),
          ),
          child: SelectableText(
            _initializationCommand,
            style: libraryText(
              context,
              13,
              height: 1.8,
            ).copyWith(fontFamily: 'Menlo'),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopButton(
            key: const ValueKey('setup-copy-command'),
            leading: Icon(_copied ? Icons.check : Icons.copy_outlined),
            onPressed: () async {
              final host = d.host.text.trim(), port = int.tryParse(d.port.text);
              if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.:-]*$').hasMatch(host) ||
                  port == null ||
                  port < 1 ||
                  port > 65535) {
                setState(() => _error = '请填写服务器 IP／域名和有效端口。');
                return;
              }
              await Clipboard.setData(
                ClipboardData(text: _initializationCommand),
              );
              if (mounted) {
                setState(() {
                  _copied = true;
                  _error = null;
                });
              }
            },
            child: Text(_copied ? '已复制' : '复制初始化命令'),
          ),
        ),
        const SizedBox(height: 24),
        const _InfoRow(
          icon: Icons.task_alt,
          title: '初始化后，导出连接文件',
          description: '证书和 Token 自动生成，私钥留在服务器。重启和升级会沿用原配置。',
        ),
      ],
    );
  }

  String get _initializationCommand =>
      'docker compose run --rm chiyo setup \\\n  --host ${d.host.text.trim()} --port ${d.port.text.trim()}';

  Widget _footer(BuildContext context) {
    final c = UiPalette.of(context);
    final local = d.selected == SetupStorageMode.local;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 690),
          child: Row(
            children: [
              if (_panel != _Panel.mode || widget.embedded)
                DesktopButton(
                  key: const ValueKey('setup-back'),
                  kind: DesktopButtonKind.quiet,
                  leading: const Icon(Icons.arrow_back),
                  onPressed: d.busy
                      ? null
                      : () {
                          if (_panel == _Panel.mode) {
                            widget.onBack?.call();
                          } else {
                            _go(
                              _panel == _Panel.initialization
                                  ? _Panel.connection
                                  : _Panel.mode,
                            );
                          }
                        },
                  child: Text(_panel == _Panel.mode ? '返回信息库' : '上一步'),
                ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: DesktopButton(
                    key: const ValueKey('setup-continue'),
                    kind: DesktopButtonKind.primary,
                    busy: d.busy,
                    minimumSize: const Size(160, 42),
                    onPressed: d.busy
                        ? null
                        : () {
                            if (_panel == _Panel.initialization) {
                              _import(context);
                            } else if (_panel == _Panel.mode && !local) {
                              _go(_Panel.connection);
                            } else {
                              _finish();
                            }
                          },
                    child: Text(
                      d.busy
                          ? '正在连接…'
                          : _panel == _Panel.initialization
                          ? '导入连接文件'
                          : _panel == _Panel.mode
                          ? local
                                ? widget.embedded
                                      ? '使用本地模式'
                                      : '开始本地使用'
                                : '继续'
                          : widget.embedded
                          ? '保存并连接'
                          : '连接并开始使用',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeChoice extends StatelessWidget {
  const _ModeChoice({
    required this.mode,
    required this.selected,
    required this.onSelect,
  });
  final SetupStorageMode mode;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final c = UiPalette.of(context), local = mode == SetupStorageMode.local;
    return Semantics(
      selected: selected,
      child: DesktopButton(
        key: ValueKey('setup-mode-${mode.name}'),
        selected: selected,
        selectedBorder: true,
        selectedBorderColor: c.accent,
        minimumSize: const Size(0, 120),
        padding: const EdgeInsets.all(22),
        alignment: Alignment.centerLeft,
        onPressed: onSelect,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              local ? Icons.computer_outlined : Icons.cloud_sync_outlined,
              size: 26,
              color: selected ? c.accent : c.muted,
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    local ? '本地使用' : '服务器同步',
                    style: libraryHeading(context, 18),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    local ? '资料保存在这台电脑，无需部署服务器。' : '连接自己的 NAS 或服务器，在多台电脑间同步资料。',
                    style: libraryText(context, 14, color: c.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 21,
              color: selected ? c.accent : c.lineStrong,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title, description;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Icon(icon, size: 20, color: UiPalette.of(context).muted),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: libraryText(context, 14, weight: FontWeight.w500),
            ),
            const SizedBox(height: 5),
            _note(context, description),
          ],
        ),
      ),
    ],
  );
}

Widget _note(BuildContext context, String text) => Text(
  text,
  style: libraryText(
    context,
    14,
    color: UiPalette.of(context).muted,
    height: 1.75,
  ),
);
