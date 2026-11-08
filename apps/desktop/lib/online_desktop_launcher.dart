import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'workspace/remote_workspace_source.dart';
import 'workspace/workspace_app.dart';
import 'workspace/zhiyu_theme.dart';
import 'desktop_controls.dart';
import 'online_agent_connection_dialog.dart';

class OnlineDesktopLauncher extends StatefulWidget {
  const OnlineDesktopLauncher({super.key, required this.profiles});
  final ConnectionProfileStore profiles;
  @override
  State<OnlineDesktopLauncher> createState() => _OnlineDesktopLauncherState();
}

class _OnlineDesktopLauncherState extends State<OnlineDesktopLauncher> {
  final _address = TextEditingController(),
      _token = TextEditingController(),
      _certificate = TextEditingController();
  RemoteWorkspaceSource? _source;
  ConnectionProfile? _previous;
  String? _error;
  bool _busy = true;
  bool _serverChanged = false;
  bool _offline = false, _probing = false;
  Timer? _connectionTimer;
  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final saved = await widget.profiles.read();
      if (!mounted) return;
      if (saved == null) {
        setState(() => _busy = false);
        return;
      }
      _previous = saved;
      _address.text = saved.address;
      _token.text = saved.token;
      _certificate.text = saved.certificate;
      await _connect();
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '无法读取连接设置，请重新连接。';
        });
      }
    }
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
      _serverChanged = false;
    });
    OwnerClient? client;
    try {
      final address = _address.text.trim();
      final certificate = _certificate.text.trim();
      SecurityContext? trust;
      if (certificate.isNotEmpty) {
        trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(certificate.codeUnits);
      }
      client = await OwnerClient.connect(
        address: Uri.parse(address),
        token: _token.text.trim(),
        trust: trust,
        expectedServerId: _previous?.address == address
            ? _previous!.serverId
            : null,
      );
      final profile = ConnectionProfile(
        address: address,
        token: _token.text.trim(),
        serverId: client.serverId,
        certificate: certificate,
      );
      await widget.profiles.save(profile);
      if (!mounted) {
        client.close();
        return;
      }
      _previous = profile;
      setState(() {
        _source = RemoteWorkspaceSource(client!);
        _offline = false;
        _busy = false;
      });
      _connectionTimer?.cancel();
      _connectionTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_checkConnection()),
      );
    } on Object catch (e) {
      client?.close();
      if (mounted) {
        setState(() {
          _busy = false;
          _serverChanged = e is RemoteFailure && e.code == 'server_changed';
          _error = switch (e) {
            RemoteFailure(code: 'unauthorized') => 'Token 不正确，请重新填写。',
            RemoteFailure(code: 'server_changed') => '服务器身份已变化，请核对服务器地址。',
            RemoteFailure(code: 'untrusted_server') => '无法验证服务器证书，请检查证书或连接地址。',
            RemoteFailure(code: 'invalid_connection') =>
              '请填写完整的 HTTPS 服务器地址和 Token。',
            _ => '连接失败，请检查服务器地址、Token 和网络后重试。',
          };
        });
      }
    }
  }

  Future<void> _checkConnection() async {
    final source = _source;
    if (source == null || _probing) return;
    _probing = true;
    try {
      final status = await source.client.request('GET', '/v1/server');
      final observation = status['workspaceObservation'];
      if (observation is! String) throw const RemoteFailure('invalid_response');
      if (mounted && identical(source, _source)) {
        source.observeServer(observation);
      }
      if (mounted && identical(source, _source) && _offline) {
        source.notifyConnectionChanged();
        setState(() => _offline = false);
      }
    } on Object {
      if (mounted && identical(source, _source) && !_offline) {
        setState(() => _offline = true);
        source.notifyConnectionChanged();
      }
    } finally {
      _probing = false;
    }
  }

  void _settings() {
    _connectionTimer?.cancel();
    final old = _source;
    setState(() => _source = null);
    if (old != null) unawaited(old.dispose());
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    _source?.dispose();
    _address.dispose();
    _token.dispose();
    _certificate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    if (source != null) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(
              excluding: _offline,
              child: ExcludeFocus(
                excluding: _offline,
                child: AbsorbPointer(
                  absorbing: _offline,
                  child: WorkspaceApp(
                    source: source,
                    windowTitle: '知予',
                    onConnectionSettings: _settings,
                    onAgentConnectionSetup:
                        widget.profiles is PrivateConnectionProfileStore
                        ? (context) async {
                            await showDesktopDialog<void>(
                              context,
                              barrierDismissible: false,
                              builder: (_) => OnlineAgentConnectionDialog(
                                client: source.client,
                                certificate: _previous!.certificate,
                                directory: Directory(
                                  '${(widget.profiles as PrivateConnectionProfileStore).directory}/agent',
                                ),
                              ),
                            );
                          }
                        : null,
                  ),
                ),
              ),
            ),
            if (_offline)
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: zhiyuTheme(Brightness.light),
                home: Scaffold(
                  key: const ValueKey('online-offline-blocker'),
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('与服务器的连接已断开。'),
                        const SizedBox(height: 12),
                        const Text('连接恢复后可继续操作。'),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _checkConnection,
                          child: const Text('重新连接'),
                        ),
                        TextButton(
                          onPressed: _settings,
                          child: const Text('连接设置'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: zhiyuTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            child: SizedBox(
              width: 480,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '连接服务器',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    const Text('连接后查看和管理你的资料。'),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _address,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: 'https://server.example:47126',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _token,
                      enabled: !_busy,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Token'),
                    ),
                    ExpansionTile(
                      title: const Text('证书设置（可选）'),
                      children: [
                        TextField(
                          controller: _certificate,
                          enabled: !_busy,
                          minLines: 3,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            labelText: '服务器 CA 证书',
                            helperText: '使用私人证书时填写，不会修改系统信任设置。',
                          ),
                        ),
                      ],
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _error!,
                          key: const ValueKey('connection-error'),
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (_serverChanged)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                                _previous = null;
                                unawaited(_connect());
                              },
                        child: const Text('确认连接新服务器'),
                      ),
                    FilledButton(
                      onPressed: _busy ? null : _connect,
                      child: Text(_busy ? '正在连接…' : '连接'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
