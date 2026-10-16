import 'approvals.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'library.dart';
import 'import_proposals.dart';
import 'desktop_runtime.dart';
import 'backups.dart';
import 'history.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  EncryptedInformationRepository? repository;
  InformationService? service;
  try {
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
    repository = await EncryptedInformationRepository.open(directory, keys);
    service = InformationService(repository: repository);
    final server = await AgentServer.start(service.agent);
    final runtime = DesktopRuntime(
      service: service,
      platform: NativeDesktopPlatform(),
      closeServer: server.close,
      closeRepository: repository.close,
    );
    await runtime.start();
    runApp(
      InformationApp(
        service: service,
        port: server.port,
        runtime: runtime,
        backups: repository.backups,
      ),
    );
  } on Object {
    await service?.close();
    await repository?.close();
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              '资料库或本机服务无法启动。请检查系统密钥是否可用、应用是否已运行。原有资料不会被重建或覆盖；请保留资料库与密钥文件。',
            ),
          ),
        ),
      ),
    );
  }
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
  @override
  void initState() {
    super.initState();
    widget.runtime?.addListener(_runtimeChanged);
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
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '信息访问授权',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff245c51)),
      useMaterial3: true,
    ),
    home: Scaffold(
      appBar: AppBar(
        title: const Text('信息访问授权'),
        actions: [
          if (widget.runtime case final runtime?) ...[
            TextButton(
              onPressed: runtime.quitting ? null : runtime.enableNotifications,
              child: const Text('启用或检查通知'),
            ),
            TextButton(
              onPressed: runtime.quitting ? null : runtime.quit,
              child: Text(
                runtime.quitting
                    ? '正在退出…'
                    : runtime.shutdownFailed
                    ? '重试保存并退出'
                    : '完全退出',
              ),
            ),
          ],
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: '访问审批'),
            Tab(text: '我的信息'),
            Tab(text: '录入提案'),
            Tab(text: '授权历史'),
            if (widget.backups != null) Tab(text: '备份恢复'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (widget.runtime?.recycleCleanupFailed == true)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('回收站到期清理暂时失败，请检查存储。到期内容无法恢复，应用会再次尝试清理。'),
            ),
          if (widget.runtime?.revisionCleanupFailed == true)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('修改历史到期清理暂时失败，请检查存储。到期版本无法查看或恢复，应用会再次尝试清理。'),
            ),
          if (widget.runtime?.shutdownFailed == true)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('访问服务已停止，但记录尚未保存，应用未退出。请修复存储后重试保存并退出；重新启动后需要重新申请授权。'),
            ),
          if (widget.runtime case final runtime?)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '${runtime.availability.tray ? '关窗后继续运行，可从托盘或菜单栏打开审批。' : '托盘或菜单栏不可用，关闭按钮将保留窗口；可选择完全退出。'} '
                '${switch (runtime.availability.notifications) {
                  NotificationAvailability.enabled => '系统通知已启用，可能受系统勿扰设置影响。',
                  NotificationAvailability.notEnabled => '系统通知尚未启用，待办仍保留在访问审批。',
                  NotificationAvailability.denied => '系统通知已被拒绝，请在系统设置中允许后检查。',
                  NotificationAvailability.unavailable => '系统通知暂不可用，请在访问审批中查看新申请。',
                }}',
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                Approvals(service: widget.service, port: widget.port),
                InformationLibrary(owner: widget.service.owner, refresh: _tabs),
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
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
