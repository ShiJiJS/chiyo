import 'dart:async';
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
            _Approvals(service: service, port: port),
            InformationLibrary(owner: service.owner),
          ],
        ),
      ),
    ),
  );
}

class _Approvals extends StatefulWidget {
  const _Approvals({required this.service, required this.port});
  final InformationService service;
  final int port;
  @override
  State<_Approvals> createState() => _ApprovalsState();
}

class _ApprovalsState extends State<_Approvals> {
  Timer? _refresh;
  final _selection = <String, Set<FieldRef>>{};
  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _manage(VoidCallback action) {
    try {
      action();
      setState(() {});
    } on AccessFailure {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请求状态已变化，请重新检查。')));
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final requests = widget.service.owner.requests;
    return Scaffold(
      appBar: AppBar(title: const Text('信息访问授权 · 开发演示')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                '决定本次聊天可以读取什么',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                '目前仅使用虚构内存资料；请勿录入真实信息。关闭程序会使当前授权失效。加密存储与 Codex 接入尚未实现。',
              ),
              const SizedBox(height: 8),
              Text(
                '本机 CLI 服务已启动 · 127.0.0.1:${widget.port}',
                style: const TextStyle(color: Color(0xff245c51)),
              ),
              const Divider(height: 32),
              if (requests.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Text('暂无访问请求。使用 CLI 查询目录并提交申请。'),
                ),
              for (final request in requests) _requestView(request),
              const SizedBox(height: 24),
              const Text('授权仅包含选中的信息字段，新增信息需要重新申请。撤销可以阻止后续读取，无法收回已经提供的内容。'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _requestView(Map<String, Object?> request) {
    final id = request['requestId'] as String;
    final fields = (request['fields'] as List)
        .map((f) => FieldRef(f['itemId'] as String, f['fieldId'] as String))
        .toList();
    final selected = _selection.putIfAbsent(id, () => fields.toSet());
    final state = request['status'];
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '聊天：${request['chatLabel']}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(request['purpose'] as String),
            const Text(
              '聊天名称与用途由 agent 自述，仅供判断。',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (state == 'pending') ...[
              for (final field in fields)
                CheckboxListTile(
                  key: ValueKey('field-${field.fieldId}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    field.fieldId == 'host' ? '虚构服务器 · 地址' : '虚构服务器 · 用户名',
                  ),
                  subtitle: Text('${field.itemId} / ${field.fieldId}'),
                  value: selected.contains(field),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      selected.add(field);
                    } else {
                      selected.remove(field);
                    }
                  }),
                ),
              const Text('有效期：批准后 8 小时，读取不会延长有效期。'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => _manage(
                        () =>
                            widget.service.owner.approve(id, selected.toList()),
                      ),
                child: const Text('批准所选字段'),
              ),
            ] else ...[
              Text(
                state == 'approved'
                    ? '已批准'
                    : state == 'revoked'
                    ? '已撤销'
                    : '已过期',
              ),
              Text(
                '已批准字段：${(request['approvedFields'] as List).map((f) => f['fieldId']).join(', ')}',
              ),
              Text('到期时间：${request['expiresAt']}'),
              if (state == 'approved')
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton(
                    onPressed: () =>
                        _manage(() => widget.service.owner.revoke(id)),
                    child: const Text('撤销授权'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
