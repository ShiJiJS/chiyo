import 'approvals.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'information_workspace.dart';
import 'credential_files.dart';
import 'desktop_scroll.dart';
import 'desktop_interaction_host.dart';
import 'import_proposals.dart';
import 'desktop_runtime.dart';
import 'desktop_bootstrap.dart';
import 'backups.dart';
import 'settings.dart';
import 'history.dart';
import 'desktop_shell.dart';
import 'ui.dart';
import 'window_frame.dart';
import 'prototype_dialog.dart';
import 'bundled_focused_fill.dart';
import 'package:info_core/macos_desktop_control.dart';
import 'workspace/owner_workspace_host.dart';
import 'desktop_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS) await loadDesktopFonts(requiredFiles: false);
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Noto Sans SC',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  runApp(
    DesktopLauncher(
      useWorkspace: Platform.isMacOS,
      bootstrap: DesktopBootstrap(
        openLibrary: _openLibrary,
        openLibraryWithKeyAccess: Platform.isMacOS
            ? () => _openLibrary(requestKeyAccess: true)
            : null,
        platform: NativeDesktopPlatform(),
        openAppControl: Platform.isMacOS
            ? (state, quit) {
                final base = Platform.environment['HOME'];
                if (base == null || base.isEmpty) {
                  throw StateError('control_unavailable');
                }
                return MacDesktopControlHost.start(
                  directory: Directory(
                    '$base/Library/Application Support/AgentInfoManage/app-control',
                  ),
                  state: state,
                  quit: quit,
                );
              }
            : null,
      ),
    ),
  );
}

Future<DesktopLibrary> _openLibrary({bool requestKeyAccess = false}) async {
  final String directory;
  final DatabaseKeyStore keys;
  if (Platform.isWindows) {
    final base = Platform.environment['LOCALAPPDATA'];
    if (base == null || base.isEmpty) {
      throw const StorageFailure('directory_unavailable');
    }
    directory = '$base/AgentInfoManage';
    keys = WindowsDatabaseKeyStore('$directory/database-key.dpapi');
  } else if (Platform.isMacOS) {
    final base = Platform.environment['HOME'];
    if (base == null || base.isEmpty) {
      throw const StorageFailure('directory_unavailable');
    }
    directory = '$base/Library/Application Support/AgentInfoManage';
    const channel = MethodChannel('agent_info_manage/database_key');
    keys = MacOsDatabaseKeyStore((method, arguments) {
      return channel.invokeMethod<Object?>(
        requestKeyAccess && method == 'read' ? 'readWithInteraction' : method,
        arguments,
      );
    });
  } else {
    throw const StorageFailure('platform_unsupported');
  }
  final fill = Platform.isWindows ? await loadBundledFocusedFill() : null;
  final repository = await EncryptedInformationRepository.open(directory, keys);
  return DesktopLibrary(
    service: InformationService(
      repository: repository,
      focusedFillDriver: fill,
      informationDeliveryFiles: Platform.isWindows
          ? WindowsInformationDeliveryFiles()
          : Platform.isMacOS
          ? NativeInformationDeliveryFiles()
          : null,
    ),
    close: repository.close,
    backups: repository.backups,
  );
}

class DesktopLauncher extends StatefulWidget {
  const DesktopLauncher({
    super.key,
    required this.bootstrap,
    this.useWorkspace = false,
  });
  final DesktopBootstrap bootstrap;
  final bool useWorkspace;
  @override
  State<DesktopLauncher> createState() => _DesktopLauncherState();
}

class _DesktopLauncherState extends State<DesktopLauncher> {
  @override
  void initState() {
    super.initState();
    if (widget.bootstrap.state == DesktopStartupState.idle) {
      unawaited(widget.bootstrap.start());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.bootstrap,
    builder: (context, _) {
      final startup = widget.bootstrap;
      if (startup.state == DesktopStartupState.ready) {
        final runtime = startup.runtime!;
        return ListenableBuilder(
          listenable: runtime,
          builder: (context, _) {
            // A ready notification can still have a frame queued when quit
            // closes the repository. Never mount/rebuild data views then.
            if (runtime.quitting || runtime.stopped) {
              return MaterialApp(
                theme: informationTheme(),
                debugShowCheckedModeBanner: false,
                builder: (_, child) => DesktopWindowFrame(child: child!),
                home: Scaffold(
                  body: Center(
                    child: runtime.shutdownFailed
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('信息库已关闭，但应用未能退出。请重试退出。'),
                              TextButton(
                                onPressed: runtime.quit,
                                child: const Text('重试退出'),
                              ),
                            ],
                          )
                        : const Text('正在保存并退出…'),
                  ),
                ),
              );
            }
            if (widget.useWorkspace) {
              return OwnerWorkspaceHost(
                key: ValueKey(runtime),
                runtime: runtime,
              );
            }
            return InformationApp(
              service: startup.library!.service,
              port: startup.boundPort!,
              runtime: runtime,
              backups: startup.library!.backups,
            );
          },
        );
      }
      return MaterialApp(
        theme: informationTheme(),
        builder: (_, child) => DesktopWindowFrame(child: child!),
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: startup.keyAccessPending
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      const Text('请在系统提示中确认钥匙串访问。取消后可重新尝试。'),
                      if (startup.keyAccessExitFailed)
                        const Text('应用未能退出，请重试退出。'),
                      TextButton(
                        onPressed: startup.quitKeyAccess,
                        child: Text(
                          startup.keyAccessExitFailed ? '重试退出' : '退出应用',
                        ),
                      ),
                    ],
                  )
                : startup.state != DesktopStartupState.failed
                ? const CircularProgressIndicator()
                : Padding(
                    padding: const EdgeInsets.all(28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: FormSection(
                        title: '无法打开信息库',
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              startup.applicationFilesInvalid
                                  ? '应用文件不完整或版本不匹配。请将桌面程序与辅助程序整包替换后重试。尚未打开信息库，原有资料不会被重建或覆盖。'
                                  : startup.systemKeyUnavailable
                                  ? '无法访问系统钥匙串中的信息库密钥。请确认钥匙串已解锁；如果刚更新应用，请先用原版本导出备份，再处理新版本的钥匙串访问。原有资料不会被重建或覆盖。'
                                  : '信息库或本机服务无法启动。请检查系统密钥是否可用、应用是否已运行。原有资料不会被重建或覆盖；请保留信息库与密钥文件。',
                            ),
                            if (startup.cleanupPending)
                              const Text(
                                '访问服务已停止，但记录尚未保存或信息库尚未关闭。请保留此窗口，修复存储后重试；记录保存成功后才会重新启动。',
                              ),
                            const SizedBox(height: 16),
                            if (startup.canRequestKeyAccess) ...[
                              const Text(
                                '可点击下方按钮，请系统重新请求访问现有密钥。是否允许由你在系统提示中决定；拒绝或密钥缺失不会替换原密钥。',
                              ),
                              TextButton(
                                onPressed: startup.requestKeyAccess,
                                child: const Text('请求钥匙串访问'),
                              ),
                            ],
                            TextButton(
                              style: prototypePrimary(context),
                              onPressed: startup.start,
                              child: Text(
                                startup.cleanupPending ? '重试保存并启动' : '重试启动',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      );
    },
  );
}

class InformationApp extends StatefulWidget {
  const InformationApp({
    super.key,
    required this.service,
    required this.port,
    this.runtime,
    this.backups,
    this.backupFiles = const NativeBackupFilePicker(),
    this.credentialFiles = const NativeCredentialFilePicker(),
  });
  final InformationService service;
  final int port;
  final DesktopRuntime? runtime;
  final InformationBackups? backups;
  final BackupFilePicker backupFiles;
  final CredentialFilePicker credentialFiles;
  @override
  State<InformationApp> createState() => _InformationAppState();
}

class _InformationAppState extends State<InformationApp>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 5, vsync: this);
  int _openRevision = 0;
  int _openSettingsRevision = 0;
  int _searchApprovalsRevision = 0;
  // A restored data source can reset history; ordinary tabs refresh in place.
  int _libraryRevision = 0;
  final _visited = <int>{0};
  String? _focusedInformationId;
  String? _focusedCredentialId;
  int _informationFocusRevision = 0;
  String? _focusedHistoryId;
  int _historyFocusRevision = 0;
  void _openInformation(String id) {
    setState(() {
      _focusedInformationId = id;
      _focusedCredentialId = null;
      _informationFocusRevision++;
      _visited.add(1);
    });
    _tabs.index = 1;
  }

  void _openOrganizationGrant(String taskId) {
    setState(() {
      _focusedHistoryId = taskId;
      _historyFocusRevision++;
      _visited.add(3);
    });
    _tabs.index = 3;
  }

  void _openCredential(String id) {
    setState(() {
      _focusedCredentialId = id;
      _focusedInformationId = null;
      _informationFocusRevision++;
      _visited.add(1);
    });
    _tabs.index = 1;
  }

  void _openCredentialHistory(String id) {
    final requests =
        widget.service.owner.credentialUseRequests
            .where(
              (r) =>
                  r.credentialId == id &&
                  widget.service.owner.credentialUseState(r) != 'pending',
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (requests.isNotEmpty) _openOrganizationGrant(requests.first.id);
  }

  final _approvalsKey = GlobalKey<ApprovalsState>();
  late DesktopColorTheme _colorTheme = widget.service.owner.colorTheme;
  bool _themeBusy = false;
  String? _themeError;
  int _settingsNavigationRevision = 0;
  SettingsSection _settingsSection = SettingsSection.appearance;
  void _openRecordSettings() {
    setState(() {
      _settingsSection = SettingsSection.records;
      _settingsNavigationRevision++;
    });
    _tabs.index = 4;
  }

  Future<void> _changeTheme(DesktopColorTheme theme) async {
    if (_themeBusy) return;
    setState(() {
      _themeBusy = true;
      _themeError = null;
    });
    try {
      await widget.service.owner.setColorTheme(theme);
      if (mounted) {
        setState(() => _colorTheme = widget.service.owner.colorTheme);
      }
    } catch (_) {
      if (mounted) setState(() => _themeError = '主题未保存，仍使用上次的颜色。请重试。');
    } finally {
      if (mounted) setState(() => _themeBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.runtime?.addListener(_runtimeChanged);
    _tabs.addListener(_tabChanged);
  }

  void _tabChanged() {
    if (!mounted) return;
    setState(() {
      _visited.add(_tabs.index);
    });
  }

  void _runtimeChanged() {
    final runtime = widget.runtime!;
    if (runtime.openApprovalsRevision != _openRevision) {
      _openRevision = runtime.openApprovalsRevision;
      _tabs.index = 0;
    }
    if (runtime.openSettingsRevision != _openSettingsRevision) {
      _openSettingsRevision = runtime.openSettingsRevision;
      _tabs.index = 4;
    }
    if (runtime.searchApprovalsRevision != _searchApprovalsRevision) {
      _searchApprovalsRevision = runtime.searchApprovalsRevision;
      _tabs.index = 0;
      final revision = _searchApprovalsRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _tabs.index == 0 &&
            _searchApprovalsRevision == revision) {
          _approvalsKey.currentState?.focusSearch();
        }
      });
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.runtime?.removeListener(_runtimeChanged);
    _tabs.removeListener(_tabChanged);
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '信息访问授权',
    debugShowCheckedModeBanner: false,
    scrollBehavior: const DesktopScrollBehavior(),
    theme: informationTheme(_colorTheme),
    shortcuts: {
      ...WidgetsApp.defaultShortcuts,
      const SearchInboxActivator(): const SearchInboxIntent(),
    },
    // Keep WidgetsApp's focus, activation and scrolling actions intact. The
    // application-level actions parameter replaces that entire default map.
    builder: (_, child) => Actions(
      actions: {
        SearchInboxIntent: CallbackAction<SearchInboxIntent>(
          onInvoke: (_) {
            if (_tabs.index == 0) _approvalsKey.currentState?.focusSearch();
            return null;
          },
        ),
      },
      child: DesktopInteractionHost(child: DesktopWindowFrame(child: child!)),
    ),
    home: Builder(
      builder: (context) => DesktopShell(
        service: widget.service,
        port: widget.port,
        index: _tabs.index,
        onSelected: (index) => _tabs.index = index,
        runtime: widget.runtime,
        hasBackups: widget.backups != null,
        colorTheme: _colorTheme,
        onThemeChanged: _changeTheme,
        themeBusy: _themeBusy,
        themeError: _themeError,
        child: IndexedStack(
          index: _tabs.index,
          children:
              [
                    Approvals(
                      key: _approvalsKey,
                      service: widget.service,
                      port: widget.port,
                      focusRequestId: widget.runtime?.openRequestId,
                      focusRevision: _openRevision,
                      onOpenSettings: _openRecordSettings,
                    ),
                    InformationWorkspace(
                      owner: widget.service.owner,
                      refresh: _tabs,
                      focusItemId: _focusedInformationId,
                      initialCredentialId: _focusedCredentialId,
                      focusRevision: _informationFocusRevision,
                      onOpenInformation: _openInformation,
                      onOpenUsageHistory: _openCredentialHistory,
                      files: widget.credentialFiles,
                    ),
                    ImportProposalsPage(
                      owner: widget.service.owner,
                      onOpenInformation: _openInformation,
                      onGoToLibrary: () => _tabs.index = 1,
                      onOpenOrganizationGrant: _openOrganizationGrant,
                    ),
                    AuthorizationHistory(
                      visible: _tabs.index == 3,
                      key: ValueKey(_libraryRevision),
                      owner: widget.service.owner,
                      onOpenRecordSettings: _openRecordSettings,
                      initialRecordId: _focusedHistoryId,
                      onOpenCredential: _openCredential,
                      focusRevision: _historyFocusRevision,
                      refresh: _tabs,
                    ),
                    SettingsPage(
                      owner: widget.service.owner,
                      runtime: widget.runtime,
                      backups: widget.backups,
                      files: widget.backupFiles,
                      initialSection: _settingsSection,
                      navigationRevision: _settingsNavigationRevision,
                      onOpenApprovals: () => _tabs.index = 0,
                      onThemeChanged: _changeTheme,
                      themeBusy: _themeBusy,
                      themeError: _themeError,
                      onRestored: () {
                        if (mounted) {
                          setState(() {
                            _libraryRevision++;
                            _colorTheme = widget.service.owner.colorTheme;
                          });
                        }
                      },
                    ),
                  ].indexed
                  .map(
                    // Retained pages must not keep tooltip portals active in
                    // the root overlay while another page owns the interface.
                    (entry) => _visited.contains(entry.$1)
                        ? TooltipVisibility(
                            visible: entry.$1 == _tabs.index,
                            child: entry.$2,
                          )
                        : const SizedBox(),
                  )
                  .toList(),
        ),
      ),
    ),
  );
}
