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
import 'connection_view.dart';
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
  bool _serverChanged = false, _certificateError = false;
  bool _connecting = false, _connectionView = false;
  final _connectionSettingsRequests = ValueNotifier<int>(0);
  bool _offline = false, _probing = false;
  int _failedHealthChecks = 0;
  RemoteWorkspaceSource? _updatingSource;
  Timer? _connectionTimer, _syncTimer;
  late final OnlineDesktopRuntime _desktop;
  String? _desktopObservation;
  DateTime? _lastOwnerMaintenance;
  Future<void>? _ownerMaintenance;
  @override
  void initState() {
    super.initState();
    _address.addListener(_draftChanged);
    _token.addListener(_draftChanged);
    _certificate.addListener(_draftChanged);
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

  void _draftChanged() {
    if (mounted) {
      setState(() {
        _serverChanged = false;
        _certificateError = false;
        _error = null;
      });
    }
  }

  bool _matchesProfile(ConnectionProfile profile) =>
      _address.text.trim() == profile.address &&
      _token.text.trim() == profile.token &&
      _certificate.text.trim() == profile.certificate;

  ConnectionCertificateStatus get _certificateStatus {
    if (_certificateError) return ConnectionCertificateStatus.error;
    if (_source != null &&
        !_offline &&
        _previous != null &&
        _matchesProfile(_previous!)) {
      return ConnectionCertificateStatus.verified;
    }
    return _certificate.text.trim().isEmpty
        ? ConnectionCertificateStatus.unconfigured
        : ConnectionCertificateStatus.unverified;
  }

  RemoteWorkspaceSource _createSource(
    OwnerClient client,
  ) => RemoteWorkspaceSource(
    client,
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

  Future<void> _saveConnection(ConnectionProfile profile, OwnerClient client) =>
      widget.profiles is PrivateConnectionProfileStore
      ? (widget.profiles as PrivateConnectionProfileStore).saveConnected(
          profile,
          client,
        )
      : widget.profiles.save(profile);

  Future<void> _connect({bool confirmServer = false}) async {
    if (_connecting || _desktop.quitting || confirmServer && !_serverChanged) {
      return;
    }
    _connecting = true;
    setState(() {
      _busy = true;
      _error = null;
      _serverChanged = false;
      _certificateError = false;
    });
    OwnerClient? client;
    RemoteWorkspaceSource? candidate;
    var adopted = false;
    var parsingCertificate = false;
    try {
      // Capture a draft once. It cannot replace the active connection until
      // identity, authentication and the first complete projection all pass.
      final address = _address.text.trim();
      final token = _token.text.trim();
      final certificate = _certificate.text.trim();
      SecurityContext? trust;
      if (certificate.isNotEmpty) {
        parsingCertificate = true;
        trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(certificate.codeUnits);
        parsingCertificate = false;
      }
      client = await OwnerClient.connect(
        address: Uri.parse(address),
        token: token,
        trust: trust,
        expectedServerId: !confirmServer && _previous?.address == address
            ? _previous!.serverId
            : null,
      );
      if (!mounted || _desktop.quitting) return;
      final profile = ConnectionProfile(
        address: address,
        token: token,
        serverId: client.serverId,
        certificate: certificate,
      );
      if (_source != null &&
          _previous != null &&
          _matchesProfile(_previous!) &&
          client.serverId == _previous!.serverId) {
        // Reuse the device too, including upgrading a legacy owner-only setup.
        await _saveConnection(profile, client);
        // A reconnect with unchanged settings keeps every controller and draft.
        setState(() {
          _offline = false;
          _failedHealthChecks = 0;
        });
        _source!.notifyConnectionChanged();
        return;
      }
      candidate = _createSource(client);
      await candidate.cache.synchronize();
      if (!mounted || _desktop.quitting) return;
      await _saveConnection(profile, client);
      if (!mounted || _desktop.quitting) return;
      final old = _source;
      _previous = profile;
      setState(() {
        _source = candidate;
        adopted = true;
        _connectionView = false;
        _offline = false;
        _failedHealthChecks = 0;
      });
      _syncTimer?.cancel();
      _syncTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        final source = _source;
        if (source != null && !_offline) {
          unawaited(source.cache.synchronize().catchError((Object _) {}));
        }
      });
      // Retiring the old projection happens after widgets have released it;
      // its cleanup cannot turn a successfully adopted connection into failure.
      await WidgetsBinding.instance.endOfFrame;
      if (old != null) unawaited(old.dispose().catchError((Object _) {}));
      if (!mounted || _desktop.quitting) return;
      unawaited(_desktop.bind(candidate));
      _connectionTimer?.cancel();
      _connectionTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_checkConnection()),
      );
    } on Object catch (e) {
      if (mounted && !_desktop.quitting) {
        setState(() {
          _serverChanged = e is RemoteFailure && e.code == 'server_changed';
          _certificateError =
              parsingCertificate ||
              e is RemoteFailure && e.code == 'untrusted_server';
          _error = parsingCertificate
              ? '证书格式不正确，请填写 PEM 格式的 CA 证书。'
              : switch (e) {
                  RemoteFailure(code: 'unauthorized') => 'Token 不正确，请重新填写。',
                  RemoteFailure(code: 'server_changed') => '服务器身份已变化，请核对服务器地址。',
                  RemoteFailure(code: 'untrusted_server') =>
                    '无法验证服务器证书，请检查证书或连接地址。',
                  RemoteFailure(code: 'invalid_connection') ||
                  FormatException() => '请填写完整的 HTTPS 服务器地址和 Token。',
                  RemoteFailure(code: 'server_unavailable') =>
                    '无法连接服务器，请检查网络、服务器是否运行，以及系统是否允许知予访问本地网络。',
                  RemoteFailure(code: 'server_timeout') =>
                    '连接服务器超时，请检查网络和服务器状态后重试。',
                  RemoteFailure(code: 'profile_store_unavailable') ||
                  RemoteFailure(code: 'invalid_profile') ||
                  FileSystemException() ||
                  ProcessException() => '无法保存本机连接设置，请检查应用的数据目录权限后重试。',
                  RemoteFailure(code: 'agent_connection_unavailable') =>
                    '无法准备 CLI 连接，请检查服务器后重试。原连接设置已保留。',
                  _ => '连接失败，请检查服务器地址、Token 和网络后重试。',
                };
        });
      }
    } finally {
      if (!adopted) {
        if (candidate != null) {
          await candidate.dispose().catchError((Object _) {});
        } else {
          client?.close();
        }
      }
      _connecting = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkConnection() async {
    final source = _source;
    if (source == null || _probing) return;
    _probing = true;
    try {
      await source.client.request('GET', '/v1/owner/health');
      if (!mounted || !identical(source, _source)) return;
      _failedHealthChecks = 0;
      if (mounted && identical(source, _source) && _offline) {
        source.notifyConnectionChanged();
        setState(() => _offline = false);
      }
      unawaited(_checkUpdates(source));
    } on Object {
      // An update may wait for a durable approval while the host is healthy.
      // Only repeated failed health checks make the connection unavailable.
      if (!mounted || !identical(source, _source)) return;
      _failedHealthChecks++;
      if (_failedHealthChecks >= 2 &&
          mounted &&
          identical(source, _source) &&
          !_offline) {
        setState(() => _offline = true);
        source.notifyConnectionChanged();
      }
    } finally {
      _probing = false;
    }
  }

  Future<void> _checkUpdates(RemoteWorkspaceSource source) async {
    if (identical(_updatingSource, source)) return;
    _updatingSource = source;
    try {
      final status = await source.client.request('GET', '/v1/owner/updates');
      final observation = status['workspaceObservation'];
      if (observation is! String) throw const RemoteFailure('invalid_response');
      if (mounted && identical(source, _source)) {
        source.observeServer(
          observation,
          summary: status['summary'] == null
              ? null
              : Map<String, dynamic>.from(status['summary'] as Map),
        );
        // A slow OS notification delivery must not hold the health probe open
        // and delay the offline screen. The App lifetime drains this work.

        final now = DateTime.now();
        if (_lastOwnerMaintenance == null ||
            now.difference(_lastOwnerMaintenance!) >=
                const Duration(minutes: 1)) {
          _lastOwnerMaintenance = now;
          unawaited(_maintainOwnerFiles(source));
        }
      }
    } on Object {
      // Keep the current view and inputs. Independent health checks continue
      // while this business query is queued, delayed or unavailable.
    } finally {
      if (identical(_updatingSource, source)) _updatingSource = null;
    }
  }

  void _settings() {
    if (_desktop.quitting || _connecting) return;
    _connectionSettingsRequests.value++;
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
    _syncTimer?.cancel();
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
    _syncTimer?.cancel();
    _source?.dispose();
    _connectionSettingsRequests.dispose();
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
          body: ConnectionSurface(
            title: _desktop.shutdownFailed ? '退出未完成' : '正在退出应用…',
            description: _desktop.shutdownFailed
                ? (_desktop.resourcesClosed
                      ? '应用未能退出，请重试。服务器和CLI会话不受影响。'
                      : '本机资源尚未关闭，请重试退出。服务器和CLI会话不受影响。')
                : '正在保存状态并关闭本机连接。',
            loading: !_desktop.shutdownFailed,
            children: [
              if (_desktop.shutdownFailed)
                DesktopButton(
                  key: const ValueKey('online-retry-exit'),
                  onPressed: _desktop.quit,
                  child: const Text('重试退出'),
                ),
            ],
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
              excluding: _offline && !_connectionView,
              child: ExcludeFocus(
                excluding: _offline && !_connectionView,
                child: AbsorbPointer(
                  absorbing: _offline && !_connectionView,
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
                    connectionSettingsRequests: _connectionSettingsRequests,
                    onConnectionSettingsVisible: (visible) {
                      if (mounted &&
                          identical(_source, source) &&
                          _connectionView != visible) {
                        setState(() => _connectionView = visible);
                      }
                    },
                    connectionBuilder: (context, onCancel) => ConnectionForm(
                      embedded: true,
                      address: _address,
                      token: _token,
                      certificate: _certificate,
                      certificateStatus: _certificateStatus,
                      busy: _busy,
                      error: _error,
                      onConnect: _connect,
                      onCancel: onCancel,
                      onConfirmServer: _serverChanged
                          ? () => _connect(confirmServer: true)
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            if (_offline && !_connectionView)
              MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: zhiyuTheme(Brightness.light),
                home: Scaffold(
                  key: const ValueKey('online-offline-blocker'),
                  body: ConnectionSurface(
                    title: '与服务器的连接已断开。',
                    description: '连接恢复后可继续操作。',
                    icon: Icons.cloud_off_outlined,
                    children: [
                      DesktopButton(
                        kind: DesktopButtonKind.primary,
                        onPressed: _checkConnection,
                        child: const Text('重新连接'),
                      ),
                      const SizedBox(height: 12),
                      DesktopButton(
                        onPressed: _settings,
                        child: const Text('连接设置'),
                      ),
                    ],
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
        body: ConnectionForm(
          address: _address,
          token: _token,
          certificate: _certificate,
          busy: _busy,
          error: _error,
          onConnect: _connect,
          certificateStatus: _certificateStatus,
          onConfirmServer: !_serverChanged
              ? null
              : () {
                  unawaited(_connect(confirmServer: true));
                },
        ),
      ),
    );
  }
}
