import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';

List<int> knownHostBytes() {
  final key = base64Encode([
    0,
    0,
    0,
    11,
    ...ascii.encode('ssh-ed25519'),
    0,
    0,
    0,
    32,
    ...List.generate(32, (i) => i + 1),
  ]);
  return utf8.encode('[test.beichen.example]:2222 ssh-ed25519 $key\n');
}

class SshSessionFixture {
  SshSessionFixture(this.service, this.session, this.request, this.field);
  final InformationService service;
  final String session;
  final CredentialUseRequest request;
  final FieldRef field;
  static Future<SshSessionFixture> create({
    required DateTime Function() clock,
    int protocolVersion = 2,
    InformationRepository? repository,
  }) async {
    final service = InformationService(
      repository: repository ?? MemoryInformationRepository(),
      clock: clock,
      credentialExecutableInspector: (p, r) async =>
          ExecutableIdentity(p, 10, 100, 'sha256:${'a' * 64}'),
    );
    await service.owner.configureSshKnownHosts(
      'Synthetic trust',
      knownHostBytes(),
    );
    var c = await service.owner.createFileCredential(
      name: 'Synthetic SSH',
      publicPurpose: 'Tests only',
      fileName: 'identity',
      bytes: utf8.encode('SYNTHETIC KEY NEVER USED FOR AUTHENTICATION'),
    );
    c = await service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: c.publicPurpose,
      privateNote: '',
      suggestedBinding: 'ssh_key',
      discoverable: true,
    );
    final item = await service.owner.createInformation(
      'Synthetic connection',
      '',
      [const FieldInput('Address', '', 'test.beichen.example')],
    );
    final field = FieldRef(item.id, item.fields.single.id);
    final session = service.agent.openSession('Synthetic SSH chat');
    final request = await service.agent.requestCredentialUse(
      session,
      CredentialUseInput.fromJson({
        'protocolVersion': protocolVersion,
        'command': 'request-use',
        'purpose': 'Synthetic multi-step task',
        'credentials': [
          {'alias': 'ssh_key', 'credentialId': c.id, 'version': c.version},
        ],
        'readFields': [field.toJson()],
        'launch': {
          'receiver': 'ssh_identity',
          'executable': Platform.resolvedExecutable,
          'argv': [
            '-T',
            '-o',
            'BatchMode=yes',
            '-i',
            {'file': 'ssh_key'},
            '-p',
            '2222',
            'developer@test.beichen.example',
            '/usr/bin/true',
          ],
          'cwd': Directory.current.path,
          'env': <String, Object?>{},
        },
      }),
    );
    return SshSessionFixture(service, session, request, field);
  }

  CredentialOperationInput operation(String id) =>
      CredentialOperationInput.fromJson({
        'protocolVersion': 2,
        'command': 'run-use',
        'requestId': request.id,
        'operationId': id,
        'launch': request.toRequestInputJson()['launch'],
      });
  Future<CredentialOperationClaim> begin(String id) =>
      service.agent.beginCredentialUseOperation(session, operation(id));
}
