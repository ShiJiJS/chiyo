import 'dart:async';
import 'dart:io';
import 'package:info_core/macos_desktop_control.dart';
import 'package:flutter/material.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'workspace/remote_workspace_source.dart';
import 'workspace/workspace_app.dart';
import 'workspace/workspace_inputs.dart';
import 'workspace/zhiyu_theme.dart';
import 'desktop_controls.dart';
import 'online_agent_connection_dialog.dart';
import 'information_files.dart';
import 'backups.dart';
import 'package:info_storage/info_storage.dart';
import 'workspace/owner_file_open_dispatcher.dart';
import 'workspace/owner_credential_input.dart';
import 'credential_files.dart';
import 'desktop_runtime.dart';
import 'online_desktop_runtime.dart';

class OnlineDesktopLauncher extends StatefulWidget {
  const OnlineDesktopLauncher({
    super.key,
    required this.profiles,
    this.filePicker,
    this.deviceFilesDirectory,
    this.desktopPlatform,
    this.appControlDirectory,
    this.outputPicker = const NativeBackupFilePicker(),
    this.openDispatcher = const NativeOwnerFileOpenDispatcher(),
    this.credentialFiles = const NativeCredentialFilePicker(),
  });
  final ConnectionProfileStore profiles;
  final InformationFilePicker? filePicker;
  final String? deviceFilesDirectory;
  final DesktopPlatform? desktopPlatform;
  final Directory? appControlDirectory;
  final BackupFilePicker outputPicker;
  final OwnerFileOpenDispatcher openDispatcher;
  final CredentialFilePicker credentialFiles;
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
  late final OnlineDesktopRuntime _desktop;
  String? _desktopObservation;
  DateTime? _lastOwnerMaintenance;
  Future<void>? _ownerMaintenance;
  @override
  void initState() {
    super.initState();
    final platform = widget.desktopPlatform ?? NativeDesktopPlatform();
    _desktop = OnlineDesktopRuntime(
      platform: platform,
      beforeExit: _closeForExit,
      onResume: _resumeConnection,
      openAppControl: Platform.isMacOS && platform is NativeDesktopPlatform
          ? (state, quit) => MacDesktopControlHost.start(
              directory:
                  widget.appControlDirectory ??
                  MacDesktopControl.defaultDirectory()!,
              state: state,
              quit: quit,
            )
          : null,
    )..addListener(_desktopChanged);
    unawaited(_desktop.start());
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
        _source = RemoteWorkspaceSource(
          client!,
          filePicker: widget.filePicker,
          onNotificationEnable: _desktop.enableNotifications,
          onClosing: _desktop.release,
          desktopRuntime: _desktop,
          deviceFilesDirectory:
              widget.deviceFilesDirectory ??
              (widget.profiles is PrivateConnectionProfileStore
                  ? '${(widget.profiles as PrivateConnectionProfileStore).directory}/files'
                  : null),
          outputPicker: widget.outputPicker,
          openDispatcher: widget.openDispatcher,
        );
        _offline = false;
        _busy = false;
      });
      await _desktop.bind(_source);
      if (!mounted || _desktop.quitting) return;
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
        // A slow OS notification delivery must not hold the health probe open
        // and delay the offline screen. The App lifetime drains this work.
        unawaited(_desktop.refresh());
        final now = DateTime.now();
        if (_lastOwnerMaintenance == null ||
            now.difference(_lastOwnerMaintenance!) >=
                const Duration(minutes: 1)) {
          _lastOwnerMaintenance = now;
          unawaited(_maintainOwnerFiles(source));
        }
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
    if (_desktop.quitting) return;
    unawaited(_desktop.bind(null));
    _connectionTimer?.cancel();
    final old = _source;
    setState(() => _source = null);
    if (old != null) unawaited(old.dispose());
  }

  Future<void> _resumeConnection() async {
    await _checkConnection();
    final source = _source;
    if (source != null && !_offline) await _maintainOwnerFiles(source);
  }

  Future<void> _maintainOwnerFiles(RemoteWorkspaceSource source) =>
      _ownerMaintenance ??= (() async {
        if (!mounted ||
            _desktop.quitting ||
            !_desktop.navigationEnabled ||
            !identical(source, _source)) {
          return;
        }
        try {
          final changed = await source.maintainOwnerFiles();
          if (changed &&
              mounted &&
              !_desktop.quitting &&
              identical(source, _source)) {
            source.notifyConnectionChanged();
          }
        } on Object {
          // Original private cleanup records remain pending for next sweep.
          // An unavailable check never means files were removed.
        }
      })().whenComplete(() => _ownerMaintenance = null);

  void _desktopChanged() {
    final observation =
        '${_desktop.availability.tray}|${_desktop.availability.notifications.name}|${_desktop.windowHidden}|${_desktop.quitting}|${_desktop.closed}|${_desktop.resourcesClosed}|${_desktop.shutdownFailed}';
    if (observation != _desktopObservation) {
      _desktopObservation = observation;
      _source?.notifyConnectionChanged();
    }
    if (mounted) setState(() {});
  }

  Future<void> _closeForExit() async {
    _connectionTimer?.cancel();
    // Unmount data-backed widgets before their client and private device
    // coordinators close. This callback has no server/session stop capability.
    if (mounted) {
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }
    await _ownerMaintenance;
    await _source?.dispose();
  }

  @override
  void dispose() {
    _desktop.removeListener(_desktopChanged);
    _desktop.dispose();
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
    if (_desktop.quitting) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: zhiyuTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: _desktop.shutdownFailed
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _desktop.resourcesClosed
                            ? '应用未能退出，请重试。服务器和CLI会话不受影响。'
                            : '本机资源尚未关闭，请重试退出。服务器和CLI会话不受影响。',
                      ),
                      TextButton(
                        key: const ValueKey('online-retry-exit'),
                        onPressed: _desktop.quit,
                        child: const Text('重试退出'),
                      ),
                    ],
                  )
                : const Text('正在退出应用…'),
          ),
        ),
      );
    }
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
                    desktop: _desktop,
                    windowTitle: '知予',
                    inputsBuilder: (context) => WorkspaceInputs(
                      plugin: source.plugins.pick,
                      file: source.files.pick,
                      hostFile: source.hosts.pick,
                      backup: source.backups.pick,
                      proposalPassword: source.proposalPasswords,
                      credential: (form) => showOwnerCredentialInput(
                        context,
                        source.credentials,
                        form,
                        files: widget.credentialFiles,
                      ),
                    ),
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
