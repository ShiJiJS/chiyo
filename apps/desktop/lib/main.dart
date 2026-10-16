import 'approvals.dart';
import 'package:flutter/material.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final service = InformationService.fictional();
  try {
    final server = await AgentServer.start(service.agent);
    runApp(InformationApp(service: service, port: server.port));
  } on Object {
    service.close();
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('本机服务无法启动。请检查是否已有应用占用端口 47125，然后重新启动。')),
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
    home: Approvals(service: service, port: port),
  );
}
