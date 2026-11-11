import 'dart:io';

import 'package:flutter/material.dart';
import 'package:info_core/macos_desktop_control.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/local_library_configuration.dart';
import 'package:info_remote/owner_client.dart';

import 'connection_view.dart';
import 'desktop_bootstrap.dart';
import 'desktop_runtime.dart';
import 'online_desktop_launcher.dart';
import 'platform/local_library.dart';
import 'workspace/zhiyu_theme.dart';

/// Resolves the persisted active library before opening any data or key.
class StorageDesktopLauncher extends StatefulWidget {
  const StorageDesktopLauncher({
    super.key,
    required this.profiles,
    required this.localBuilder,
    this.appControlDirectory,
    this.platform,
    this.openLocal,
  });

  final PrivateConnectionProfileStore profiles;
  final Widget Function(DesktopBootstrap) localBuilder;
  final Directory? appControlDirectory;
  final DesktopPlatform? platform;
  final Future<DesktopLibrary> Function(LocalLibraryConfiguration, bool)?
  openLocal;

  @override
  State<StorageDesktopLauncher> createState() => _StorageDesktopLauncherState();
}

class _StorageDesktopLauncherState extends State<StorageDesktopLauncher> {
  DesktopBootstrap? _local;
  bool _online = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final active = await AutomaticConnectionStore(
        widget.profiles.directory,
      ).readOwner();
      if (active?['mode'] != 'local' && await widget.profiles.read() != null) {
        if (mounted) setState(() => _online = true);
        return;
      }
      final configuration = await LocalLibraryConfiguration.open(
        widget.profiles.directory,
      );
      if (active?['mode'] == 'local' &&
          active?['libraryId'] != configuration.libraryId) {
        throw const RemoteFailure('invalid_profile');
      }
      Future<DesktopLibrary> open(bool interaction) =>
          widget.openLocal?.call(configuration, interaction) ??
          openLocalLibrary(configuration, requestKeyAccess: interaction);
      final platform = widget.platform ?? NativeDesktopPlatform();
      final bootstrap = DesktopBootstrap(
        openLibrary: () => open(false),
        openLibraryWithKeyAccess: Platform.isMacOS ? () => open(true) : null,
        platform: platform,
        port: 0,
        localConfiguration: configuration,
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
      if (mounted) setState(() => _local = bootstrap);
    } on Object {
      if (mounted) setState(() => _failure = '无法打开资料库设置，请检查本机资料目录或使用备份恢复。');
    }
  }

  @override
  void dispose() {
    final bootstrap = _local;
    if (bootstrap != null) {
      bootstrap.close().whenComplete(bootstrap.dispose);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_online) {
      return OnlineDesktopLauncher(
        profiles: widget.profiles,
        appControlDirectory: widget.appControlDirectory,
        desktopPlatform: widget.platform,
      );
    }
    final bootstrap = _local;
    if (bootstrap != null) return widget.localBuilder(bootstrap);
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
