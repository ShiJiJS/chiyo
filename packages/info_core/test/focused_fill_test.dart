import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class FillAuditRepository extends MemoryInformationRepository {
  String? failPhase;
  int materialReads = 0;
  void Function()? beforeValidate;
  @override
  List<CredentialMaterial> get credentialMaterials {
    materialReads++;
    return super.credentialMaterials;
  }

  @override
  Future<void> commitFocusedFillRuntime(
    List<CredentialUseRequest> requests,
    List<FocusedFillOperation> operations, {
    void Function()? validate,
    List<CredentialExecution>? executions,
  }) async {
    final latest = operations.lastOrNull;
    if (failPhase == 'intent' &&
            latest != null &&
            latest.checkedAt == null &&
            latest.state == FocusedFillState.checking ||
        failPhase == 'checked' &&
            latest?.checkedAt != null &&
            latest?.inputReleased == false &&
            latest?.state == FocusedFillState.checking ||
        failPhase == 'released' &&
            latest?.inputReleased == true &&
            latest?.state == FocusedFillState.checking ||
        failPhase == 'terminal' &&
            latest != null &&
            latest.state != FocusedFillState.checking) {
      throw StateError('synthetic audit failure');
    }
    final hook = beforeValidate;
    beforeValidate = null;
    hook?.call();
    await super.commitFocusedFillRuntime(
      requests,
      operations,
      validate: validate,
      executions: executions,
    );
  }
}

class TestFillDriver implements FocusedFillDriver {
  int prepares = 0, closes = 0;
  Completer<void>? preparation;
  Object? prepareFailure;
  FocusedFillApplication? differentApplication;
  Future<FocusedFillBatchResult> Function(List<int>, int)? onBatch;
  final batches = <List<int>>[];
  @override
  Future<PreparedFocusedFill> prepare(
    FocusedFillApplication application,
  ) async {
    prepares++;
    await preparation?.future;
    if (prepareFailure case final failure?) throw failure;
    return _TestPreparedFill(this, differentApplication ?? application);
  }
}

class _TestPreparedFill implements PreparedFocusedFill {
  _TestPreparedFill(this.driver, this.application);
  final TestFillDriver driver;
  @override
  final FocusedFillApplication application;
  bool closed = false;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async {
    if (closed) throw StateError('closed test driver');
    driver.batches.add(List.of(units));
    return await driver.onBatch?.call(units, driver.batches.length) ??
        const FocusedFillBatchResult(FocusedFillState.sent);
  }

  @override
  Future<void> close() async {
    if (!closed) {
      closed = true;
      driver.closes++;
    }
  }
}

class FillFixture {
  FillFixture(
    this.repo,
    this.driver,
    this.service,
    this.session,
    this.credential,
  );
  final FillAuditRepository repo;
  final TestFillDriver driver;
  final InformationService service;
  final String session;
  final ManagedCredential credential;
  late CredentialUseRequest request;
  DateTime now = DateTime.utc(2026, 10, 19, 1);
  Map<String, dynamic> input() => {
    'protocolVersion': 2,
    'command': 'request-use',
    'purpose': 'Synthetic login task',
    'credentials': [
      {
        'alias': 'password',
        'credentialId': credential.id,
        'version': credential.version,
      },
    ],
    'fill': {
      'application': {
        'executable': r'C:\Apps\FixtureBrowser.exe',
        'sha256': '31' * 32,
      },
      'targetHint': 'https://portal.example.invalid/login',
    },
  };
  FocusedFillOperationInput operation([
    String id = 'fill-1',
    String? requestId,
  ]) => FocusedFillOperationInput.fromJson({
    'protocolVersion': 2,
    'command': 'fill-use',
    'requestId': requestId ?? request.id,
    'operationId': id,
  });
  Future<void> requestAndApprove({bool approve = true}) async {
    request = await service.agent.requestFocusedFill(
      session,
      FocusedFillInput.fromJson(input()),
    );
    if (approve) {
      await service.owner.decideCredentialUse(
        request.id,
        approveCredential: true,
      );
    }
  }

  Future<Map<String, Object?>> run([String id = 'fill-1']) async {
    await service.agent.startFocusedFill(session, operation(id));
    await service.drainFocusedFills();
    return service.agent.focusedFillStatus(session, operation(id));
  }
}

Future<FillFixture> fixture({
  String secret = '  Synthetic!#密碼😀with-more-than-sixteen-characters  ',
  bool request = true,
}) async {
  final repo = FillAuditRepository(), driver = TestFillDriver();
  FillFixture? clockSource;
  final service = InformationService(
    repository: repo,
    clock: () => clockSource?.now ?? DateTime.utc(2026, 10, 19, 1),
    focusedFillDriver: driver,
    focusedFillApplicationInspector: (a) async => a,
    credentialExecutableInspector: (path, _) async =>
        ExecutableIdentity(path, 10, 100, 'sha256:fixture'),
  );
  var credential = await service.owner.createStringCredential(
    name: 'Synthetic password',
    publicPurpose: 'Login',
    secret: secret,
  );
  credential = await service.owner.updateCredentialMetadata(
    credential.id,
    credential.revision,
    name: credential.name,
    publicPurpose: credential.publicPurpose,
    privateNote: '',
    suggestedBinding: 'PASSWORD',
    discoverable: true,
  );
  final session = service.agent.openSession('Synthetic fill chat');
  final f = FillFixture(repo, driver, service, session, credential);
  clockSource = f;
  repo.materialReads = 0;
  if (request) await f.requestAndApprove();
  addTearDown(service.close);
  return f;
}

Matcher code(String expected) => throwsA(
  isA<CredentialUseFailure>().having((e) => e.code, 'code', expected),
);

void main() {
  test(
    'the published focused-fill request example parses with the actual protocol field names',
    () async {
      final text = (await File(
        '../../docs/design/local-focused-fill-contract.md',
      ).readAsString()).replaceAll('\r\n', '\n');
      final example = RegExp(
        r'```json\n([\s\S]*?)\n```',
      ).firstMatch(text)!.group(1)!;
      final input = FocusedFillInput.fromJson(
        jsonDecode(example) as Map<String, dynamic>,
      );
      expect(input.fill.application.sha256.length, 64);
      expect(input.credentialId, 'portal-password');
    },
  );
  test(
    'a typed fill request has no fake command plan or ordinary field grant',
    () async {
      final f = await fixture();
      expect(f.request.isFocusedFill, isTrue);
      expect(
        f.request.specification,
        isA<CredentialFocusedFillSpecification>(),
      );
      expect(() => f.request.plan, code('scope_not_approved'));
      final stored = f.request.toStorageJson();
      expect(stored, contains('fill'));
      expect(stored, isNot(contains('plan')));
      expect(
        CredentialUseRequest.fromJson(
          jsonDecode(jsonEncode(stored)) as Map<String, dynamic>,
        ).focusedFill!.application.sha256,
        '31' * 32,
      );
      expect(f.request.toRequestInputJson(), isNot(contains('launch')));
      expect(
        FocusedFillInput.fromJson(
          jsonDecode(jsonEncode(f.request.toRequestInputJson()))
              as Map<String, dynamic>,
        ).credentialId,
        f.credential.id,
      );
      expect(
        f.service.agent.credentialUseStatus(
          f.session,
          f.request.id,
        )['decision'],
        containsPair('fieldRead', {'approved': false}),
      );
      expect(f.repo.materialReads, 0);
    },
  );
  test(
    'fill parsing rejects v1, mixed launch, fields, extra credentials and unknown application keys',
    () async {
      final f = await fixture(request: false);
      expect(
        () => FocusedFillInput.fromJson({...f.input(), 'protocolVersion': 1}),
        code('unsupported_protocol'),
      );
      expect(
        () => FocusedFillInput.fromJson({...f.input(), 'launch': {}}),
        code('unknown_field'),
      );
      expect(
        () => FocusedFillInput.fromJson({
          ...f.input(),
          'readFields': [
            {'itemId': 'x', 'fieldId': 'y'},
          ],
        }),
        code('invalid_plan'),
      );
      final raw = f.input();
      raw['credentials'] = [
        ...raw['credentials'] as List,
        ...raw['credentials'] as List,
      ];
      expect(() => FocusedFillInput.fromJson(raw), code('invalid_type'));
      final other = f.input();
      (other['fill'] as Map)['application'] = {
        'executable': r'C:\Apps\Browser.exe',
        'sha256': '31' * 32,
        'pid': 42,
      };
      expect(() => FocusedFillInput.fromJson(other), code('unknown_field'));
    },
  );
  test(
    'pending request and approval do not access secret material or native driver',
    () async {
      final f = await fixture(request: false);
      await f.requestAndApprove(approve: false);
      expect(
        await f.service.agent
            .startFocusedFill(f.session, f.operation())
            .then<Object?>((_) => null, onError: (Object e) => e),
        isA<CredentialUseFailure>().having(
          (e) => e.code,
          'code',
          'request_pending',
        ),
      );
      expect(f.repo.materialReads, 0);
      expect(f.driver.prepares, 0);
      await f.service.owner.decideCredentialUse(
        f.request.id,
        approveCredential: true,
      );
      expect(f.repo.materialReads, 0);
      expect(f.driver.prepares, 0);
    },
  );
  test(
    'one fixed grant permits two explicit operations without another approval or renewal',
    () async {
      final f = await fixture();
      final expiry =
          f.service.owner.credentialUseRequests.single.credentialExpiresAt;
      expect((await f.run('one'))['fillState'], 'sent');
      f.now = f.now.add(const Duration(minutes: 2));
      expect((await f.run('two'))['fillState'], 'sent');
      expect(f.repo.focusedFillOperations.length, 2);
      expect(f.driver.prepares, 2);
      expect(
        f.service.owner.credentialUseRequests.single.credentialExpiresAt,
        expiry,
      );
      expect(f.repo.credentialExecutions, isEmpty);
    },
  );
  test(
    'Unicode, spaces and surrogate pairs survive batching; public results contain no secret or command facts',
    () async {
      const secret = '123456789012345😀!密碼  with-trailing-spaces  ';
      final f = await fixture(secret: secret);
      final result = await f.run();
      expect(String.fromCharCodes(f.driver.batches.expand((b) => b)), secret);
      for (final batch in f.driver.batches) {
        expect(batch.length, lessThanOrEqualTo(16));
        expect(batch.last >= 0xd800 && batch.last <= 0xdbff, isFalse);
      }
      final text = jsonEncode(result);
      expect(text, isNot(contains(secret)));
      for (final key in [
        'exitCode',
        'cleanupState',
        'command',
        'value',
        'characterCount',
      ]) {
        expect(result, isNot(contains(key)));
      }
      expect(f.driver.closes, 1);
    },
  );
  test(
    'duplicate concurrent start and later duplicate query never prepare another native input',
    () async {
      final f = await fixture();
      f.driver.preparation = Completer<void>();
      final results = await Future.wait([
        f.service.agent.startFocusedFill(f.session, f.operation()),
        f.service.agent.startFocusedFill(f.session, f.operation()),
      ]);
      expect(results.map((r) => r['fillId']).toSet().length, 1);
      expect(results.map((r) => r['duplicate']), containsAll([false, true]));
      f.driver.preparation!.complete();
      await f.service.drainFocusedFills();
      await f.service.owner.revokeCredentialUse(f.request.id);
      final replay = await f.service.agent.startFocusedFill(
        f.session,
        f.operation(),
      );
      expect(replay['fillState'], 'sent');
      expect(replay['duplicate'], isTrue);
      expect(f.driver.prepares, 1);
      await expectLater(
        f.service.agent.startFocusedFill(f.session, f.operation('another')),
        code('grant_revoked'),
      );
    },
  );
  test(
    'another session cannot query, use or infer the original operation',
    () async {
      final f = await fixture();
      await f.run();
      final other = f.service.agent.openSession('Other chat');
      expect(
        () => f.service.agent.focusedFillStatus(other, f.operation()),
        code('session_mismatch'),
      );
      await expectLater(
        f.service.agent.startFocusedFill(other, f.operation()),
        code('session_mismatch'),
      );
      expect(f.driver.prepares, 1);
    },
  );
  test(
    'native preparation mismatch is refused before any secret read',
    () async {
      final f = await fixture();
      f.driver.differentApplication = FocusedFillApplication.fromJson({
        'executable': r'C:\Apps\Other.exe',
        'sha256': '32' * 32,
      });
      final result = await f.run();
      expect(result['fillState'], 'refused');
      expect(result['errorCode'], 'application_changed');
      expect(f.repo.materialReads, 0);
      expect(f.driver.batches, isEmpty);
    },
  );
  for (final phase in ['intent', 'checked', 'released']) {
    test('$phase audit failure never releases unaudited input', () async {
      final f = await fixture();
      f.repo.failPhase = phase;
      if (phase == 'intent') {
        await expectLater(
          f.service.agent.startFocusedFill(f.session, f.operation()),
          code('audit_unavailable'),
        );
        expect(f.repo.focusedFillOperations, isEmpty);
        expect(f.driver.prepares, 0);
      } else {
        final result = await f.run();
        expect(result['fillState'], 'refused');
        expect(result['errorCode'], 'audit_unavailable');
      }
      expect(f.driver.batches, isEmpty);
      if (phase != 'released') expect(f.repo.materialReads, 0);
    });
  }
  test(
    'a native response loss is unknown and blocks another ID until owner acknowledgement',
    () async {
      final f = await fixture();
      f.driver.onBatch = (_, _) async =>
          throw const CredentialUseFailure('service_unavailable');
      final result = await f.run();
      expect(result['fillState'], 'unknown');
      await expectLater(
        f.service.agent.startFocusedFill(f.session, f.operation('new')),
        code('fill_needs_attention'),
      );
      expect(
        (await f.service.agent.startFocusedFill(
          f.session,
          f.operation(),
        ))['fillState'],
        'unknown',
      );
      expect(f.driver.prepares, 1);
      await f.service.owner.acknowledgeFocusedFillAttention(
        result['fillId']! as String,
      );
      f.driver.onBatch = null;
      expect((await f.run('explicit-after-owner-review'))['fillState'], 'sent');
    },
  );
  test(
    'final audit failure returns unknown instead of inventing a recorded success',
    () async {
      final f = await fixture();
      f.repo.failPhase = 'terminal';
      final result = await f.run();
      expect(result['fillState'], 'unknown');
      expect(result['errorCode'], 'audit_unavailable');
      expect(
        f.repo.focusedFillOperations.single.state,
        FocusedFillState.checking,
      );
      expect(f.repo.focusedFillOperations.single.inputReleased, isTrue);
      await expectLater(
        f.service.agent.startFocusedFill(f.session, f.operation('new')),
        code('fill_needs_attention'),
      );
      f.repo.failPhase = null;
      await f.service.owner.acknowledgeFocusedFillAttention(
        result['fillId']! as String,
      );
      expect(
        f.repo.focusedFillOperations.single.state,
        FocusedFillState.unknown,
      );
      expect(
        f.repo.focusedFillOperations.single.attentionAcknowledgedAt,
        isNotNull,
      );
    },
  );
  test(
    'native confirmed refusal leaves no automatic retry and permits an explicit later operation',
    () async {
      final f = await fixture();
      f.driver.onBatch = (_, _) async => const FocusedFillBatchResult(
        FocusedFillState.refused,
        'focus_changed',
      );
      expect((await f.run())['fillState'], 'refused');
      expect(f.driver.prepares, 1);
      f.driver.onBatch = null;
      expect((await f.run('new'))['fillState'], 'sent');
    },
  );
  for (final action in ['revoke', 'end', 'expire', 'rotate']) {
    test(
      '$action during native wait stops the next batch without holding the owner lock',
      () async {
        final f = await fixture();
        final entered = Completer<void>(), release = Completer<void>();
        f.driver.onBatch = (_, n) async {
          if (n == 1) {
            entered.complete();
            await release.future;
          }
          return const FocusedFillBatchResult(FocusedFillState.sent);
        };
        await f.service.agent.startFocusedFill(f.session, f.operation());
        await entered.future;
        if (action == 'revoke') {
          await f.service.owner.revokeCredentialUse(f.request.id);
        }
        if (action == 'end') f.service.agent.endSession(f.session);
        if (action == 'expire') f.now = f.now.add(const Duration(minutes: 16));
        if (action == 'rotate') {
          await f.service.owner.rotateStringCredential(
            f.credential.id,
            f.credential.revision,
            'new synthetic password',
          );
        }
        release.complete();
        await f.service.drainFocusedFills();
        expect(
          f.service.agent.focusedFillStatus(
            f.session,
            f.operation(),
          )['fillState'],
          'partial',
        );
        expect(f.driver.batches.length, 1);
        expect(f.driver.closes, 1);
      },
    );
  }
  test(
    'control characters are refused without any native batch or automatic submit',
    () async {
      final f = await fixture(secret: 'synthetic\npassword');
      final result = await f.run();
      expect(result['fillState'], 'refused');
      expect(result['errorCode'], 'unsupported_secret');
      expect(f.driver.batches, isEmpty);
    },
  );
  test('denied and expired requests do not touch the native driver', () async {
    final f = await fixture(request: false);
    await f.requestAndApprove(approve: false);
    await f.service.owner.decideCredentialUse(
      f.request.id,
      approveCredential: false,
    );
    await expectLater(
      f.service.agent.startFocusedFill(f.session, f.operation()),
      code('request_denied'),
    );
    expect(f.driver.prepares, 0);
  });
  test(
    'same operation ID on a second fill request conflicts without a second native input',
    () async {
      final f = await fixture();
      await f.run();
      final second = await f.service.agent.requestFocusedFill(
        f.session,
        FocusedFillInput.fromJson(f.input()),
      );
      await f.service.owner.decideCredentialUse(
        second.id,
        approveCredential: true,
      );
      await expectLater(
        f.service.agent.startFocusedFill(
          f.session,
          f.operation('fill-1', second.id),
        ),
        code('operation_conflict'),
      );
      expect(f.driver.prepares, 1);
    },
  );
  test(
    'only known typed storage states and result facts are accepted',
    () async {
      final f = await fixture();
      await f.run();
      final stored = f.repo.focusedFillOperations.single.toStorageJson();
      expect(
        FocusedFillOperation.fromStorageJson(
          jsonDecode(jsonEncode(stored)) as Map<String, dynamic>,
        ).state,
        FocusedFillState.sent,
      );
      expect(
        () => FocusedFillOperation.fromStorageJson({
          ...stored,
          'fillState': 'logged_in',
        }),
        code('invalid_plan'),
      );
      expect(
        () => FocusedFillOperation.fromStorageJson({...stored, 'exitCode': 0}),
        code('unknown_field'),
      );
      expect(
        () => CredentialUseRequest.fromJson({
          ...f.request.toStorageJson(),
          'useKind': 'unknown',
        }),
        code('unsupported_receiver'),
      );
    },
  );
}
