import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:test/test.dart';

class _Driver implements FocusedFillDriver {
  int preparations = 0, batches = 0;
  Completer<void>? gate;
  @override
  Future<PreparedFocusedFill> prepare(
    FocusedFillApplication application,
  ) async {
    preparations++;
    await gate?.future;
    return _Prepared(this, application);
  }
}

class _Prepared implements PreparedFocusedFill {
  _Prepared(this.driver, this.application);
  final _Driver driver;
  @override
  final FocusedFillApplication application;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async {
    driver.batches++;
    return const FocusedFillBatchResult(FocusedFillState.sent);
  }

  @override
  Future<void> close() async {}
}

class _Fixture {
  _Fixture(
    this.service,
    this.server,
    this.client,
    this.driver,
    this.credential,
  );
  final InformationService service;
  final AgentServer server;
  final AgentClient client;
  final _Driver driver;
  final ManagedCredential credential;
  Map<String, dynamic> request() => {
    'command': 'request-use',
    'purpose': 'Synthetic login',
    'credentials': [
      {'alias': 'password', 'credentialId': credential.id, 'version': 1},
    ],
    'fill': {
      'application': {
        'executable': r'C:\Apps\FixtureBrowser.exe',
        'sha256': '31' * 32,
      },
      'targetHint': 'https://portal.example.invalid/login',
    },
  };
  Future<String> approved() async {
    final pending = await client.execute(request());
    expect(pending['status'], 'pending');
    final id = pending['requestId'] as String;
    await service.owner.decideCredentialUse(id, approveCredential: true);
    return id;
  }
}

Future<_Fixture> _fixture({bool enabled = true, bool native = true}) async {
  final driver = _Driver();
  final service = InformationService(
    repository: MemoryInformationRepository(),
    focusedFillDriver: native ? driver : null,
    focusedFillApplicationInspector: (a) async => a,
  );
  var credential = await service.owner.createStringCredential(
    name: 'Synthetic password',
    publicPurpose: 'Login',
    secret: 'synthetic-secret-never-returned',
  );
  credential = await service.owner.updateCredentialMetadata(
    credential.id,
    credential.revision,
    name: credential.name,
    publicPurpose: 'Login',
    privateNote: '',
    suggestedBinding: 'PASSWORD',
    discoverable: true,
  );
  final server = await AgentServer.start(
    service.agent,
    port: 0,
    enableReusableCredentialUse: true,
    enableFocusedFill: enabled,
  );
  final client = AgentClient(server.port);
  expect(
    (await client.execute({
      'command': 'session',
      'chatLabel': 'Synthetic CLI fill',
    }))['status'],
    'ok',
  );
  addTearDown(() async {
    if (driver.gate case final gate?) {
      if (!gate.isCompleted) gate.complete();
    }
    client.close();
    await service.close();
    await server.close();
  });
  return _Fixture(service, server, client, driver, credential);
}

void main() {
  test(
    'independent JSON-lines CLI can request, reuse, and query fills while all secret handling stays in its resident host',
    () async {
      final f = await _fixture();
      final compiled = Platform.environment['D35_COMPILED_CLI'];
      final process = await Process.start(
        compiled ?? Platform.resolvedExecutable,
        [
          if (compiled == null) ...['run', 'bin/info.dart'],
          '--port',
          '${f.server.port}',
        ],
      );
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      var exited = false;
      addTearDown(() async {
        if (!exited) {
          await process.stdin.close();
          await process.exitCode.timeout(const Duration(seconds: 15));
        }
        await lines.cancel();
        await errors;
      });
      final replies = <Map<String, dynamic>>[];
      Future<Map<String, dynamic>> command(Map<String, dynamic> input) async {
        process.stdin.writeln(jsonEncode(input));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        final result = jsonDecode(lines.current) as Map<String, dynamic>;
        replies.add(result);
        return result;
      }

      expect(
        (await command({
          'command': 'session',
          'chatLabel': 'Independent fill CLI',
        }))['status'],
        'ok',
      );
      final pending = await command(f.request());
      expect(pending['status'], 'pending');
      final request = pending['requestId'] as String;
      await f.service.owner.decideCredentialUse(
        request,
        approveCredential: true,
      );
      for (final id in ['one', 'two']) {
        expect(
          (await command({
            'command': 'fill-use',
            'requestId': request,
            'operationId': id,
          }))['status'],
          anyOf('accepted', 'ok'),
        );
        await f.service.drainFocusedFills();
        expect(
          (await command({
            'command': 'fill-status',
            'requestId': request,
            'operationId': id,
          }))['fillState'],
          'sent',
        );
      }
      await command({
        'command': 'fill-use',
        'requestId': request,
        'operationId': 'one',
      });
      expect(f.driver.preparations, 2);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
      exited = true;
      final transcript = jsonEncode(replies) + (await errors);
      for (final value in [
        'synthetic-secret-never-returned',
        'sessionSecret',
        'executionCapability',
        'bytesBase64',
      ]) {
        expect(transcript, isNot(contains(value)));
      }
    },
  );
  test(
    'public CLI request, owner approval, fill, query and reuse traverse real loopback HTTP without secret output',
    () async {
      final f = await _fixture();
      final request = await f.approved();
      final expiry =
          f.service.owner.credentialUseRequests.single.credentialExpiresAt;
      final replies = <Map<String, dynamic>>[];
      for (final id in ['one', 'two']) {
        replies.add(
          await f.client.execute({
            'command': 'fill-use',
            'requestId': request,
            'operationId': id,
          }),
        );
        await f.service.drainFocusedFills();
        replies.add(
          await f.client.execute({
            'command': 'fill-status',
            'requestId': request,
            'operationId': id,
          }),
        );
        expect(replies.last['fillState'], 'sent');
        expect(replies.last['protocolVersion'], 2);
      }
      expect(f.driver.preparations, 2);
      expect(
        f.service.owner.credentialUseRequests.single.credentialExpiresAt,
        expiry,
      );
      final encoded = jsonEncode(replies);
      expect(encoded, isNot(contains('synthetic-secret-never-returned')));
      for (final key in [
        'exitCode',
        'cleanupState',
        'bytesBase64',
        'executionCapability',
      ]) {
        expect(encoded, isNot(contains(key)));
      }
    },
  );
  test(
    'the capability stays off without explicit host and repository readiness',
    () async {
      for (final pair in [(false, true), (true, false)]) {
        final f = await _fixture(enabled: pair.$1, native: pair.$2);
        expect(
          (await f.client.execute(f.request()))['errorCode'],
          'unsupported_capability',
        );
        expect(f.service.owner.credentialUseRequests, isEmpty);
        expect(f.driver.preparations, 0);
      }
    },
  );
  test(
    'repeat ID through independent clients returns one operation, including after revocation',
    () async {
      final f = await _fixture();
      final request = await f.approved();
      f.driver.gate = Completer<void>();
      final other = AgentClient(
        f.server.port,
        sessionSecret: f.client.sessionSecret,
      );
      addTearDown(other.close);
      final command = {
        'command': 'fill-use',
        'requestId': request,
        'operationId': 'same',
      };
      final first = await f.client.execute(command),
          duplicate = await other.execute(command);
      expect(duplicate['fillId'], first['fillId']);
      expect(duplicate['duplicate'], isTrue);
      f.driver.gate!.complete();
      await f.service.drainFocusedFills();
      await f.service.owner.revokeCredentialUse(request);
      expect((await other.execute(command))['fillState'], 'sent');
      expect(f.driver.preparations, 1);
      expect(
        (await f.client.execute({
          ...command,
          'operationId': 'new',
        }))['errorCode'],
        'grant_revoked',
      );
    },
  );
  test(
    'incompatible version, secret-valued fields and arbitrary target handles are rejected',
    () async {
      final f = await _fixture();
      final request = await f.approved();
      for (final input in [
        {
          'protocolVersion': 1,
          'command': 'fill-use',
          'requestId': request,
          'operationId': 'v1',
        },
        {
          'command': 'fill-use',
          'requestId': request,
          'operationId': 'secret',
          'password': 'must-not-echo',
        },
        {
          'command': 'fill-use',
          'requestId': request,
          'operationId': 'handle',
          'hwnd': 123,
        },
      ]) {
        final result = await f.client.execute(input);
        expect(result['status'], 'invalid_request');
        expect(jsonEncode(result), isNot(contains('must-not-echo')));
      }
      expect(f.driver.preparations, 0);
    },
  );
  test(
    'unknown operation is query-only and cannot be read by another private session',
    () async {
      final f = await _fixture();
      final request = await f.approved();
      final query = {
        'command': 'fill-status',
        'requestId': request,
        'operationId': 'not-submitted',
      };
      expect((await f.client.execute(query))['status'], 'not_found');
      final other = AgentClient(f.server.port);
      addTearDown(other.close);
      await other.execute({
        'command': 'session',
        'chatLabel': 'Other private chat',
      });
      expect((await other.execute(query))['status'], 'unauthorized');
      expect(f.driver.preparations, 0);
    },
  );
  test(
    'a missing resident-host reply is unknown and does not fall back to another executor',
    () async {
      final received = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        final input =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        received.add(input);
        if (request.uri.path == '/capabilities') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'status': 'ok',
              'protocolVersions': [1, 2],
              'capabilities': [
                'credential-use-reuse.v1',
                'credential-focused-fill.v1',
              ],
            }),
          );
          await request.response.close();
        } else {
          request.response.statusCode = 503;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"status":"service_unavailable"}');
          await request.response.close();
        }
      });
      final client = AgentClient(
        server.port,
        sessionSecret: 'synthetic-private-session',
        credentialProcessStarter: (a, b, c, d) async =>
            throw StateError('No fallback is allowed'),
      );
      addTearDown(() async {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
      });
      final result = await client.execute({
        'command': 'fill-use',
        'requestId': 'request',
        'operationId': 'operation',
      });
      expect(result['errorCode'], 'fill_unknown');
      expect(result['operationClaimed'], isTrue);
      expect(result['retryable'], isFalse);
      expect(received.length, 2);
    },
  );
}
