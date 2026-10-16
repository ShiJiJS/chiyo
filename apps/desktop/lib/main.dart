import 'approvals.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'library.dart';

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
    runApp(InformationApp(service: service, port: server.port));
  } on Object {
    service?.close();
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

class InformationApp extends StatelessWidget {
  const InformationApp({super.key, required this.service, required this.port});
  final InformationService service;
  final int port;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '信息访问授权',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff245c51)),
      useMaterial3: true,
    ),
    home: DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('信息访问授权'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '访问审批'),
              Tab(text: '我的信息'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            Approvals(service: service, port: port),
            InformationLibrary(owner: service.owner),
          ],
        ),
      ),
    ),
  );
}
