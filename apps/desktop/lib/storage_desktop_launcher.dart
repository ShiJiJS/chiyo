import 'dart:io';
import 'dart:async';
import 'package:info_core/info_core.dart';
import 'package:info_cli/device_focused_fill_host.dart';
import 'package:info_cli/device_credential_batch_host.dart';
import 'package:info_cli/installed_ego_browser.dart';
import 'bundled_focused_fill.dart';
import 'bundled_windows_native_fill.dart';
import 'macos_focused_fill.dart';
import 'macos_native_background_fill.dart';
import 'local_library_sync.dart';
import 'package:info_remote/library_replication_client.dart';

import 'package:flutter/material.dart';
import 'package:info_core/macos_desktop_control.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/private_connection_files.dart';

import 'connection_view.dart';
import 'desktop_bootstrap.dart';
import 'desktop_runtime.dart';
import 'online_desktop_launcher.dart';
import 'platform/local_library.dart';
import 'workspace/zhiyu_theme.dart';
import 'onboarding/setup_configuration.dart';
import 'onboarding/server_setup_controller.dart';

/// Resolves the persisted active library before opening any data or key.
class StorageDesktopLauncher extends StatefulWidget {
  const StorageDesktopLauncher({
    super.key,
    required this.profiles,
    required this.localBuilder,
    this.appControlDirectory,
    this.platform,
    this.openLocal,
    this.focusedFillDriver,
    this.nativeFillDriver,
    this.openNativeFillDriver,
  });

  final PrivateConnectionProfileStore profiles;
  final Widget Function(DesktopBootstrap) localBuilder;
  final Directory? appControlDirectory;
  final DesktopPlatform? platform;

  /// Owner-side test seam. Agent commands cannot select a driver or helper.
  final FocusedFillDriver? focusedFillDriver;
  final NativeFillDriver? nativeFillDriver;
  final Future<NativeFillDriver?> Function()? openNativeFillDriver;
  final Future<DesktopLibrary> Function(LocalLibraryConfiguration, bool)?
  openLocal;

  @override
  State<StorageDesktopLauncher> createState() => _StorageDesktopLauncherState();
}

class _StorageDesktopLauncherState extends State<StorageDesktopLauncher> {
  late final DesktopPlatform _platform =
      widget.platform ?? NativeDesktopPlatform();
  late final Future<void> _credentialFillStartup, _restoreStartup;
  DesktopBootstrap? _local;
  DeviceFocusedFillHost? _focusedFillHost;
  DeviceCredentialBatchHost? _credentialBatchHost;
  bool _hostDisposed = false;
  bool _online = false;
  String? _failure;
  ServerSetupController? _initialSetup;
  Completer<void>? _setupSettled;
  Future<void>? _initialClosing, _fillHostsClosing;
  bool _initialQuitting = false, _initialExitFailed = false;

  @override
  void initState() {
    super.initState();
    _credentialFillStartup = _startCredentialFillHosts();
    // Publish a resource-aware handler before persisted-profile I/O or the
    // first setup screen. The selected runtime replaces it on handoff.
    _restoreStartup = Future<void>.value()
        .then((_) => _initializeUnconfiguredDesktop())
        .then((_) => _restore());
  }

  Future<void> _initializeUnconfiguredDesktop() async {
    try {
      await _platform.initialize((event) async {
        if (event == DesktopEvent.quit || event == DesktopEvent.closeWindow) {
          await _closeUnconfiguredDesktop();
        } else if (event == DesktopEvent.openApprovals ||
            event == DesktopEvent.openSettings ||
            event == DesktopEvent.searchApprovals) {
          await _platform.showWindow();
        }
      });
    } on Object {
      // Retain the setup/error screen if the optional OS integration fails.
    }
  }

  Future<void> _closeUnconfiguredDesktop() => _initialClosing ??=
      _finishUnconfiguredDesktop().catchError((Object error, StackTrace stack) {
        _initialClosing = null;
        _initialExitFailed = true;
        if (mounted) setState(() {});
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _finishUnconfiguredDesktop() async {
    _initialQuitting = true;
    _initialExitFailed = false;
    if (mounted) setState(() {});
    // Stop new execution/late Host publication while recovery/setup settles.
    await _closeFocusedFillHost();
    await _restoreStartup;
    await _setupSettled?.future;
    await _local?.close();
    await _platform.terminate();
  }

  Future<void> _startCredentialFillHosts() async {
    if (widget.focusedFillDriver == null &&
        widget.nativeFillDriver == null &&
        widget.openNativeFillDriver == null &&
        widget.platform != null &&
        widget.platform is! NativeDesktopPlatform) {
      return;
    }
    NativeFillDriver? nativeDriver;
    var nativeTransferred = false;
    try {
      try {
        nativeDriver = widget.nativeFillDriver;
        if (nativeDriver == null) {
          final factory = widget.openNativeFillDriver;
          if (factory != null) {
            nativeDriver = await factory();
          } else if (widget.platform == null ||
              widget.platform is NativeDesktopPlatform) {
            nativeDriver = Platform.isMacOS
                ? MacOSNativeBackgroundFillDriver()
                : Platform.isWindows
                ? await loadBundledWindowsNativeFill()
                : null;
          }
        }
      } on Object {
        // An unavailable native adapter leaves the other providers usable.
      }
      if (_hostDisposed) return;
      var driver = widget.focusedFillDriver;
      if (driver == null &&
          (widget.platform == null ||
              widget.platform is NativeDesktopPlatform)) {
        try {
          driver = Platform.isMacOS
              ? MacOSFocusedFillDriver()
              : Platform.isWindows
              ? await loadBundledFocusedFill()
              : null;
        } on Object {
          // A missing focus broker must not disable native or browser filling.
        }
      }
      if (_hostDisposed) return;
      if (driver != null) {
        try {
          final host = await DeviceFocusedFillHost.start(
            directory: Directory(widget.profiles.directory),
            driver: driver,
          );
          if (_hostDisposed) {
            await host.close();
            return;
          }
          _focusedFillHost = host;
        } on Object {
          // The batch Host has an independent endpoint and provider lifetime.
        }
      }
      String? browser;
      try {
        browser = await findInstalledEgoBrowser();
      } on Object {
        // Chrome and native providers do not depend on an installed Ego helper.
      }
      if (_hostDisposed) return;
      final batches = await DeviceCredentialBatchHost.start(
        directory: Directory(widget.profiles.directory),
        driver: driver,
        nativeDriver: nativeDriver,
        ownsNativeDriver: true,
        egoExecutable: browser,
      );
      nativeTransferred = true;
      if (_hostDisposed) {
        await batches.close();
      } else {
        _credentialBatchHost = batches;
      }
    } on Object {
      // An absent optional helper or occupied locator never impersonates a live
      // filling capability and must not prevent the owner opening their library.
    } finally {
      if (!nativeTransferred) {
        try {
          await nativeDriver?.dispose();
        } on Object {
          // The adapter also invalidates references when its owner pipe closes.
        }
      }
    }
  }

  Future<void> _restore() async {
    try {
      if (_initialQuitting) return;
      final active = await AutomaticConnectionStore(
        widget.profiles.directory,
      ).readOwner();
      if (_initialQuitting) return;
      if (active?['mode'] != 'local') {
        final saved = await widget.profiles.read();
        if (_initialQuitting) return;
        if (saved != null) {
          final recovered = await _recoverLocal(saved);
          if (recovered != null) {
            _startLocal(recovered);
          } else if (mounted && !_initialQuitting) {
            setState(() => _online = true);
          }
          return;
        }
      }
      if (active == null &&
          await FileSystemEntity.type(
                '${widget.profiles.directory}/local/library.db',
                followLinks: false,
              ) ==
              FileSystemEntityType.notFound) {
        if (mounted && !_initialQuitting) {
          setState(
            () => _initialSetup = ServerSetupController(
              onBusy: (busy) {
                if (busy) {
                  _setupSettled = Completer<void>();
                } else {
                  final settled = _setupSettled;
                  _setupSettled = null;
                  settled?.complete();
                }
              },
              onLocal: () async {
                if (_initialQuitting) return;
                final configuration = await LocalLibraryConfiguration.open(
                  widget.profiles.directory,
                );
                _startLocal(configuration);
              },
              onConnected: (profile, client) async {
                if (_initialQuitting) return;
                // Remember a successful authenticated server connection before the
                // potentially interrupted first content transfer; never a password.
                await widget.profiles.save(profile);
                if (_initialQuitting) return;
                await _adoptServer(profile, client, true);
              },
            ),
          );
        }
        return;
      }
      final configuration = await LocalLibraryConfiguration.open(
        widget.profiles.directory,
      );
      if (active?['mode'] == 'local' &&
          active?['libraryId'] != configuration.libraryId) {
        throw const RemoteFailure('invalid_profile');
      }
      if (active?['mode'] == 'local' &&
          await FileSystemEntity.type(
                '${configuration.libraryDirectory}/library.db',
                followLinks: false,
              ) !=
              FileSystemEntityType.file) {
        throw const RemoteFailure('local_library_missing');
      }
      _startLocal(configuration);
    } on Object {
      if (mounted && !_initialQuitting) {
        setState(() => _failure = '无法打开资料库设置，请检查本机资料目录或使用备份恢复。');
      }
    }
  }

  Future<DesktopLibrary> _openLocal(
    LocalLibraryConfiguration configuration,
    bool interaction,
  ) =>
      widget.openLocal?.call(configuration, interaction) ??
      openLocalLibrary(configuration, requestKeyAccess: interaction);

  Future<LocalLibraryConfiguration?> _recoverLocal(
    ConnectionProfile profile,
  ) async {
    try {
      final stored = await PrivateConnectionFiles.read(
        File('${widget.profiles.directory}/library-sync.json'),
      );
      if (_initialQuitting) return null;
      if (stored == null ||
          stored['version'] != 1 ||
          await FileSystemEntity.type(
                '${widget.profiles.directory}/local/library.db',
                followLinks: false,
              ) !=
              FileSystemEntityType.file) {
        return null;
      }
      final configuration = await LocalLibraryConfiguration.open(
        widget.profiles.directory,
      );
      if (_initialQuitting) return null;
      if (stored['localLibraryId'] != configuration.libraryId) return null;
      final library = await _openLocal(configuration, false);
      try {
        if (library.replication == null) return null;
        final recovered = await LocalLibrarySync(
          configuration: configuration,
          owner: library.service.owner,
          replication: library.replication!,
        ).recoverCompletedLocalCopy(profile);
        return recovered ? configuration : null;
      } finally {
        await library.service.close();
        await library.close();
      }
    } on Object {
      return null;
    } // Keep the previous server selection and data.
  }

  void _startLocal(LocalLibraryConfiguration configuration) {
    if (!mounted || _initialQuitting) return;
    final platform = _platform;
    final bootstrap = DesktopBootstrap(
      openLibrary: () => _openLocal(configuration, false),
      openLibraryWithKeyAccess: Platform.isMacOS
          ? () => _openLocal(configuration, true)
          : null,
      platform: platform,
      port: 0,
      localConfiguration: configuration,
      closeDeviceFocusedFillHost: _closeFocusedFillHost,
      openAppControl:
          Platform.isMacOS &&
              platform is NativeDesktopPlatform &&
              widget.appControlDirectory != null
          ? (state, quit) => MacDesktopControlHost.start(
              directory: widget.appControlDirectory!,
              state: state,
              quit: quit,
            )
          : null,
    );
    if (mounted) {
      setState(() {
        _local = bootstrap;
      });
    }
  }

  Future<void> _adoptServer(
    ConnectionProfile profile,
    OwnerClient client,
    bool enabled,
  ) async {
    // Verify support before opening a new system key or selecting local data.
    await LibraryReplicationClient(client).status();
    if (_initialQuitting) return;
    final configuration = await LocalLibraryConfiguration.open(
      widget.profiles.directory,
    );
    if (_initialQuitting) return;
    final library = await _openLocal(configuration, false);
    try {
      final replication = library.replication;
      if (replication == null) throw const RemoteFailure('unsupported_sync');
      await LocalLibrarySync(
        configuration: configuration,
        owner: library.service.owner,
        replication: replication,
      ).connect(profile, enabled: enabled, connection: client);
    } finally {
      await library.service.close();
      await library.close();
    }
    if (!mounted || _initialQuitting) return;
    // Retire the server workspace first. Its client/menu must not be disposed
    // after the new local runtime has already installed its handlers.
    setState(() {
      _online = false;
      _failure = null;
    });
    final binding = WidgetsBinding.instance;
    if (binding.framesEnabled) {
      await binding.endOfFrame.timeout(
        const Duration(milliseconds: 250),
        onTimeout: () {},
      );
    }
    if (mounted) _startLocal(configuration);
  }

  Future<void> _closeFocusedFillHost() {
    _hostDisposed = true;
    return _fillHostsClosing ??= (() async {
      await _credentialFillStartup;
      try {
        await _credentialBatchHost?.close();
      } finally {
        await _focusedFillHost?.close();
      }
    })();
  }

  @override
  void dispose() {
    unawaited(_closeFocusedFillHost());
    _initialSetup?.dispose();
    final bootstrap = _local;
    if (bootstrap != null) {
      bootstrap.close().whenComplete(bootstrap.dispose);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initialQuitting) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: zhiyuTheme(Brightness.light),
        home: Scaffold(
          body: ConnectionSurface(
            title: _initialExitFailed ? '退出未完成' : '正在退出应用…',
            description: _initialExitFailed
                ? '本机资源尚未关闭或应用未能退出，请重试。'
                : '正在关闭本机连接。',
            loading: !_initialExitFailed,
            children: [
              if (_initialExitFailed)
                TextButton(
                  onPressed: _closeUnconfiguredDesktop,
                  child: const Text('重试退出'),
                ),
            ],
          ),
        ),
      );
    }
    if (_online) {
      return OnlineDesktopLauncher(
        profiles: widget.profiles,
        onSaveStorage: _adoptServer,
        appControlDirectory: widget.appControlDirectory,
        desktopPlatform: _platform,
        closeDeviceFocusedFillHost: _closeFocusedFillHost,
      );
    }
    final bootstrap = _local;
    if (bootstrap != null) return widget.localBuilder(bootstrap);
    if (_initialSetup case final setup?) {
      return InitialConnectionSetup(draft: setup, onComplete: () {});
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: zhiyuTheme(Brightness.light),
      home: Scaffold(
        body: ConnectionSurface(
          title: _failure == null ? '正在打开本地资料库…' : '资料库暂时无法打开',
          description: _failure ?? '',
          loading: _failure == null,
          icon: Icons.storage_outlined,
          children: const [],
        ),
      ),
    );
  }
}
