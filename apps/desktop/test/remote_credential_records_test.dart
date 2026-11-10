import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/workspace/remote_workspace_credentials.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/owner_credential_routes.dart';
import 'package:info_workspace/workspace_source.dart';
import '../../server/test/support/tls_fixture.dart';

void main() {
  late Directory root;
  late InformationService service;
  late HttpServer server;
  late OwnerClient client;
  late RemoteWorkspaceCredentials source;
  late OwnerCredentialRoutes routes;
  var responseMode = '';
  final responses = <String>[];
  const privateMaterial = 'SYNTHETIC_RECORDS_TOKEN_NEVER_IN_METADATA';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('credential-records-tls-');
    addTearDown(() => root.delete(recursive: true));
    final tls = await createTlsFixture(root);
    service = InformationService(
      repository: MemoryInformationRepository(),
      credentialExecutableInspector: (path, _) async =>
          ExecutableIdentity(path, 1, 1, 'sha256:${'a' * 64}'),
    );
    routes = OwnerCredentialRoutes(service.owner);
    addTearDown(service.close);
    addTearDown(routes.dispose);
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      SecurityContext()
        ..useCertificateChain(tls.certificate)
        ..usePrivateKey(tls.privateKey),
    );
    responseMode = '';
    addTearDown(() => server.close(force: true));
    responses.clear();
    server.listen((request) async {
      Object body;
      var code = 200;
      try {
        if (request.headers.value('authorization') !=
            'Bearer synthetic-owner') {
          code = 401;
          body = {'error': 'unauthorized'};
        } else if (request.uri.path == '/v1/server') {
          body = {'protocolVersion': 1, 'serverId': 'credential-records-test'};
        } else if (responseMode == 'old-server') {
          code = 404;
          body = {'error': 'not_found'};
        } else {
          expect(request.method, 'GET');
          final result = await routes.dispatch(
            'GET',
            request.uri.pathSegments,
            null,
          );
          code = result.$1;
          body = result.$2;
          if (responseMode == 'wrong-record') {
            final map = Map<String, Object?>.from(body as Map);
            if (map['requests'] case final List values) {
              map['requests'] = [
                for (final value in values)
                  {...value as Map, 'credentialId': 'another-credential'},
              ];
            } else {
              map['credentialId'] = 'another-credential';
            }
            body = map;
          }
        }
      } catch (_) {
        code = 500;
        body = {'error': 'fixture-failed'};
      }
      final encoded = jsonEncode(body);
      responses.add(encoded);
      request.response.statusCode = code;
      request.response.headers.set(
        'x-chiyo-server-id',
        'credential-records-test',
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(encoded);
      await request.response.close();
    });
    client = await OwnerClient.connect(
      address: Uri.parse('https://127.0.0.1:${server.port}'),
      token: 'synthetic-owner',
      expectedServerId: 'credential-records-test',
      trust: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(tls.ca),
    );
    source = RemoteWorkspaceCredentials(client, changed: () {});
    addTearDown(client.close);
    addTearDown(source.dispose);
  });

  Future<(WorkspaceRecordRef, String)> request(String name) async {
    var credential = await service.owner.createStringCredential(
      name: name,
      publicPurpose: 'Synthetic records check',
      secret: privateMaterial,
    );
    credential = await service.owner.updateCredentialMetadata(
      credential.id,
      credential.revision,
      name: name,
      publicPurpose: credential.publicPurpose,
      privateNote: '',
      suggestedBinding: 'material',
      discoverable: true,
    );
    final session = service.agent.openSession('Synthetic record chat');
    final requested = await service.agent.requestCredentialUse(
      session,
      CredentialUseInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Read metadata',
        'credentials': [
          {'alias': 'material', 'credentialId': credential.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'gh_token',
          'executable': Platform.isWindows
              ? r'C:\receiver\gh.exe'
              : '/receiver/gh',
          'argv': ['api', 'user'],
          'cwd': root.path,
          'env': {
            'GH_TOKEN': {'secret': 'material'},
          },
        },
      }),
    );
    return (
      WorkspaceRecordRef(WorkspaceRecordKind.credential, credential.id),
      requested.id,
    );
  }

  test(
    'TLS owner records filter the selected credential and follow real approval/revocation without secrets',
    () async {
      final (ref, id) = await request('Selected credential');
      await request('Other credential');
      expect((await source.requests()).length, 2);
      expect(
        (await source.requests(ref: ref)).single.state,
        WorkspaceCredentialRequestState.pending,
      );
      await service.owner.decideCredentialUse(id, approveCredential: true);
      expect(
        (await source.requests(ref: ref)).single.state,
        WorkspaceCredentialRequestState.approved,
      );
      final approved = (await source.history(ref)).single;
      expect(approved.grantId, id);
      expect(approved.operations.single.description, '用户审批');
      final deadline = approved.expiresAt;
      await service.owner.revokeCredentialUse(id);
      expect(
        (await source.requests(ref: ref)).single.state,
        WorkspaceCredentialRequestState.revoked,
      );
      final revoked = (await source.history(ref)).single;
      expect(revoked.expiresAt, deadline);
      expect(revoked.operations.map((o) => o.description), contains('用户撤销'));
      for (final text in responses) {
        expect(text, isNot(contains(privateMaterial)));
        for (final field in [
          'sessionSecret',
          'executionCapability',
          'supervisorPid',
          'deviceToken',
        ]) {
          expect(text, isNot(contains('"$field"')));
        }
      }
    },
  );

  test(
    'mixed-record responses are rejected instead of showing another credential history',
    () async {
      final (ref, _) = await request('Selected credential');
      responseMode = 'wrong-record';
      final failure = throwsA(
        isA<WorkspaceFailure>().having((e) => e.code, 'code', 'unavailable'),
      );
      await expectLater(source.requests(ref: ref), failure);
      await expectLater(source.history(ref), failure);
    },
  );

  test(
    'an older server reports missing capability rather than empty history or deleted credential',
    () async {
      final (ref, _) = await request('Selected credential');
      responseMode = 'old-server';
      final failure = throwsA(
        isA<WorkspaceFailure>().having((e) => e.code, 'code', 'unsupported'),
      );
      await expectLater(source.requests(ref: ref), failure);
      await expectLater(source.history(ref), failure);
    },
  );
}
