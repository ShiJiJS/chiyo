// Synthetic HTTPS/encrypted-library fixture for native App integration tests.
// Start with the server package configuration. Pass the printed base64 value
// as CHIYO_NATIVE_CONNECTION_FIXTURE to approved_workspace_native_test.dart.
// SIGTERM closes the fixture and removes its temporary library and keys.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'device_credential_fixture.dart';

Future<void> main(List<String> arguments) async {
  final menu = arguments.contains('--pending-menu');
  final f = await DeviceCredentialFixture.create();
  final (request, proposalId) = await f.runtime.run(() async {
    final item = await f.runtime.service.owner
        .createInformation('原生连接验收资料', '', [
          const FieldInput('用途', '', '仅供自动测试'),
          if (menu)
            for (var index = 1; index <= 28; index++)
              FieldInput('长范围字段 $index · 此字段完整名称应显示', '', '仅供自动测试'),
        ]);
    final session = f.runtime.service.agent.openSession('原生时间验收聊天');
    final proposal = menu
        ? await f.runtime.service.agent.submitImport(
            session,
            [
              ImportItemInput('原生菜单提案资料', '', [
                const FieldInput('正文', '', '合成正文'),
              ]),
            ],
            title: '原生菜单录入提案',
            purpose: '核对菜单定位',
            agentName: '原生验收 Agent',
          )
        : null;
    final request = await f.runtime.service.agent.request(
      session,
      '原生时间验收',
      [for (final field in item.fields) FieldRef(item.id, field.id)],
      agentName: '原生验收 Agent',
      externalChatId: 'native-timing-chat',
    );
    return (request, proposal);
  });
  // These are generated fixture credentials, never a saved user profile.
  stdout.writeln(
    'NATIVE_CONNECTION_FIXTURE=${base64Encode(utf8.encode(jsonEncode({'address': f.owner.address.toString(), 'token': f.token, 'certificate': f.certificate, 'serverId': f.owner.serverId, 'requestId': request.id, if (proposalId != null) 'proposalId': proposalId})))}',
  );
  final done = Completer<void>();
  final stop = ProcessSignal.sigterm.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });
  await done.future;
  await stop.cancel();
  await f.dispose();
}
