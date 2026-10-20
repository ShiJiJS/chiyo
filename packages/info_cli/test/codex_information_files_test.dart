import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_cli/credential_execution_host.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void expectPrivateAbsent(String output, Iterable<String> values) {
  for (final value in values) {
    final encoded = jsonEncode(value);
    for (final representation in [
      value,
      encoded.substring(1, encoded.length - 1),
    ]) {
      expect(output, isNot(contains(representation)));
    }
  }
}

// Real Windows copies/Jobs and independent adapters, but a Memory repository,
// controlled executable classification and fake input. No Codex model or keys.
class _Files implements InformationDeliveryFiles {
  final native = WindowsInformationDeliveryFiles();
  final leases = <InformationDeliveryLease>[];
  @override
  Future<InformationDeliveryLease> reserve(String name) async {
    final lease = await native.reserve(name);
    leases.add(lease);
    return lease;
  }

  @override
  Future<void> write(InformationDeliveryLease lease, Uint8List bytes) =>
      native.write(lease, bytes);
  @override
  Future<void> verify(
    InformationDeliveryLease lease,
    int size,
    String digest,
  ) => native.verify(lease, size, digest);
  @override
  Future<void> cleanup(InformationDeliveryLease lease) => native.cleanup(lease);
}

class _InputDriver implements FocusedFillDiscoveryDriver {
  final application = FocusedFillApplication.fromJson({
    'executable': r'C:\Synthetic\PasswordReceiver.exe',
    'sha256': '31' * 32,
  });
  int sends = 0;
  @override
  Future<FocusedFillTarget> inspectTarget() async =>
      FocusedFillTarget.ready(application);
  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication actual) async {
    if (!actual.matches(application)) {
      throw const CredentialUseFailure('application_changed');
    }
    return _Input(this);
  }
}

class _Input implements PreparedFocusedFill {
  _Input(this.driver);
  final _InputDriver driver;
  final _received = <int>[];
  @override
  FocusedFillApplication get application => driver.application;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async {
    _received.addAll(units);
    return const FocusedFillBatchResult(FocusedFillState.sent);
  }

  @override
  Future<void> close() async {
    expect(String.fromCharCodes(_received), _Fixture.password);
    _received.fillRange(0, _received.length, 0);
    driver.sends++;
  }
}

class _Fixture {
  static const password = 'Synthetic-password-only-中文';
  static const credentialBody =
      '[default]\naws_access_key_id=TEST_ACCESS_ONLY\n'
      'aws_secret_access_key=SYNTHETIC_NOT_A_REAL_SECRET\n';
  static const body = '虚构简历：文件正文允许读取，但目录中不包含原文。';
  final files = _Files();
  final input = _InputDriver();
  final repository = MemoryInformationRepository();
  late Directory root;
  late InformationService service;
  late AgentServer server;
  late CredentialExecutionHost host;
  late InformationItem item;
  late String session, reference;
  final references = <String>[];
  late ManagedCredential passwordCredential, fileCredential;

  static Future<_Fixture> create({bool enabled = true}) async {
    final f = _Fixture();
    f.root = await Directory.systemTemp.createTemp('info-codex-files-');
    final executable = File(Platform.resolvedExecutable);
    final stat = await executable.stat();
    final identity = ExecutableIdentity(
      executable.path,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
      'sha256:${sha256.convert(await executable.readAsBytes())}',
    );
    f.service = InformationService(
      repository: f.repository,
      informationDeliveryFiles: f.files,
      focusedFillDriver: f.input,
      focusedFillApplicationInspector: (a) async => a,
      credentialExecutableInspector: (path, receiver) async => identity,
    );
    f.server = await AgentServer.start(
      f.service.agent,
      port: 0,
      enableReusableCredentialUse: true,
      enableInformationFiles: enabled,
      enableFocusedFill: true,
      credentialExecutionHandler: (s, i) => f.host.execute(s, i),
    );
    final bundle = Platform.environment['INFO_TEST_BUNDLE'];
    f.host = CredentialExecutionHost(
      port: f.server.port,
      workerExecutable: bundle == null
          ? null
          : '$bundle/info-runtime-worker.exe',
    );
    addTearDown(f.close);
    f.item = await f.saveFile(body);
    f.passwordCredential = await f.service.owner.createStringCredential(
      name: 'Synthetic password',
      publicPurpose: 'Controlled input',
      secret: password,
    );
    f.fileCredential = await f.service.owner.createFileCredential(
      name: 'Synthetic service credentials',
      publicPurpose: 'Controlled receiver',
      fileName: 'credentials.ini',
      bytes: utf8.encode(credentialBody),
    );
    for (final credential in [f.passwordCredential, f.fileCredential]) {
      await f.service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: '',
        discoverable: true,
      );
    }
    f.session = f.service.agent.openSession('Synthetic integration chat');
    f.reference = await CodexAssociation(
      'file-root',
      f.server.port,
      f.session,
    ).save(f.root);
    f.references.add(f.reference);
    return f;
  }

  Future<InformationItem> saveFile(
    String text, [
    InformationItem? before,
  ]) async {
    final source = File('${root.path}/private-original-resume.txt');
    await source.writeAsString(text);
    final draft = await service.owner.beginInformationFileDraft();
    try {
      final stage = await service.owner.stageInformationFile(
        draft,
        source.path,
        mediaType: 'text/plain',
      );
      return await service.owner.commitInformationDraft(
        draft,
        'owner-save-${before?.version ?? 0}',
        InformationDraftInput(
          name: '求职资料',
          description: '姓名与简历',
          itemId: before?.id,
          baseVersion: before?.version,
          fields: [
            InformationDraftField.text(
              '姓名',
              '',
              '虚构姓名',
              fieldId: before?.fields[0].id,
            ),
            InformationDraftField.text(
              '私人备注',
              '',
              '未授权备注',
              fieldId: before?.fields[1].id,
            ),
            InformationDraftField.stagedFile(
              '简历',
              '',
              stage.id,
              fieldId: before?.fields[2].id,
            ),
          ],
        ),
      );
    } finally {
      await service.owner.releaseInformationFileDraft(draft);
    }
  }

  Future<Map<String, dynamic>> call(
    Map<String, dynamic> input, {
    String? association,
    String chat = 'file-root',
  }) async {
    final bundle = Platform.environment['INFO_TEST_BUNDLE'];
    final process = await Process.start(
      bundle == null ? Platform.resolvedExecutable : '$bundle/info-codex.exe',
      [
        if (bundle == null) ...['run', 'bin/codex_info.dart'],
      ],
      environment: {'CODEX_THREAD_ID': chat},
    );
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    var exited = false;
    try {
      process.stdin.writeln(
        jsonEncode({'association': association ?? reference, ...input}),
      );
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
      exited = true;
      final raw = await out, errors = await err;
      expectPrivateAbsent('$raw$errors', [
        session,
        ...references,
        password,
        credentialBody,
        'TEST_ACCESS_ONLY',
        'SYNTHETIC_NOT_A_REAL_SECRET',
      ]);
      expect(errors, isEmpty);
      final result = jsonDecode(raw) as Map<String, dynamic>;
      if (result['privateAssociation'] case final String child) {
        references.add(
          child,
        ); // Only delegate may return a new private reference.
      }
      return result;
    } finally {
      if (!exited) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
    }
  }

  Future<String> requestFiles({bool approve = true}) async {
    final requested = await call({
      'command': 'request',
      'purpose': '填写虚构简历',
      'fields': [
        for (final f in item.fields) {'itemId': item.id, 'fieldId': f.id},
      ],
    });
    expect(requested['status'], 'pending');
    final id = requested['requestId'] as String;
    if (approve) {
      service.owner.approve(id, [
        FieldRef(item.id, item.fields[0].id),
        FieldRef(item.id, item.fields[2].id),
      ]);
      await service.owner.retryAuditStorage();
    }
    return id;
  }

  Map<String, dynamic> fetch(String request, String op, {int field = 2}) => {
    'command': 'file-fetch',
    'requestId': request,
    'operationId': op,
    'itemId': item.id,
    'fieldId': item.fields[field].id,
  };
  Map<String, dynamic> read(String request, int field) => {
    'command': 'read',
    'requestId': request,
    'itemId': item.id,
    'fieldId': item.fields[field].id,
  };
  Future<void> close() async {
    await File('${root.path}/release-receiver').writeAsString('stop');
    await host.drain();
    host.close();
    await server.close();
    await service.close();
    for (final lease in files.leases) {
      expect(await File(lease.filePath).exists(), false);
    }
    await root.delete(recursive: true);
  }
}

Map<String, dynamic> delivery(Map<String, dynamic> result) {
  expect(result['status'], 'ok', reason: '$result');
  return Map<String, dynamic>.from(result['delivery'] as Map);
}

void main() {
  test(
    'file capability rejection creates neither a copy nor a grant',
    () async {
      final f = await _Fixture.create(enabled: false);
      final result = await f.call(f.fetch('not-approved', 'not-supported'));
      expect(result['errorCode'], 'unsupported_capability');
      expect(f.files.leases, isEmpty);
      expect(f.service.owner.requests, isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test(
    'independent adapters deliver only approved files, pin retries, share only delegated authority and release after revocation',
    () async {
      final f = await _Fixture.create();
      final catalog = await f.call({'command': 'catalog'});
      expectPrivateAbsent(jsonEncode(catalog), [
        _Fixture.body,
        'private-original-resume.txt',
        f.root.path,
      ]);
      expect(jsonEncode(catalog), contains('"kind":"file"'));
      final request = await f.requestFiles();
      final claim = await f.call({'command': 'claim', 'requestId': request});
      expect(claim['fields'], hasLength(2));
      expect((await f.call(f.read(request, 0)))['value'], '虚构姓名');
      expect((await f.call(f.read(request, 1)))['status'], 'unauthorized');
      final first = delivery(await f.call(f.fetch(request, 'resume-01')));
      expect(first['fileName'], 'private-original-resume.txt');
      expect(await File(first['path'] as String).readAsString(), _Fixture.body);
      expect(jsonEncode(first), isNot(contains(_Fixture.body)));
      final status = delivery(
        await f.call({'command': 'file-status', 'operationId': 'resume-01'}),
      );
      expect(status['path'], isNull);
      expect(status['fileName'], isNull);
      expect(status['state'], 'ready');
      expect(
        (await f.call(f.fetch(request, 'resume-01', field: 0)))['errorCode'],
        'operation_conflict',
      );
      f.item = await f.saveFile('第二版虚构简历。', f.item);
      final retry = delivery(await f.call(f.fetch(request, 'resume-01')));
      expect(retry, first);
      expect(await File(retry['path'] as String).readAsString(), _Fixture.body);
      final second = delivery(await f.call(f.fetch(request, 'resume-02')));
      expect(second['attachmentVersion'], 2);
      expect(await File(second['path'] as String).readAsString(), '第二版虚构简历。');
      expect(second['deliveryId'], isNot(first['deliveryId']));
      expect(
        (await f.call({'command': 'claim', 'requestId': request}))['expiresAt'],
        claim['expiresAt'],
      );
      final delegated = await f.call({
        'command': 'delegate',
        'childChatId': 'file-child',
      });
      final childReference = delegated['privateAssociation'] as String;
      final child = delivery(
        await f.call(
          f.fetch(request, 'resume-03'),
          association: childReference,
          chat: 'file-child',
        ),
      );
      expect(child['expiresAt'], first['expiresAt']);
      expect(
        (await f.call(
          f.fetch(request, 'wrong-chat'),
          chat: 'unrelated-chat',
        ))['status'],
        'association_unavailable',
      );
      final otherSession = f.service.agent.openSession(
        'Other independent chat',
      );
      final otherReference = await CodexAssociation(
        'other-chat',
        f.server.port,
        otherSession,
      ).save(f.root);
      f.references.add(otherReference);
      expect(
        (await f.call(
          f.fetch(request, 'other-chat'),
          association: otherReference,
          chat: 'other-chat',
        ))['errorCode'],
        'not_authorized',
      );
      expect(f.files.leases, hasLength(3));
      f.service.owner.revoke(request);
      await f.service.agent.drainInformationFileDeliveries();
      expect(
        (await f.call(f.fetch(request, 'after-revoke')))['errorCode'],
        'not_authorized',
      );
      for (final copy in [first, second, child]) {
        expect(await File(copy['path'] as String).exists(), false);
        final released = delivery(
          await f.call({
            'command': 'file-release',
            'deliveryId': copy['deliveryId'],
          }),
        );
        expect(released['state'], 'expired');
        expect(released['path'], isNull);
      }
      expect(f.service.owner.requests, hasLength(1));
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'one association separates document copies, focused fills and active credential-file materials through root end',
    () async {
      final f = await _Fixture.create();
      var bundle = Platform.environment['INFO_TEST_BUNDLE'];
      if (bundle == null) {
        bundle = f.root.path;
        final build = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'exe',
          'bin/runtime_worker.dart',
          '-o',
          '$bundle/info-runtime-worker.exe',
        ]);
        expect(build.exitCode, 0, reason: '${build.stderr}');
        f.host.close();
        f.host = CredentialExecutionHost(
          port: f.server.port,
          workerExecutable: '$bundle/info-runtime-worker.exe',
        );
      }
      final ordinary = await f.requestFiles();
      final copy = delivery(await f.call(f.fetch(ordinary, 'document-active')));
      final target = await f.call({'command': 'focus-target'});
      expect(target['targetState'], 'ready', reason: '$target');
      final fill = await f.call({
        'command': 'request-use',
        'purpose': 'Synthetic portal',
        'credentials': [
          {
            'alias': 'password',
            'credentialId': f.passwordCredential.id,
            'version': 1,
          },
        ],
        'fill': {
          'application': target['application'],
          'targetHint': 'Synthetic portal',
        },
      });
      expect(fill['status'], 'pending', reason: '$fill');
      final fillId = fill['requestId'] as String;
      await f.service.owner.decideCredentialUse(
        fillId,
        approveCredential: true,
      );
      Map<String, dynamic> fillUse(String id) => {
        'command': 'fill-use',
        'requestId': fillId,
        'operationId': id,
      };
      expect((await f.call(fillUse('fill-once')))['status'], 'accepted');
      await f.service.drainFocusedFills();
      expect(f.input.sends, 1);
      final launch = {
        'receiver': 'aws_shared_credentials',
        'executable': Platform.resolvedExecutable,
        'argv': ['sts', 'get-caller-identity', '--region', 'us-east-1'],
        'cwd': f.root.path,
        'env': {
          'AWS_SHARED_CREDENTIALS_FILE': {'file': 'token'},
        },
      };
      await File('${f.root.path}/sts').writeAsString('''
import 'dart:async'; import 'dart:convert'; import 'dart:io';
Future<void> main() async {
  final material = Platform.environment['AWS_SHARED_CREDENTIALS_FILE']!;
  final contents = File(material).readAsStringSync();
  stdout.write(contents); await stdout.flush();
  File('receiver.json').writeAsStringSync(jsonEncode({'path': material, 'matches': contents == ${jsonEncode(_Fixture.credentialBody)}}));
  final end = DateTime.now().add(const Duration(seconds: 30));
  while (!File('release-receiver').existsSync() && DateTime.now().isBefore(end)) { await Future<void>.delayed(const Duration(milliseconds: 30)); }
}
''');
      final command = await f.call({
        'command': 'request-use',
        'purpose': 'Synthetic credentials receiver',
        'credentials': [
          {'alias': 'token', 'credentialId': f.fileCredential.id, 'version': 1},
        ],
        'launch': launch,
      });
      expect(command['status'], 'pending', reason: '$command');
      final commandId = command['requestId'] as String;
      await f.service.owner.decideCredentialUse(
        commandId,
        approveCredential: true,
      );
      final started = await f.call({
        'command': 'run-use',
        'requestId': commandId,
        'operationId': 'credential-file-01',
        'launch': launch,
      });
      expect(started['status'], 'accepted');
      final marker = File('${f.root.path}/receiver.json');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await marker.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Synthetic receiver did not start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      final received = jsonDecode(await marker.readAsString()) as Map;
      expect(received['matches'], true);
      final credentialFile = File(received['path'] as String);
      expect(await credentialFile.exists(), true);
      var outputText = '';
      while (!outputText.contains('[REDACTED]')) {
        final output = await f.call({
          'command': 'execution-output',
          'executionId': started['executionId'],
        });
        expect(output['status'], 'ok', reason: '$output');
        outputText = utf8.decode(
          (output['chunks'] as List)
              .expand<int>((c) => base64Decode(c['dataBase64'] as String))
              .toList(),
        );
        if (DateTime.now().isAfter(deadline)) {
          fail('Controlled credential output did not arrive');
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(outputText, isNot(contains('TEST_ACCESS_ONLY')));
      expect(outputText, isNot(contains('SYNTHETIC_NOT_A_REAL_SECRET')));
      // Releasing the document cannot delete an active process's credential file.
      expect(
        delivery(
          await f.call({
            'command': 'file-release',
            'deliveryId': copy['deliveryId'],
          }),
        )['state'],
        'released',
      );
      expect(await File(copy['path'] as String).exists(), false);
      expect(await credentialFile.exists(), true);
      final remainingCopy = delivery(
        await f.call(f.fetch(ordinary, 'document-after-release')),
      );
      f.service.agent.endSession(f.session);
      await f.service.agent.drainInformationFileDeliveries();
      expect(await File(remainingCopy['path'] as String).exists(), false);
      expect(
        await credentialFile.exists(),
        true,
        reason:
            'Root end stops new access but an active Windows Job still owns its material',
      );
      expect(
        (await f.call(f.fetch(ordinary, 'after-end')))['errorCode'],
        'session_ended',
      );
      expect(
        (await f.call(fillUse('after-end')))['errorCode'],
        'grant_revoked',
      );
      expect(
        (await f.call({
          'command': 'run-use',
          'requestId': commandId,
          'operationId': 'after-end',
          'launch': launch,
        }))['errorCode'],
        'session_required',
      );
      expect(f.input.sends, 1);
      await File('${f.root.path}/release-receiver').writeAsString('stop');
      await f.host.drain();
      final execution = f.service.owner.credentialExecutions.single;
      expect(execution.state, 'exited');
      expect(execution.exitCode, 0);
      // The worker may finish a little later than its target's stdout drain.
      final cleanupDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (await credentialFile.exists()) {
        if (DateTime.now().isAfter(cleanupDeadline)) {
          fail('Credential Job material did not settle');
        }
        await f.service.owner.cleanupCredentialExecution(execution.id);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(
        f.service.owner.credentialExecutions.single.cleanupState,
        'complete',
      );
      expect(
        f.service.owner.focusedFillOperations.single.state,
        FocusedFillState.sent,
      );
      expect(f.service.owner.requests.single.state, AccessRequestState.revoked);
      expect(f.service.owner.credentialUseRequests, hasLength(2));
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
