import 'package:flutter/material.dart';
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

enum _Panel { mode, connection, password }

/// Isolated UI state only. Connection checks, certificates, passwords and sync
/// are synthetic and stay in memory. No production profile/API is involved.
class SetupPreviewDraft extends ChangeNotifier implements WorkspaceSync {
  final host = TextEditingController();
  final port = TextEditingController(text: '47126');
  SetupStorageMode selected = SetupStorageMode.local;
  SetupStorageMode saved = SetupStorageMode.local;
  String? _configuredEndpoint, _password;
  bool certificateRemembered = false;
  @override
  bool busy = false;
  @override
  DateTime? updatedAt;
  bool _disposed = false;

  String get endpoint {
    final value = host.text.trim();
    return Uri(
      scheme: 'https',
      host: value,
      port: int.parse(port.text),
    ).toString();
  }

  String? get addressError {
    final value = host.text.trim();
    if (value.isEmpty ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.:-]*$').hasMatch(value)) {
      return '请填写服务器 IP 或域名，不需要填写 https://。';
    }
    final number = int.tryParse(port.text);
    if (number == null || number < 1 || number > 65535) {
      return '请填写 1～65535 之间的端口。';
    }
    return null;
  }

  bool get knownServer =>
      addressError == null && _configuredEndpoint == endpoint;
  bool get hasConnection => _configuredEndpoint != null;
  @override
  bool get enabled => saved == SetupStorageMode.server;
  @override
  bool get needsReview => false;
  @override
  Object? get failure => null;

  Future<void> checkServer() => synchronize();

  void useLocal() {
    selected = saved = SetupStorageMode.local;
    notifyListeners();
  }

  void saveServer(String password) {
    _configuredEndpoint = endpoint;
    _password = password;
    selected = saved = SetupStorageMode.server;
    certificateRemembered = true;
    notifyListeners();
  }

  bool passwordMatches(String value) => value == _password;
  void changePassword(String value) {
    _password = value;
    notifyListeners();
  }

  void resumeServer() {
    saved = selected = SetupStorageMode.server;
    notifyListeners();
  }

  @override
  Future<void> synchronize() async {
    if (busy) return;
    busy = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_disposed) return;
    busy = false;
    updatedAt = DateTime.now();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    host.dispose();
    port.dispose();
    super.dispose();
  }
}

/// First-run guide only. Settings compose StorageSettingsPreview instead.
class SetupConfigurationPreview extends StatefulWidget {
  const SetupConfigurationPreview({
    super.key,
    required this.draft,
    required this.onComplete,
  });
  final SetupPreviewDraft draft;
  final VoidCallback onComplete;
  @override
  State<SetupConfigurationPreview> createState() =>
      _SetupConfigurationPreviewState();
}

class _SetupConfigurationPreviewState extends State<SetupConfigurationPreview> {
  _Panel _panel = _Panel.mode;
  final _password = TextEditingController(),
      _confirmation = TextEditingController();
  String? _error;
  SetupPreviewDraft get d => widget.draft;
  bool get _initializing => !d.knownServer;

  void _go(_Panel panel) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _panel = panel;
      _error = null;
    });
  }

  Future<void> _next() async {
    if (d.busy) return;
    if (_panel == _Panel.mode) {
      if (d.selected == SetupStorageMode.local) {
        d.useLocal();
        widget.onComplete();
      } else {
        _go(_Panel.connection);
      }
      return;
    }
    if (_panel == _Panel.connection) {
      if (d.addressError case final message?) {
        setState(() => _error = message);
        return;
      }
      setState(() => _error = null);
      await d.checkServer();
      if (mounted) _go(_Panel.password);
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _error = '请填写管理密码。');
      return;
    }
    if (_initializing && _password.text != _confirmation.text) {
      setState(() => _error = '两次输入的密码不一致，请重新确认。');
      return;
    }
    if (!_initializing && !d.passwordMatches(_password.text)) {
      setState(() => _error = '管理密码不正确，请重新输入。');
      return;
    }
    await d.checkServer();
    if (!mounted) return;
    d.saveServer(_password.text);
    _password.clear();
    _confirmation.clear();
    widget.onComplete();
  }

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: d,
    builder: (_, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '知予 · 配置预览',
      theme: zhiyuTheme(Brightness.light),
      darkTheme: zhiyuTheme(Brightness.dark),
      scrollBehavior: const DesktopScrollBehavior(scrollbarGutter: 9),
      builder: (_, child) =>
          DesktopInteractionHost(child: DesktopWindowFrame(child: child!)),
      home: Builder(builder: _standalone),
    ),
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
          for (final (index, title) in ['使用方式', '连接服务器', '管理密码'].indexed) ...[
            Row(
              children: [
                AnimatedContainer(
                  duration: DesktopMotion.feedbackOf(context),
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: index == _panel.index ? c.accent : c.paper,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.line),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: libraryText(
                      context,
                      13,
                      color: index == _panel.index ? c.onAccent : c.muted,
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
      _Panel.mode => '你的资料，放在哪里？',
      _Panel.connection => '连接你的服务器',
      _Panel.password => _initializing ? '设置管理密码' : '输入管理密码',
    };
    final subtitle = switch (_panel) {
      _Panel.mode => '先在本机使用，或连接自己的 NAS／服务器同步资料。',
      _Panel.connection => '填写已经启动知予服务的 NAS 或服务器地址。',
      _Panel.password =>
        _initializing ? '以后其他电脑连接这台服务器时，也使用这个密码。' : '这台服务器已完成初始化，输入管理密码即可连接。',
    };
    return ColoredBox(
      color: UiPalette.of(context).paper,
      child: Column(
        children: [
          Expanded(
            child: _FormBody(
              title: title,
              subtitle: subtitle,
              error: _error,
              child: DesktopEntrance(
                key: ValueKey(_panel),
                child: switch (_panel) {
                  _Panel.mode => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final mode in SetupStorageMode.values) ...[
                        _ModeChoice(
                          mode: mode,
                          selected: d.selected == mode,
                          onSelect: () => setState(() => d.selected = mode),
                        ),
                        const SizedBox(height: 16),
                      ],
                      const SizedBox(height: 8),
                      const _InfoRow(
                        icon: Icons.smart_toy_outlined,
                        title: '两种方式都能接收 AI 申请',
                        description: '由 AI 发起，你在 App 中审批和管理资料。',
                      ),
                    ],
                  ),
                  _Panel.connection => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ServerAddressFields(draft: d),
                      const SizedBox(height: 18),
                      const _InfoRow(
                        icon: Icons.verified_user_outlined,
                        title: '证书自动配置',
                        description: '服务器自动生成证书，App 在连接时保存，无需查找或导入文件。',
                      ),
                    ],
                  ),
                  _Panel.password => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _InfoRow(
                        icon: Icons.check_circle_outline,
                        title: '已连接 · ${d.host.text.trim()}:${d.port.text}',
                        description: '服务器证书已自动保存。',
                      ),
                      const SizedBox(height: 28),
                      _PasswordField(
                        controller: _password,
                        label: '管理密码',
                        enabled: !d.busy,
                        fieldKey: 'setup-password',
                      ),
                      if (_initializing)
                        _PasswordField(
                          controller: _confirmation,
                          label: '再次输入管理密码',
                          enabled: !d.busy,
                          fieldKey: 'setup-password-confirm',
                        ),
                      const SizedBox(height: 10),
                      _note(context, '这是知予的连接密码，与 NAS 的系统登录密码无关。'),
                    ],
                  ),
                },
              ),
            ),
          ),
          _FormFooter(
            backLabel: _panel == _Panel.mode ? null : '上一步',
            onBack: d.busy
                ? null
                : () => _go(
                    _panel == _Panel.password ? _Panel.connection : _Panel.mode,
                  ),
            actionKey: 'setup-continue',
            busy: d.busy,
            onAction: d.busy ? null : _next,
            action: d.busy
                ? (_panel == _Panel.connection ? '正在连接…' : '正在完成配置…')
                : switch (_panel) {
                    _Panel.mode =>
                      d.selected == SetupStorageMode.local ? '开始本地使用' : '继续',
                    _Panel.connection => '连接服务器',
                    _Panel.password => _initializing ? '完成配置并开始使用' : '连接并开始使用',
                  },
          ),
        ],
      ),
    );
  }
}

/// Day-to-day settings are one page, not an embedded first-run wizard.
class StorageSettingsPreview extends StatefulWidget {
  const StorageSettingsPreview({
    super.key,
    required this.draft,
    required this.onBack,
  });
  final SetupPreviewDraft draft;
  final VoidCallback onBack;
  @override
  State<StorageSettingsPreview> createState() => _StorageSettingsPreviewState();
}

class _StorageSettingsPreviewState extends State<StorageSettingsPreview> {
  final _password = TextEditingController();
  String? _error;
  SetupPreviewDraft get d => widget.draft;

  void _addressChanged() => setState(() => _error = null);
  @override
  void initState() {
    super.initState();
    d.selected = d.saved;
    d.host.addListener(_addressChanged);
    d.port.addListener(_addressChanged);
  }

  @override
  void dispose() {
    d.host.removeListener(_addressChanged);
    d.port.removeListener(_addressChanged);
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (d.busy) return;
    final error = d.addressError;
    if (error != null || !d.knownServer && _password.text.isEmpty) {
      setState(() => _error = error ?? '请填写这台服务器的管理密码。');
      return;
    }
    setState(() => _error = null);
    await d.checkServer();
    if (!mounted) return;
    if (d.knownServer) {
      d.resumeServer();
    } else {
      // This settings form represents logging into an existing server. It never
      // creates a new server or re-enters first-run initialization.
      d.saveServer(_password.text);
    }
    _password.clear();
  }

  Future<void> _changePassword(BuildContext context) async {
    final current = TextEditingController(),
        next = TextEditingController(),
        repeated = TextEditingController();
    await showDesktopDialog<void>(
      context,
      builder: (context) {
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) => PrototypeDialog(
            title: '修改管理密码',
            onClose: () => Navigator.pop(context),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PasswordField(
                  controller: current,
                  label: '当前密码',
                  fieldKey: 'settings-current-password',
                ),
                _PasswordField(
                  controller: next,
                  label: '新密码',
                  fieldKey: 'settings-new-password',
                ),
                _PasswordField(
                  controller: repeated,
                  label: '再次输入新密码',
                  fieldKey: 'settings-repeat-password',
                ),
                _note(context, '其他电脑下次连接时需要使用新密码，已有资料和凭据不受影响。'),
                if (error != null)
                  Text(
                    error!,
                    style: libraryText(
                      context,
                      14,
                      color: UiPalette.of(context).danger,
                    ),
                  ),
              ],
            ),
            actions: [
              DesktopButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              DesktopButton(
                key: const ValueKey('settings-save-password'),
                kind: DesktopButtonKind.primary,
                onPressed: () {
                  if (!d.passwordMatches(current.text)) {
                    setDialogState(() => error = '当前密码不正确。');
                  } else if (next.text.isEmpty || next.text != repeated.text) {
                    setDialogState(() => error = '请填写新密码，并确保两次输入一致。');
                  } else {
                    d.changePassword(next.text);
                    Navigator.pop(context);
                  }
                },
                child: const Text('保存新密码'),
              ),
            ],
          ),
        );
      },
    );
    // The route may still be unmounting its editors after pop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      current.dispose();
      next.dispose();
      repeated.dispose();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: d,
    builder: (context, _) {
      final server = d.selected == SetupStorageMode.server;
      return ColoredBox(
        color: UiPalette.of(context).paper,
        child: Column(
          children: [
            Expanded(
              child: _FormBody(
                title: '存储与同步',
                subtitle: '管理资料的保存方式和服务器连接。',
                error: _error,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<SetupStorageMode>(
                      key: const ValueKey('settings-storage-mode'),
                      expandedInsets: EdgeInsets.zero,
                      segments: const [
                        ButtonSegment(
                          value: SetupStorageMode.local,
                          label: Text('本地模式'),
                          icon: Icon(Icons.computer_outlined),
                        ),
                        ButtonSegment(
                          value: SetupStorageMode.server,
                          label: Text('服务器同步'),
                          icon: Icon(Icons.cloud_sync_outlined),
                        ),
                      ],
                      selected: {d.selected},
                      onSelectionChanged: d.busy
                          ? null
                          : (values) => setState(() {
                              d.selected = values.single;
                              _error = null;
                              if (!server) {
                                _password.clear();
                              }
                              if (d.selected == SetupStorageMode.local) {
                                d.useLocal();
                              }
                            }),
                    ),
                    const SizedBox(height: 28),
                    if (!server)
                      const _InfoRow(
                        icon: Icons.computer_outlined,
                        title: '资料保存在这台电脑',
                        description: '无需连接服务器，也能接收 AI 申请和审批。',
                      )
                    else ...[
                      _ServerAddressFields(draft: d),
                      if (!d.knownServer) ...[
                        _PasswordField(
                          controller: _password,
                          label: '管理密码',
                          fieldKey: 'settings-login-password',
                          enabled: !d.busy,
                        ),
                        _note(context, '使用这台服务器已有的管理密码。'),
                      ],
                      const SizedBox(height: 20),
                      if (d.knownServer && d.certificateRemembered) ...[
                        _InfoRow(
                          icon: Icons.verified_user_outlined,
                          title: '已记住服务器证书',
                          description: d.enabled
                              ? '已连接 · ${d.host.text.trim()}:${d.port.text}'
                              : '重新连接时自动核对服务器身份。',
                        ),
                        const SizedBox(height: 26),
                        const Divider(),
                        const SizedBox(height: 18),
                        _InfoRow(
                          icon: Icons.lock_outline,
                          title: '管理密码',
                          description: '用于其他电脑连接这台服务器。',
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: DesktopButton(
                            key: const ValueKey('settings-change-password'),
                            onPressed: d.busy
                                ? null
                                : () => _changePassword(context),
                            child: const Text('修改管理密码'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 26),
                      Align(
                        alignment: Alignment.centerRight,
                        child: DesktopButton(
                          key: const ValueKey('settings-save-connection'),
                          kind: DesktopButtonKind.primary,
                          busy: d.busy,
                          onPressed: d.busy ? null : _save,
                          child: Text(d.busy ? '正在连接…' : '保存连接'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: DesktopButton(
                  kind: DesktopButtonKind.quiet,
                  leading: const Icon(Icons.arrow_back),
                  onPressed: d.busy ? null : widget.onBack,
                  child: const Text('返回信息库'),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _ServerAddressFields extends StatelessWidget {
  const _ServerAddressFields({required this.draft});
  final SetupPreviewDraft draft;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DesktopTextField(
        controller: draft.host,
        enabled: !draft.busy,
        decoration: const InputDecoration(
          labelText: '服务器 IP 或域名',
          hintText: '192.168.1.20',
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 180,
          child: DesktopTextField(
            controller: draft.port,
            enabled: !draft.busy,
            decoration: const InputDecoration(labelText: '端口'),
          ),
        ),
      ),
    ],
  );
}

class _PasswordField extends StatefulWidget {
  const _PasswordField({
    required this.controller,
    required this.label,
    required this.fieldKey,
    this.enabled = true,
  });
  final TextEditingController controller;
  final String label, fieldKey;
  final bool enabled;
  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _visible = false;
  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey(widget.fieldKey),
    child: DesktopTextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: !_visible,
      inlineSecret: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: IconButton(
          tooltip: _visible ? '隐藏密码' : '显示密码',
          onPressed: widget.enabled
              ? () => setState(() => _visible = !_visible)
              : null,
          icon: Icon(
            _visible
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            size: 18,
          ),
        ),
      ),
    ),
  );
}

class _FormBody extends StatelessWidget {
  const _FormBody({
    required this.title,
    required this.subtitle,
    required this.child,
    this.error,
  });
  final String title, subtitle;
  final Widget child;
  final String? error;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
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
            child,
            if (error != null) ...[
              const SizedBox(height: 16),
              Text(
                error!,
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
  );
}

class _FormFooter extends StatelessWidget {
  const _FormFooter({
    required this.action,
    required this.actionKey,
    required this.onAction,
    required this.busy,
    this.backLabel,
    this.onBack,
  });
  final String action, actionKey;
  final String? backLabel;
  final VoidCallback? onAction, onBack;
  final bool busy;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: UiPalette.of(context).line)),
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 690),
        child: Row(
          children: [
            if (backLabel != null)
              DesktopButton(
                key: const ValueKey('setup-back'),
                kind: DesktopButtonKind.quiet,
                leading: const Icon(Icons.arrow_back),
                onPressed: onBack,
                child: Text(backLabel!),
              ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: DesktopButton(
                  key: ValueKey(actionKey),
                  kind: DesktopButtonKind.primary,
                  busy: busy,
                  minimumSize: const Size(160, 42),
                  onPressed: onAction,
                  child: Text(action),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
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
