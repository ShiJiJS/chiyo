import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_cli/device_credential_host.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/history_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

class _ProgramTrial {
  _ProgramTrial(this.f, {this.localProfile});
  final DeviceCredentialFixture f;
  final AgentConnectionProfile? localProfile;
  AgentConnectionProfile get profile => localProfile ?? f.profiles.first;
  late final ChiyoContext context;
  late final File contextFile, business, gate, counter;
  late final Directory state;
  late ManagedCredential password, token, key;
  late Map<String, dynamic> launch;
  Future<void> open() async {
    final connection = AgentConnection(profile);
    final opened = await connection.call('/session/lifecycle', {
      'chatLabel': 'Synthetic program CLI',
    });
    connection.close();
    context = ChiyoContext(
      chatId: 'synthetic-program-cli',
      agentName: 'Trial Agent',
      secret: opened['sessionSecret'] as String,
      port: profile.address.port,
      connection: profile,
    );
    contextFile = File('${f.root.path}/cli-chat/context.json');
    await context.saveNew(contextFile);
    state = Directory('${contextFile.parent.path}/device-files');
    gate = File('${f.root.path}/release');
    counter = File('${f.root.path}/start-count');
    business = File('${f.root.path}/program.json');
    await f.runtime.run(() async {
      Future<ManagedCredential> discover(ManagedCredential c) =>
          f.runtime.service.owner.updateCredentialMetadata(
            c.id,
            c.revision,
            name: c.name,
            publicPurpose: '',
            privateNote: '',
            suggestedBinding: 'password',
            discoverable: true,
          );
      password = await discover(
        await f.runtime.service.owner.createStringCredential(
          name: 'Synthetic DB',
          publicPurpose: '',
          secret: '  SYNTHETIC_DB_中文🔐  ',
        ),
      );
      token = await discover(
        await f.runtime.service.owner.createStringCredential(
          name: 'Synthetic Token',
          publicPurpose: '',
          secret: 'SYNTHETIC_TOKEN_VALUE',
        ),
      );
      key = await discover(
        await f.runtime.service.owner.createFileCredential(
          name: 'Synthetic binary key',
          publicPurpose: '',
          fileName: 'test.key',
          bytes: [0, 1, 255, 254, 40, 41],
        ),
      );
    });
    launch = {
      'executable': await File(
        Platform.resolvedExecutable,
      ).resolveSymbolicLinks(),
      'cwd': await Directory.current.resolveSymbolicLinks(),
      'argv': [
        File('test/support/program_batch_child.dart').absolute.path,
        counter.path,
        gate.path,
        {
          'file': {'credentialId': key.id},
        },
      ],
      'env': {
        'DB_PASSWORD': {'credentialId': password.id},
        'SERVICE_TOKEN': {'credentialId': token.id},
        'TMPDIR': 'target-only-temp',
        'TEMP': 'target-only-temp',
      },
      'stdin': {'credentialId': password.id},
    };
    await business.writeAsString(
      jsonEncode({'purpose': 'Use synthetic service', 'launch': launch}),
    );
  }

  Future<ChiyoRunResult> call(List<String> args) async {
    final binary = Platform.environment['CHIYO_TEST_EXECUTABLE'];
    if (binary == null) {
      return ChiyoCli(
        environment: {'CHIYO_CONTEXT': contextFile.path},
      ).run([...args, '--json']);
    }
    final environment = Map<String, String>.from(Platform.environment)
      ..removeWhere(
        (key, _) => key.startsWith('CHIYO_') || key.startsWith('CODEX_'),
      );
    final result = await Process.run(
      binary,
      [...args, '--json'],
      environment: {...environment, 'CHIYO_CONTEXT': contextFile.path},
      includeParentEnvironment: false,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(result.stderr, isEmpty);
    return ChiyoRunResult(
      Map<String, Object?>.from(jsonDecode(result.stdout as String) as Map),
      result.exitCode,
      json: true,
    );
  }

  Future<String> request() async {
    final result = await call([
      'exec',
      'request',
      '--input',
      business.path,
      '--operation',
      'submit-program',
    ]);
    expect(result.exitCode, 0, reason: result.render());
    final id = (result.output['data'] as Map)['requestId'] as String;
    return id;
  }

  Future<void> approve(String id, List<String> selected) async {
    final review = approvalDetailFromJson(
      await f.owner.request(
        'GET',
        '/v1/owner/approvals/details/${Uri.encodeComponent(id)}',
      ),
    );
    expect(review.credentialBatch, true);
    await f.owner.request(
      'POST',
      '/v1/owner/approvals/decisions',
      approvalChangeToJson(
        WorkspaceApprovalChange(
          operationId: 'approve-program',
          requestId: id,
          reviewToken: review.reviewToken,
          action: WorkspaceApprovalAction.approve,
          selected: selected,
        ),
      ),
    );
  }

  Future<Map> wait(String id, Set<String> states) async {
    for (var i = 0; i < 300; i++) {
      final result = await call(['operations', 'show', id]);
      final data = result.output['data'];
      if (data is Map && states.contains(data['executionState'])) return data;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('Synthetic operation did not reach $states');
  }

  Future<void> close() async {
    await gate.writeAsString('release');
    final host = DeviceCredentialHost(profile, state);
    for (var i = 0; i < 100; i++) {
      final result = await host.stopIfIdle();
      if (result['status'] == 'ok') return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('Synthetic host still active');
  }
}

String _stream(Map data, String name) => utf8.decode(
  (data['chunks'] as List)
      .where((row) => row['stream'] == name)
      .expand<int>((row) => base64Decode(row['dataBase64'] as String))
      .toList(),
);

void main() {
  test(
    'public exec delivers mixed receivers to one native process, survives caller exit, and filters every material',
    () async {
      final f = await DeviceCredentialFixture.create();
      final trial = _ProgramTrial(f);
      await trial.open();
      addTearDown(() async {
        await trial.close();
        await f.dispose();
      });
      final id = await trial.request();
      expect(await trial.counter.exists(), false);
      await trial.approve(id, ['b1', 'b2', 'b3', 'b4']);
      final run = await trial.call([
        'exec',
        'run',
        '--request',
        id,
        '--operation',
        'one-program',
      ]);
      expect(run.exitCode, 0, reason: run.render());
      await trial.wait('one-program', {'running'});
      Future<WorkspaceApprovalDetail> detail() async => approvalDetailFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/approvals/details/${Uri.encodeComponent(id)}',
        ),
      );
      final runningDetail = await detail();
      final running = runningDetail.programOperations.single;
      expect(running.state, 'running');
      expect(running.processStarted, true);
      expect((await detail()).batchOperations, isEmpty);
      expect(
        (await detail()).programPlan!.executable,
        trial.launch['executable'],
      );
      expect(
        () => approvalDetailToJson(runningDetail, version: 3),
        throwsA(isA<WorkspaceFailure>()),
      );
      for (var i = 0; i < 200; i++) {
        if (await trial.counter.exists() &&
            await trial.counter.readAsString() == 'start\n')
          break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await trial.counter.readAsLines(), ['start']);
      expect(
        (await trial.call([
          'exec',
          'run',
          '--request',
          id,
          '--operation',
          'one-program',
        ])).exitCode,
        0,
      );
      expect(
        (await trial.call(['operations', 'retry', 'one-program'])).exitCode,
        0,
      );
      expect(
        (await trial.call(['operations', 'retry', 'submit-program'])).exitCode,
        0,
      );
      expect(await trial.counter.readAsLines(), ['start']);
      await trial.gate.writeAsString('release');
      final ended = await trial.wait('one-program', {
        'exited',
        'unknown',
        'start_failed',
        'prepare_failed',
      });
      expect(ended['executionState'], 'exited', reason: '$ended');
      expect(ended['exitCode'], 0, reason: '$ended');
      expect(ended['outputAvailable'], true);
      expect(ended['outputState'], 'retained');
      final serverOnly = await f.agents.first.call('/operations/show', {
        'sessionSecret': trial.context.secret,
        'id': 'one-program',
      });
      expect(serverOnly['outputLocation'], 'execution-device');
      expect(serverOnly.containsKey('outputAvailable'), false);
      final ownerOperation = WorkspaceCredentialProgramOperation.fromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/credential-batches/${Uri.encodeComponent(id)}/operations/one-program',
        ),
      );
      expect(ownerOperation.state, 'exited');
      expect(ownerOperation.updates(running), true);
      final history = grantDetailFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/grant-history/entries/${Uri.encodeComponent('request:$id')}',
        ),
      );
      expect(history.summary.operationCount, 1);
      expect(
        history.events.any((event) => event.result.contains('退出码 0')),
        true,
      );
      expect(
        history.events.any((event) => event.description.contains('运行')),
        true,
      );
      expect(
        jsonEncode(approvalDetailToJson(await detail(), version: 4)),
        isNot(contains('SYNTHETIC_DB_')),
      );
      final output = await trial.call([
        'exec',
        'output',
        '--operation',
        'one-program',
      ]);
      expect(output.exitCode, 0, reason: output.render());
      final data = output.output['data'] as Map;
      final text = _stream(data, 'stdout');
      for (final field in [
        'passwordExact',
        'tokenExact',
        'stdinExact',
        'fileExact',
      ]) {
        expect(text, contains('"$field":true'));
      }
      expect(text, contains('target-only-temp'));
      expect(text, contains('[REDACTED]'));
      // Adjacent redacted ranges may merge; no original byte sequence survives.
      expect(_stream(data, 'stderr'), '[REDACTED]');
      expect(text, isNot(contains('SYNTHETIC_TOKEN_VALUE')));
      expect(text, isNot(contains('SYNTHETIC_DB_')));
      final operations = f.runtime.service.owner.credentialProgramOperations;
      expect(operations, hasLength(1));
      for (
        var i = 0;
        i < 100 &&
            f
                    .runtime
                    .service
                    .owner
                    .credentialProgramOperations
                    .single
                    .progress
                    .cleanupState !=
                'complete';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final finalOperation =
          f.runtime.service.owner.credentialProgramOperations.single;
      expect(finalOperation.progress.cleanupState, 'complete');
      expect(
        await Directory(finalOperation.progress.materialLease!.path).exists(),
        false,
      );
      expect(output.render(), isNot(contains(trial.context.secret)));
      // Loss of the original volatile cache is reported honestly. Querying
      // must not start another Host or repeat the successful business action.
      await trial.close();
      Map? afterStop;
      for (var i = 0; i < 100; i++) {
        afterStop =
            (await trial.call([
                  'operations',
                  'show',
                  'one-program',
                ])).output['data']
                as Map?;
        if (afterStop?['outputAvailable'] == false) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(afterStop?['outputAvailable'], false);
      expect(afterStop?['outputState'], 'not_retained');
      final hostFolder = DeviceCredentialHost(
        trial.profile,
        trial.state,
      ).directory;
      final hostRecord =
          (await hostFolder
                      .list()
                      .where(
                        (file) => file is File && file.path.endsWith('.json'),
                      )
                      .toList())
                  .single
              as File;
      final before = await hostRecord.readAsString();
      expect(
        (await trial.call(['operations', 'show', 'one-program'])).exitCode,
        0,
      );
      expect(await hostRecord.readAsString() == before, true);
      expect(await trial.counter.readAsLines(), ['start']);
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'partial approval cannot launch a complete plan, while an explicit independent approved receiver may run once',
    () async {
      final f = await DeviceCredentialFixture.create();
      final trial = _ProgramTrial(f);
      await trial.open();
      addTearDown(() async {
        await trial.close();
        await f.dispose();
      });
      final id = await trial.request();
      await trial.approve(id, ['b2']);
      final denied = await trial.call([
        'exec',
        'run',
        '--request',
        id,
        '--operation',
        'full-denied',
      ]);
      expect(denied.exitCode, 4, reason: denied.render());
      expect(await trial.counter.exists(), false);
      expect(f.runtime.service.owner.credentialProgramOperations, isEmpty);
      final subset = File('${f.root.path}/subset.json');
      final plan = <String, dynamic>{
        ...trial.launch,
        'argv': (trial.launch['argv'] as List).take(3).toList(),
        'env': {
          'DB_PASSWORD': {'credentialId': trial.password.id},
        },
      }..remove('stdin');
      await subset.writeAsString(jsonEncode({'launch': plan}));
      final run = await trial.call([
        'exec',
        'run',
        '--request',
        id,
        '--input',
        subset.path,
        '--operation',
        'subset-once',
      ]);
      expect(run.exitCode, 0, reason: run.render());
      await trial.gate.writeAsString('release');
      final ended = await trial.wait('subset-once', {
        'exited',
        'unknown',
        'start_failed',
        'prepare_failed',
      });
      expect(ended['executionState'], 'exited', reason: '$ended');
      expect(ended['exitCode'], 0, reason: '$ended');
      expect(await trial.counter.readAsLines(), ['start']);
      expect(
        f.runtime.service.owner.credentialProgramOperations.single.itemIds,
        ['b2'],
      );
      expect(
        (await trial.call(['operations', 'retry', 'subset-once'])).exitCode,
        0,
      );
      expect(await trial.counter.readAsLines(), ['start']);
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'lost private material reply and server restart never start a replacement program',
    () async {
      var now = DateTime.now().toUtc();
      final f = await DeviceCredentialFixture.create(
        loseFirstPath: '/v1/agent/credential-use/program/begin',
        clock: () => now,
      );
      final trial = _ProgramTrial(f);
      await trial.open();
      addTearDown(() async {
        await trial.close();
        await f.dispose();
      });
      final id = await trial.request();
      await trial.approve(id, ['b1', 'b2', 'b3', 'b4']);
      final run = await trial.call([
        'exec',
        'run',
        '--request',
        id,
        '--operation',
        'lost-program',
      ]);
      expect(run.exitCode, 7, reason: run.render());
      expect(await trial.counter.exists(), false);
      expect(f.runtime.service.owner.credentialProgramOperations, hasLength(1));
      now = now.add(const Duration(seconds: 31));
      await f.reopen();
      final retry = await trial.call(['operations', 'retry', 'lost-program']);
      expect(retry.exitCode, 0, reason: retry.render());
      expect((retry.output['data'] as Map)['executionState'], 'unknown');
      final repeated = await trial.call([
        'exec',
        'run',
        '--request',
        id,
        '--operation',
        'lost-program',
      ]);
      expect(repeated.exitCode, 7, reason: repeated.render());
      expect(await trial.counter.exists(), false);
      expect(f.runtime.service.owner.credentialProgramOperations, hasLength(1));
      expect(
        (await trial.call([
          'exec',
          'output',
          '--operation',
          'lost-program',
        ])).output['ok'],
        false,
      );
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'the same public exec works in local mode with its original local device and private journal',
    () async {
      final f = await DeviceCredentialFixture.create();
      final token = '${'L' * 22}.${'T' * 43}';
      final local = await AgentServer.start(
        f.runtime.service.agent,
        port: 0,
        connectionToken: token,
        libraryId: 'SyntheticLocalLibrary001',
        enableReusableCredentialUse: true,
        enableCredentialBatches: true,
      );
      final trial = _ProgramTrial(
        f,
        localProfile: AgentConnectionProfile.local(
          port: local.port,
          deviceToken: token,
          libraryId: 'SyntheticLocalLibrary001',
        ),
      );
      await trial.open();
      addTearDown(() async {
        await trial.close();
        await local.close();
        await f.dispose();
      });
      final request = await trial.request();
      await trial.approve(request, ['b1', 'b2', 'b3', 'b4']);
      final result = await trial.call([
        'exec',
        'run',
        '--request',
        request,
        '--operation',
        'local-program',
      ]);
      expect(result.exitCode, 0, reason: result.render());
      await trial.gate.writeAsString('release');
      final ended = await trial.wait('local-program', {
        'exited',
        'prepare_failed',
        'start_failed',
        'unknown',
      });
      expect(ended['executionState'], 'exited', reason: '$ended');
      expect(ended['exitCode'], 0);
      expect(await trial.counter.readAsLines(), ['start']);
      final output = await trial.call([
        'exec',
        'output',
        '--operation',
        'local-program',
      ]);
      expect(output.exitCode, 0, reason: output.render());
      expect(
        _stream(output.output['data'] as Map, 'stdout'),
        contains('"stdinExact":true'),
      );
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test(
    'portable backup keeps program history readable through ordinary owner APIs without restoring a usable grant',
    () async {
      final f = await DeviceCredentialFixture.create(
        loseFirstPath: '/v1/agent/credential-use/program/begin',
      );
      final trial = _ProgramTrial(f);
      await trial.open();
      addTearDown(() async {
        await trial.close();
        await f.dispose();
      });
      final id = await trial.request();
      await trial.approve(id, ['b1', 'b2', 'b3', 'b4']);
      expect(
        (await trial.call([
          'exec',
          'run',
          '--request',
          id,
          '--operation',
          'archive-program',
        ])).exitCode,
        7,
      );
      final recovery = await f.runtime.run(() => f.repo.backups.enable());
      final archive = '${f.root.path}/program-history.aimbackup';
      await f.runtime.run(() async {
        await f.repo.backups.saveRecoveryKeyTo('${f.root.path}/recovery.key');
        await f.runtime.service.owner.exportLibrary(
          () => f.repo.backups.exportTo(archive),
        );
      });
      final target = await DeviceCredentialFixture.create();
      addTearDown(target.dispose);
      await target.runtime.run(
        () => target.runtime.service.owner.restoreLibrary(
          () => target.repo.backups.restoreFrom(archive, recovery),
        ),
      );
      final detail = approvalDetailFromJson(
        await target.owner.request(
          'GET',
          '/v1/owner/approvals/details/${Uri.encodeComponent(id)}',
        ),
      );
      expect(detail.programOperations.single.fromBackup, true);
      expect(detail.programOperations.single.state, 'unknown');
      expect(detail.scopes.every((scope) => !scope.available), true);
      expect(detail.canApprove, false);
      final history = grantDetailFromJson(
        await target.owner.request(
          'GET',
          '/v1/owner/grant-history/entries/${Uri.encodeComponent('request:$id')}',
        ),
      );
      expect(history.summary.state, WorkspaceGrantState.unavailable);
      expect(history.summary.operationCount, 1);
      expect(history.scopeNotice, null);
      expect(
        history.events.any((event) => event.result.contains('来自备份')),
        true,
      );
      expect(
        jsonEncode(approvalDetailToJson(detail, version: 4)),
        isNot(contains('SYNTHETIC_DB_')),
      );
      expect(await trial.counter.exists(), false);
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );
}
