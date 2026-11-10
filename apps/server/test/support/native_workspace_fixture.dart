// Synthetic HTTPS/encrypted-library fixture for native App integration tests.
// Start with the server package configuration. Pass the printed base64 value
// as CHIYO_NATIVE_CONNECTION_FIXTURE to approved_workspace_native_test.dart.
// SIGTERM closes the fixture and removes its temporary library and keys.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'device_credential_fixture.dart';

Future<void> main() async {
  final f = await DeviceCredentialFixture.create();
  final request = await f.runtime.run(() async {
    final item = await f.runtime.service.owner.createInformation(
      '原生连接验收资料',
      '',
      [const FieldInput('用途', '', '仅供自动测试')],
    );
    final session = f.runtime.service.agent.openSession('原生时间验收聊天');
    return f.runtime.service.agent.request(
      session,
      '原生时间验收',
      [FieldRef(item.id, item.fields.single.id)],
      agentName: '原生验收 Agent',
      externalChatId: 'native-timing-chat',
    );
  });
  // These are generated fixture credentials, never a saved user profile.
  stdout.writeln(
    'NATIVE_CONNECTION_FIXTURE=${base64Encode(utf8.encode(jsonEncode({'address': f.owner.address.toString(), 'token': f.token, 'certificate': f.certificate, 'serverId': f.owner.serverId, 'requestId': request.id})))}',
  );
  final done = Completer<void>();
  final stop = ProcessSignal.sigterm.watch().listen((_) {
    if (!done.isCompleted) done.complete();
  });
  await done.future;
  await stop.cancel();
  await f.dispose();
}
