import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';

List<int> knownHostBytes() => utf8.encode(
  '[test.beichen.example]:2222 ssh-ed25519 ${base64Encode([0, 0, 0, 11, ...ascii.encode('ssh-ed25519'), 0, 0, 0, 32, ...List.generate(32, (i) => i + 1)])}\n',
);

Future<(InformationService, String, CredentialUseRequest)> fileApprovalFixture(
  String receiver, {
  String? executable,
}) async {
  final ssh = receiver == 'ssh_identity';
  final service = InformationService(
    repository: MemoryInformationRepository(),
    clock: () => DateTime(2026, 10, 18, 14, 32),
    credentialExecutableInspector: (path, receiver) async =>
        ExecutableIdentity(path, 1, 1, 'sha256:synthetic-file-ui'),
  );
  final item = await service.owner.createInformation('北辰测试服务器', '', [
    const FieldInput('服务器地址', '', 'test.beichen.example'),
  ]);
  var credential = await service.owner.createFileCredential(
    name: ssh ? '北辰测试 · SSH 私钥' : '北辰服务 · AWS 凭据',
    publicPurpose: ssh ? '连接测试服务器' : '管理测试服务',
    fileName: ssh ? 'id_ed25519' : 'credentials.ini',
    bytes: utf8.encode(
      ssh
          ? 'SYNTHETIC_UI_KEY'
          : '[default]\naws_access_key_id=TEST_ONLY\naws_secret_access_key=SYNTHETIC_UI_SECRET\n',
    ),
  );
  credential = await service.owner.updateCredentialMetadata(
    credential.id,
    credential.revision,
    name: credential.name,
    publicPurpose: credential.publicPurpose,
    privateNote: '',
    suggestedBinding: ssh ? 'SSH_KEY_FILE' : 'AWS_SHARED_CREDENTIALS_FILE',
    discoverable: true,
  );
  credential = await service.owner.setCredentialLinks(
    credential.id,
    credential.revision,
    [item.id],
  );
  if (ssh) {
    await service.owner.configureSshKnownHosts(
      '北辰测试主机 · 已核对',
      knownHostBytes(),
    );
  }
  final session = service.agent.openSession(ssh ? '核对北辰服务器状态' : '核对北辰服务配置');
  final request = await service.agent.requestCredentialUse(
    session,
    CredentialUseInput.fromJson({
      'command': 'request-use',
      'purpose': ssh ? '连接已确认的测试主机，执行一次非交互状态检查。' : '读取测试区域服务配置，核对部署状态。',
      'credentials': [
        {
          'alias': ssh ? 'ssh_key' : 'aws_file',
          'credentialId': credential.id,
          'version': 1,
        },
      ],
      'launch': {
        'receiver': receiver,
        'executable': executable ?? Platform.resolvedExecutable,
        'cwd': Directory.current.path,
        'argv': ssh
            ? [
                '-T',
                '-o',
                'BatchMode=yes',
                '-i',
                {'file': 'ssh_key'},
                '-p',
                '2222',
                'developer@test.beichen.example',
                '/usr/bin/true',
              ]
            : ['sts', 'get-caller-identity', '--region', 'us-east-1'],
        'env': ssh
            ? <String, Object?>{}
            : {
                'AWS_SHARED_CREDENTIALS_FILE': {'file': 'aws_file'},
              },
      },
      'readFields': [
        {'itemId': item.id, 'fieldId': item.fields.single.id},
      ],
    }),
  );
  return (service, session, request);
}
