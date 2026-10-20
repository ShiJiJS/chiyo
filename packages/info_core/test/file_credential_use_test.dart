import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

const syntheticAwsFile =
    '[default]\naws_access_key_id = TEST_ACCESS_ONLY\naws_secret_access_key = SYNTHETIC_NOT_A_REAL_SECRET\n';

Future<(InformationService, String, ManagedCredential)> fileSession({
  String content = syntheticAwsFile,
  MemoryInformationRepository? repository,
}) async {
  final service = InformationService(
    repository: repository ?? MemoryInformationRepository(),
    credentialExecutableInspector: (path, receiver) async =>
        ExecutableIdentity(path, 1, 1, 'sha256:controlled'),
  );
  var credential = await service.owner.createFileCredential(
    name: 'Local test AWS',
    publicPurpose: 'Controlled file use',
    fileName: 'credentials.ini',
    bytes: utf8.encode(content),
  );
  credential = await service.owner.updateCredentialMetadata(
    credential.id,
    credential.revision,
    name: credential.name,
    publicPurpose: credential.publicPurpose,
    privateNote: '',
    suggestedBinding: 'aws_key',
    discoverable: true,
  );
  return (
    service,
    service.agent.openSession('File credential test'),
    credential,
  );
}

CredentialUseInput awsInput(
  ManagedCredential c, {
  int protocolVersion = 1,
  List<Object?>? argv,
  Map<String, Object?>? env,
  String? cwd,
}) => CredentialUseInput.fromJson({
  if (protocolVersion != 1) 'protocolVersion': protocolVersion,
  'command': 'request-use',
  'purpose': 'Run an approved local AWS operation',
  'credentials': [
    {'alias': 'aws_key', 'credentialId': c.id, 'version': c.version},
  ],
  'launch': {
    'receiver': 'aws_shared_credentials',
    'executable': Platform.resolvedExecutable,
    'argv':
        argv ??
        [
          'ssm',
          'put-parameter',
          '--name',
          '/test/value',
          '--value',
          '{{file:aws_key}}',
          '--type',
          'String',
          '--region',
          'us-east-1',
        ],
    'cwd': cwd ?? Directory.current.path,
    'env':
        env ??
        {
          'AWS_SHARED_CREDENTIALS_FILE': {'file': 'aws_key'},
        },
  },
});

void main() {
  test(
    'AWS files cannot introduce credential processes, other profiles or duplicate authentication values',
    () async {
      for (final content in [
        '[default]\ncredential_process = external-command\n',
        '$syntheticAwsFile\n[other]\naws_access_key_id = OTHER\n',
        '${syntheticAwsFile}aws_access_key_id = OTHER\n',
        '[default]\naws_access_key_id = TEST\nsso_session = existing-account\n',
      ]) {
        final (service, session, credential) = await fileSession(
          content: content,
        );
        try {
          await expectLater(
            service.agent.requestCredentialUse(session, awsInput(credential)),
            throwsA(
              isA<CredentialUseFailure>().having(
                (e) => e.code,
                'code',
                'material_prepare_failed',
              ),
            ),
          );
          expect(service.owner.credentialUseRequests, isEmpty);
        } finally {
          await service.close();
        }
      }
    },
  );
  test(
    'owner approves one immutable AWS file plan with an explicit isolated configuration, not a shell placeholder',
    () async {
      final (service, session, c) = await fileSession();
      addTearDown(service.close);
      final directory = await Directory.systemTemp.createTemp('受控 工作目录 ');
      addTearDown(() => directory.delete());
      final request = await service.agent.requestCredentialUse(
        session,
        awsInput(c, cwd: directory.path),
      );
      expect(request.plan.argv[5].value, '{{file:aws_key}}');
      expect(request.plan.argv[5].kind, LaunchValueKind.literal);
      expect(
        request.plan.env['AWS_SHARED_CREDENTIALS_FILE']!.kind,
        LaunchValueKind.file,
      );
      expect(
        request.plan.env['AWS_CONFIG_FILE']!.kind,
        LaunchValueKind.internalMaterial,
      );
      expect(request.plan.env['AWS_EC2_METADATA_DISABLED']!.value, 'true');
      expect(request.plan.env['AWS_CLI_AUTO_PROMPT']!.value, 'off');
      expect(
        CredentialUseRequest.fromJson(request.toJson()).plan.planHash,
        request.plan.planHash,
      );
      expect(
        jsonEncode(request.toJson()),
        isNot(contains('SYNTHETIC_NOT_A_REAL_SECRET')),
      );
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
      final material = await service.agent.consumeCredentialUse(
        session,
        request.id,
      );
      addTearDown(() async {
        await service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: material.executionId,
            executionCapability: material.executionCapability,
            state: 'prepare_failed',
            errorCode: 'material_prepare_failed',
            finishedAt: DateTime.now().toUtc(),
          ),
        );
        await service.owner.cleanupCredentialExecution(material.executionId);
      });
      expect(material.credentialMaterial.bytes, utf8.encode(syntheticAwsFile));
      expect(material.approvedPlan.planHash, request.plan.planHash);
      await expectLater(
        service.agent.consumeCredentialUse(session, request.id),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'attempt_consumed',
          ),
        ),
      );
    },
    skip: !Platform.isWindows,
  );
}
