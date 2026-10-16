import 'approvals.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'library.dart';
import 'import_proposals.dart';
import 'desktop_runtime.dart';
import 'desktop_bootstrap.dart';
import 'backups.dart';
import 'history.dart';
import 'desktop_shell.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Noto Sans SC',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  runApp(
    DesktopLauncher(
      bootstrap: DesktopBootstrap(
        openLibrary: _openLibrary,
        platform: NativeDesktopPlatform(),
      ),
    ),
  );
}

Future<DesktopLibrary> _openLibrary() async {
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
    keys = MacOsDatabaseKeyStore(channel.invokeMethod<Object?>);
  } else {
    throw const StorageFailure('platform_unsupported');
  }
  final repository = await EncryptedInformationRepository.open(directory, keys);
  return DesktopLibrary(
    service: InformationService(repository: repository),
    close: repository.close,
    backups: repository.backups,
  );
}

class DesktopLauncher extends StatefulWidget {
  const DesktopLauncher({super.key, required this.bootstrap});
  final DesktopBootstrap bootstrap;
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
        return InformationApp(
          service: startup.library!.service,
          port: startup.boundPort!,
          runtime: startup.runtime,
          backups: startup.library!.backups,
        );
      }
      return MaterialApp(
        theme: informationTheme(),
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: startup.state != DesktopStartupState.failed
                ? const CircularProgressIndicator()
                : Padding(
                    padding: const EdgeInsets.all(28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: FormSection(
                        title: '无法打开资料库',
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '资料库或本机服务无法启动。请检查系统密钥是否可用、应用是否已运行。原有资料不会被重建或覆盖；请保留资料库与密钥文件。',
                            ),
                            if (startup.cleanupPending)
                              const Text(
                                '访问服务已停止，但记录尚未保存或资料库尚未关闭。请保留此窗口，修复存储后重试；记录保存成功后才会重新启动。',
                              ),
                            const SizedBox(height: 16),
                            FilledButton(
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
  });
  final InformationService service;
  final int port;
  final DesktopRuntime? runtime;
  final InformationBackups? backups;
  final BackupFilePicker backupFiles;
  @override
  State<InformationApp> createState() => _InformationAppState();
}

class _InformationAppState extends State<InformationApp>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(
    length: widget.backups == null ? 4 : 5,
    vsync: this,
  );
  int _openRevision = 0;
  int _libraryRevision = 0;
  final _visited = <int>{0};
  int _activeTab = 0;
  @override
  void initState() {
    super.initState();
    widget.runtime?.addListener(_runtimeChanged);
    _tabs.addListener(_tabChanged);
  }

  void _tabChanged() {
    if (!mounted) return;
    setState(() {
      if (_activeTab != _tabs.index && _tabs.index == 3) _libraryRevision++;
      _activeTab = _tabs.index;
      _visited.add(_tabs.index);
    });
  }

  void _runtimeChanged() {
    final runtime = widget.runtime!;
    if (runtime.openApprovalsRevision != _openRevision) {
      _openRevision = runtime.openApprovalsRevision;
      _tabs.animateTo(0);
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
    theme: informationTheme(),
    home: Builder(
      builder: (context) => DesktopShell(
        service: widget.service,
        port: widget.port,
        index: _tabs.index,
        onSelected: (index) => _tabs.animateTo(
          index,
          duration: MediaQuery.maybeOf(context)?.disableAnimations == true
              ? Duration.zero
              : const Duration(milliseconds: 220),
        ),
        runtime: widget.runtime,
        hasBackups: widget.backups != null,
        child: IndexedStack(
          index: _tabs.index,
          children:
              [
                    Approvals(service: widget.service, port: widget.port),
                    InformationLibrary(
                      owner: widget.service.owner,
                      refresh: _tabs,
                    ),
                    ImportProposalsPage(owner: widget.service.owner),
                    AuthorizationHistory(
                      key: ValueKey(_libraryRevision),
                      owner: widget.service.owner,
                    ),
                    if (widget.backups case final backups?)
                      BackupLibrary(
                        backups: backups,
                        owner: widget.service.owner,
                        files: widget.backupFiles,
                        onRestored: () {
                          if (mounted) setState(() => _libraryRevision++);
                        },
                      ),
                  ].indexed
                  .map(
                    (entry) => _visited.contains(entry.$1)
                        ? entry.$2
                        : const SizedBox(),
                  )
                  .toList(),
        ),
      ),
    ),
  );
}
