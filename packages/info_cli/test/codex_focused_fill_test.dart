import 'dart:convert';
import 'dart:io';

import 'package:info_cli/codex_association.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

// This is a protocol/association test. It never opens a desktop or sends keys.
class _InputDriver implements FocusedFillDiscoveryDriver {
  final application = FocusedFillApplication.fromJson({
    'executable': r'C:\Synthetic\PasswordReceiver.exe',
    'sha256': '31' * 32,
  });
  int preparations = 0;

  @override
  Future<FocusedFillTarget> inspectTarget() async =>
      FocusedFillTarget.ready(application);

  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication actual) async {
    if (!actual.matches(application)) {
      throw const CredentialUseFailure('application_changed');
    }
    preparations++;
    return _Input(application);
  }
}

class _Input implements PreparedFocusedFill {
  _Input(this.application);
  @override
  final FocusedFillApplication application;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async =>
      const FocusedFillBatchResult(FocusedFillState.sent);
  @override
  Future<void> close() async {}
}

class _Fixture {
  _Fixture(
    this.root,
    this.service,
    this.server,
    this.driver,
    this.reference,
    this.session,
    this.credential,
  );
  final Directory root;
  final InformationService service;
  final AgentServer server;
  final _InputDriver driver;
  final String reference, session;
  final ManagedCredential credential;
  static const password = 'Synthetic-password-中文-with-spaces ';

  static Future<_Fixture> create({bool enabled = true}) async {
    final root = await Directory.systemTemp.createTemp('info-fill-adapter-');
    final driver = _InputDriver();
    final service = InformationService(
      repository: MemoryInformationRepository(),
      focusedFillDriver: driver,
      focusedFillApplicationInspector: (a) async => a,
    );
    final server = await AgentServer.start(
      service.agent,
      port: 0,
      enableReusableCredentialUse: true,
      enableFocusedFill: enabled,
    );
    addTearDown(() async {
      await service.close();
      await server.close();
      await root.delete(recursive: true);
    });
    var credential = await service.owner.createStringCredential(
      name: 'Synthetic portal password',
      publicPurpose: 'Synthetic sign-in test',
      secret: password,
    );
    credential = await service.owner.updateCredentialMetadata(
      credential.id,
      credential.revision,
      name: credential.name,
      publicPurpose: credential.publicPurpose,
      privateNote: '',
      suggestedBinding: '',
      discoverable: true,
    );
    final session = service.agent.openSession('Synthetic adapter chat');
    final reference = await CodexAssociation(
      'synthetic-fill-chat',
      server.port,
      session,
    ).save(root);
    return _Fixture(
      root,
      service,
      server,
      driver,
      reference,
      session,
      credential,
    );
  }

  Map<String, dynamic> request(Map<String, dynamic> application) => {
    'protocolVersion': 2,
    'command': 'request-use',
    'purpose': 'Sign in to the project portal',
    'credentials': [
      {
        'alias': 'portal_password',
        'credentialId': credential.id,
        'version': credential.version,
      },
    ],
    'fill': {
      'application': application,
      'targetHint': 'https://portal.beichen.example/login',
    },
  };

  Future<Map<String, dynamic>> call(
    Map<String, dynamic> input, {
    String chat = 'synthetic-fill-chat',
  }) async {
    final bundle = Platform.environment['INFO_TEST_BUNDLE'];
    final process = await Process.start(
      bundle == null
          ? Platform.resolvedExecutable
          : '$bundle/info-codex${Platform.isWindows ? '.exe' : ''}',
      [
        if (bundle == null) ...['run', 'bin/codex_info.dart'],
      ],
      environment: {'CODEX_THREAD_ID': chat},
    );
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    var exited = false;
    try {
      process.stdin.writeln(jsonEncode({'association': reference, ...input}));
      await process.stdin.close();
      final code = await process.exitCode.timeout(const Duration(seconds: 20));
      exited = true;
      expect(code, 0);
      final raw = await out;
      final errors = await err;
      for (final sensitive in [
        password,
        jsonEncode(password).substring(1, jsonEncode(password).length - 1),
        reference,
        session,
      ]) {
        expect(
          '$raw$errors'.contains(sensitive),
          isFalse,
          reason: 'Adapter output must not contain private inputs.',
        );
      }
      expect(errors, isEmpty);
      return jsonDecode(raw) as Map<String, dynamic>;
    } finally {
      if (!exited) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
    }
  }
}

void main() {
  test('independent adapters stop at unavailable fill capability', () async {
    final f = await _Fixture.create(enabled: false);
    final capabilities = await f.call({'command': 'capabilities'});
    expect(
      capabilities['capabilities'],
      isNot(contains('credential-focused-fill.v1')),
    );
    for (final input in [
      {'protocolVersion': 2, 'command': 'focus-target'},
      f.request(Map<String, dynamic>.from(f.driver.application.toJson())),
    ]) {
      final result = await f.call(input);
      expect(result['errorCode'], 'unsupported_capability');
    }
    expect(f.service.owner.credentialUseRequests, isEmpty);
    expect(f.service.owner.focusedFillOperations, isEmpty);
    expect(f.driver.preparations, 0);
  });

  test(
    'separate adapter processes discover, request once, reuse, query duplicates and obey revocation without returning secrets',
    () async {
      final f = await _Fixture.create();
      final capabilities = await f.call({'command': 'capabilities'});
      expect(capabilities['protocolVersions'], contains(2));
      expect(
        capabilities['capabilities'],
        containsAll([
          'credential-use-reuse.v1',
          'credential-focused-fill.v1',
          'credential-focused-target.v1',
        ]),
      );
      final target = await f.call({'command': 'focus-target'});
      expect(target['targetState'], 'ready');
      expect(f.service.owner.credentialUseRequests, isEmpty);
      final requested = await f.call(
        f.request(Map<String, dynamic>.from(target['application'] as Map)),
      );
      expect(requested['status'], 'pending');
      final request = requested['requestId'] as String;
      Map<String, dynamic> operation(String command, String id) => {
        'protocolVersion': 2,
        'command': command,
        'requestId': request,
        'operationId': id,
      };
      expect(
        (await f.call(operation('fill-use', 'before-approval')))['errorCode'],
        'request_pending',
      );
      expect(f.driver.preparations, 0);
      await f.service.owner.decideCredentialUse(
        request,
        approveCredential: true,
      );
      final deadline =
          f.service.owner.credentialUseRequests.single.credentialExpiresAt;
      expect(
        (await f.call({'command': 'status', 'requestId': request}))['status'],
        'approved',
      );
      for (final id in ['portal-fill-01', 'portal-fill-02']) {
        final started = await f.call(operation('fill-use', id));
        expect(started['duplicate'], false);
        await f.service.drainFocusedFills();
        final result = await f.call(operation('fill-status', id));
        expect(result['fillState'], 'sent');
        expect(result.containsKey('exitCode'), false);
        expect(result.containsKey('executionId'), false);
        expect(result.containsKey('cleanupState'), false);
        final duplicate = await f.call(operation('fill-use', id));
        expect(duplicate['duplicate'], true);
        expect(duplicate['fillState'], 'sent');
      }
      expect(f.driver.preparations, 2);
      expect(f.service.owner.credentialUseRequests.length, 1);
      expect(f.service.owner.focusedFillOperations.length, 2);
      expect(
        f.service.owner.credentialUseRequests.single.credentialExpiresAt,
        deadline,
      );
      expect(
        (await f.call(
          operation('fill-status', 'portal-fill-01'),
          chat: 'unrelated-chat',
        ))['status'],
        'association_unavailable',
      );
      await f.service.owner.revokeCredentialUse(request);
      expect(
        (await f.call(operation('fill-use', 'after-revoke')))['errorCode'],
        'grant_revoked',
      );
      final old = await f.call(operation('fill-use', 'portal-fill-01'));
      expect(old['fillState'], 'sent');
      expect(old['duplicate'], true);
      expect(f.driver.preparations, 2);
      expect(f.service.owner.focusedFillOperations.length, 2);
    },
  );
}
