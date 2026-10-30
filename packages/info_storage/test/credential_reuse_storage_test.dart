import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'package:crypto/crypto.dart';
import 'backup_setup.dart';
import 'storage_test.dart' show TestKeyStore;

class _Clock {
  DateTime now = DateTime.utc(2026, 10, 19);
}

class _Fixture {
  _Fixture(
    this.root,
    this.keys,
    this.repo,
    this.service,
    this.clock,
    this.session,
    this.request,
  );
  final Directory root;
  final TestKeyStore keys;
  EncryptedInformationRepository repo;
  InformationService service;
  final _Clock clock;
  final String session;
  final CredentialUseRequest request;
  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'credential-reuse-storage-',
    );
    final keys = TestKeyStore(), clock = _Clock();
    final repo = await EncryptedInformationRepository.open(
      '${root.path}/source',
      keys,
      clock: () => clock.now,
    );
    final service = InformationService(
      repository: repo,
      clock: () => clock.now,
      credentialExecutableInspector: (p, r) async =>
          ExecutableIdentity(p, 10, 100, 'sha256:${'a' * 64}'),
    );
    var c = await service.owner.createStringCredential(
      name: 'Synthetic storage token',
      publicPurpose: '',
      secret: 'SYNTHETIC_STORAGE_ONLY_638291',
    );
    c = await service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: '',
      privateNote: '',
      suggestedBinding: 'GH_TOKEN',
      discoverable: true,
    );
    final session = service.agent.openSession('Synthetic reusable storage');
    final request = await service.agent.requestCredentialUse(
      session,
      CredentialUseInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Persist multiple operations',
        'credentials': [
          {'alias': 'token', 'credentialId': c.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'gh_token',
          'executable': Platform.resolvedExecutable,
          'argv': ['api', 'user'],
          'cwd': Directory.current.path,
          'env': {
            'GH_TOKEN': {'secret': 'token'},
          },
        },
      }),
    );
    await service.owner.decideCredentialUse(
      request.id,
      approveCredential: true,
    );
    return _Fixture(root, keys, repo, service, clock, session, request);
  }

  CredentialOperationInput input(
    String id, {
    List<String> argv = const ['api', 'user'],
  }) => CredentialOperationInput.fromJson({
    'protocolVersion': 2,
    'command': 'run-use',
    'requestId': request.id,
    'operationId': id,
    'launch': <String, dynamic>{
      ...request.toRequestInputJson()['launch'] as Map,
      'argv': argv,
    },
  });
  Future<CredentialOperationClaim> add(
    String id, {
    List<String> argv = const ['api', 'user'],
  }) =>
      service.agent.beginCredentialUseOperation(session, input(id, argv: argv));
  Future<void> finish(CredentialOperationClaim claim) async {
    await service.agent.reportCredentialExecution(
      CredentialExecutionReport(
        executionId: claim.execution.id,
        executionCapability: claim.material!.executionCapability,
        state: 'start_failed',
        errorCode: 'process_start_failed',
        finishedAt: clock.now,
      ),
    );
  }

  Future<(String, String)> backup() async {
    final key = await enableTestBackups(repo.backups),
        path = '${root.path}/snapshot.aimbackup';
    await service.owner.exportLibrary(() => repo.backups.exportTo(path));
    return (path, key);
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
    final actual = await root.resolveSymbolicLinks(),
        temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
        !actual.toLowerCase().startsWith(
          '${temp.toLowerCase()}${Platform.pathSeparator}',
        )) {
      throw StateError('Unexpected fixture root');
    }
    await root.delete(recursive: true);
  }
}

sqlite.Database _openBackup(String path, String recovery) {
  final db = sqlite.sqlite3.open(path);
  final hex = base64Url
      .decode(recovery.substring('aim-recovery-v1:'.length))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  db.execute('PRAGMA key = "x\'$hex\'"');
  return db;
}

Map<String, dynamic> _payload(String path, String key) {
  final db = _openBackup(path, key);
  try {
    return jsonDecode(
          db.select('SELECT payload FROM backup_snapshot').single['payload']
              as String,
        )
        as Map<String, dynamic>;
  } finally {
    db.close();
  }
}

void main() {
  test('invalid reusable runtime snapshots are refused atomically', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    await f.add('a');
    await f.add('b');
    final before = jsonEncode(
      f.repo.credentialExecutions.map((e) => e.toStorageJson()).toList(),
    );
    for (final defect in [
      'duplicate',
      'fingerprint',
      'plan',
      'receiver',
      'consumed',
    ]) {
      final executions = List<CredentialExecution>.of(
        f.repo.credentialExecutions,
      );
      final r = f.repo.credentialUseRequests.single;
      switch (defect) {
        case 'duplicate':
          executions[1] = executions[1].changed({'operationId': 'a'});
        case 'fingerprint':
          executions[1] = executions[1].changed({
            'operationFingerprint': 'invalid',
          });
        case 'plan':
          executions[1] = executions[1].changed({'operationPlan': null});
        case 'receiver':
          executions[1] = executions[1].changed({
            'operationPlan': {
              ...executions[1].operationPlan!.toJson(),
              'receiver': 'aws_shared_credentials',
            },
          });
      }
      await expectLater(
        f.repo.commitCredentialRuntime([
          defect == 'consumed' ? r.changed({'attemptConsumed': true}) : r,
        ], executions),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'invalid_runtime_snapshot',
          ),
        ),
        reason: defect,
      );
      expect(
        jsonEncode(
          f.repo.credentialExecutions.map((e) => e.toStorageJson()).toList(),
        ),
        before,
      );
    }
  });

  test(
    'malformed persisted v2 facts cannot be opened or silently normalized',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final claim = await f.add('preserve');
      final bad = claim.execution.toStorageJson()..remove('operationPlan');
      await f.service.close();
      await f.repo.close();
      final hex = f.keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      sqlite.Database open() {
        final db = sqlite.sqlite3.open('${f.root.path}/source/library.db');
        db.execute('PRAGMA key = "x\'$hex\'"');
        return db;
      }

      var db = open();
      try {
        db.execute('UPDATE credential_operations SET payload=? WHERE id=?', [
          jsonEncode(bad),
          claim.execution.id,
        ]);
      } finally {
        db.close();
      }
      await expectLater(
        EncryptedInformationRepository.open(
          '${f.root.path}/source',
          f.keys,
        ).then((opened) {
          addTearDown(opened.close);
          return opened;
        }),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'invalid_runtime_snapshot',
          ),
        ),
      );
      db = open();
      try {
        expect(
          jsonDecode(
            db
                    .select('SELECT payload FROM credential_operations')
                    .single['payload']
                as String,
          ),
          bad,
        );
      } finally {
        db.close();
      }
    },
  );

  final legacyProbe = Platform.environment['ISSUE33_LEGACY_PROBE'];
  Future<Map<String, dynamic>> probe(List<String> args) async {
    final interpreted = legacyProbe!.endsWith('.dart');
    final result = await Process.run(
      interpreted ? Platform.resolvedExecutable : legacyProbe,
      [
        if (interpreted) ...['run', legacyProbe],
        ...args,
      ],
      workingDirectory: File(legacyProbe).parent.path,
    );
    expect(result.exitCode, 0, reason: 'Legacy compatibility helper failed');
    return jsonDecode((result.stdout as String).trim().split('\n').last)
        as Map<String, dynamic>;
  }

  test(
    'real schema16 library upgrades without granting v2 and old reader cannot load the new runtime tables',
    () async {
      final root = await Directory.systemTemp.createTemp('legacy16-migration-');
      addTearDown(() async {
        final actual = await root.resolveSymbolicLinks(),
            temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '${temp.toLowerCase()}${Platform.pathSeparator}',
            ))
          throw StateError('Unexpected fixture root');
        await root.delete(recursive: true);
      });
      final created = await probe(['create', '${root.path}/legacy']);
      expect(created, {'status': 'created', 'schema': 16, 'backupVersion': 5});
      final keys = TestKeyStore()..key = List<int>.filled(32, 61);
      final repo = await EncryptedInformationRepository.open(
        '${root.path}/legacy',
        keys,
      );
      final service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
      });
      expect(repo.credentialUseRequests, hasLength(2));
      expect(
        repo.credentialUseRequests.every((r) => r.protocolVersion == 1),
        isTrue,
      );
      expect(
        repo.credentialUseRequests.where((r) => r.attemptConsumed),
        hasLength(1),
      );
      expect(
        repo.credentialUseRequests
            .singleWhere((r) => !r.attemptConsumed)
            .invalidatedCode,
        'grant_revoked',
      );
      expect(repo.credentialExecutions.single.protocolVersion, 1);
      final facts = jsonEncode({
        'requests': repo.credentialUseRequests.map((r) => r.toJson()).toList(),
        'executions': repo.credentialExecutions
            .map((e) => e.toArchiveJson())
            .toList(),
      });
      final target = await EncryptedInformationRepository.open(
        '${root.path}/from-format5',
        TestKeyStore(),
      );
      addTearDown(target.close);
      final recovery = (await File(
        '${root.path}/legacy-recovery.txt',
      ).readAsString()).trim();
      final preview = await target.backups.restoreFrom(
        '${root.path}/legacy5.aimbackup',
        recovery,
      );
      expect(preview.formatVersion, 5);
      expect(target.managedCredentials, hasLength(1));
      expect(
        utf8.decode(target.credentialMaterials.single.bytes),
        'LEGACY_SECRET_ONLY',
      );
      expect(target.credentialUseRequests, hasLength(2));
      expect(target.items.single.name, 'Legacy fixture');
      await service.close();
      await repo.close();
      final old = await probe(['inspect', '${root.path}/legacy']);
      expect(old, {'status': 'rejected', 'errorCode': 'library_unavailable'});
      // Legacy Drift can rewrite only user_version before the missing-table
      // failure. The independent marker and all owner facts must survive.
      final reopened = await EncryptedInformationRepository.open(
        '${root.path}/legacy',
        keys,
      );
      addTearDown(reopened.close);
      expect(
        jsonEncode({
          'requests': reopened.credentialUseRequests
              .map((r) => r.toJson())
              .toList(),
          'executions': reopened.credentialExecutions
              .map((e) => e.toArchiveJson())
              .toList(),
        }),
        facts,
      );
      expect(reopened.items.single.fields.single.value, 'LEGACY_VALUE_ONLY');
      expect(
        utf8.decode(reopened.credentialMaterials.single.bytes),
        'LEGACY_SECRET_ONLY',
      );
    },
    skip: legacyProbe == null,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  for (final future in ['header', 'marker', 'missing-marker']) {
    test(
      'future $future is rejected before version changes or runtime writes',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        await f.add('preserve');
        await f.service.close();
        await f.repo.close();
        final hex = f.keys.key!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        sqlite.Database open() {
          final db = sqlite.sqlite3.open('${f.root.path}/source/library.db');
          db.execute('PRAGMA key = "x\'$hex\'"');
          return db;
        }

        var db = open();
        try {
          if (future == 'marker') {
            db.execute('UPDATE library_format SET version=999');
            db.execute('PRAGMA user_version=16');
          } else if (future == 'missing-marker') {
            db.execute('DROP TABLE library_format');
            db.execute('PRAGMA user_version=16');
          } else {
            db.execute('PRAGMA user_version=999');
          }
        } finally {
          db.close();
        }
        await expectLater(
          EncryptedInformationRepository.open('${f.root.path}/source', f.keys),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'unsupported_schema',
            ),
          ),
        );
        db = open();
        try {
          expect(
            db.select('PRAGMA user_version').single.values.single,
            future == 'header' ? 999 : 16,
          );
          expect(
            db
                .select('SELECT count(*) FROM credential_operations')
                .single
                .values
                .single,
            1,
          );
        } finally {
          db.close();
        }
      },
    );
  }

  for (final olderHeader in [10, 16]) {
    test(
      'known completed format repairs header $olderHeader without replaying old migrations',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final claim = await f.add('record');
        await f.service.close();
        await f.repo.close();
        final hex = f.keys.key!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        final db = sqlite.sqlite3.open('${f.root.path}/source/library.db');
        try {
          db.execute('PRAGMA key = "x\'$hex\'"');
          db.execute('PRAGMA user_version=$olderHeader');
        } finally {
          db.close();
        }
        f.repo = await EncryptedInformationRepository.open(
          '${f.root.path}/source',
          f.keys,
        );
        f.service = InformationService(repository: f.repo);
        expect(f.repo.credentialExecutions.single.id, claim.execution.id);
        expect(
          f.repo.credentialExecutions.single.operationPlan!.planHash,
          claim.execution.operationPlan!.planHash,
        );
        expect(f.repo.credentialExecutions.single.state, 'unknown');
        expect(f.repo.credentialUseRequests.single.protocolVersion, 2);
        expect(
          f.service.owner.credentialGrantState(
            f.repo.credentialUseRequests.single,
          ),
          'revoked',
        );
        expect(
          utf8.decode(f.repo.credentialMaterials.single.bytes),
          'SYNTHETIC_STORAGE_ONLY_638291',
        );
      },
    );
  }

  test(
    'real format5 reader refuses format6 before restoring any records',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.add('first');
      await f.add('second', argv: ['repo', 'list']);
      final (path, key) = await f.backup();
      final saved = '${f.root.path}/compat-key.txt';
      await f.repo.backups.saveRecoveryKeyTo(saved);
      final before = sha256.convert(await File(path).readAsBytes());
      final old = await probe([
        'inspect-backup',
        '${f.root.path}/legacy-reader',
        path,
        saved,
      ]);
      expect(old, {'status': 'rejected', 'errorCode': 'unsupported_backup'});
      expect(sha256.convert(await File(path).readAsBytes()), before);
      expect(
        (await f.repo.backups.inspect(path, key)).credentialExecutionCount,
        2,
      );
    },
    skip: legacyProbe == null,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'schema17 table migration rolls back completely when a target name conflicts',
    () async {
      final root = await Directory.systemTemp.createTemp('legacy16-rollback-');
      addTearDown(() async {
        final actual = await root.resolveSymbolicLinks(),
            temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '${temp.toLowerCase()}${Platform.pathSeparator}',
            ))
          throw StateError('Unexpected fixture root');
        await root.delete(recursive: true);
      });
      expect(
        (await probe(['create', '${root.path}/source']))['status'],
        'created',
      );
      sqlite.Database open() {
        final db = sqlite.sqlite3.open('${root.path}/source/library.db');
        db.execute('PRAGMA key = "x\'${'3d' * 32}\'"');
        return db;
      }

      var db = open();
      late String before;
      try {
        before = jsonEncode(
          db
              .select(
                'SELECT payload FROM credential_use_requests ORDER BY rowid',
              )
              .map((r) => r['payload'])
              .toList(),
        );
        db.execute('CREATE VIEW credential_operations AS SELECT 1 AS reserved');
      } finally {
        db.close();
      }
      final keys = TestKeyStore()..key = List<int>.filled(32, 61);
      await expectLater(
        EncryptedInformationRepository.open('${root.path}/source', keys).then((
          repo,
        ) {
          addTearDown(repo.close);
          return repo;
        }),
        throwsA(isA<StorageFailure>()),
      );
      db = open();
      try {
        final tables = db
            .select("SELECT name FROM sqlite_master WHERE type='table'")
            .map((r) => r['name'])
            .toSet();
        expect(
          tables,
          containsAll(['credential_use_requests', 'credential_executions']),
        );
        expect(tables, isNot(contains('credential_runtime_requests')));
        expect(tables, isNot(contains('library_format')));
        expect(db.select('PRAGMA user_version').single.values.single, 16);
        expect(
          jsonEncode(
            db
                .select(
                  'SELECT payload FROM credential_use_requests ORDER BY rowid',
                )
                .map((r) => r['payload'])
                .toList(),
          ),
          before,
        );
      } finally {
        db.close();
      }
    },
    skip: legacyProbe == null,
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'schema26 reopen keeps all frozen operations but no usable session or worker capability',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final first = await f.add('first');
      await f.finish(first);
      final second = await f.add(
        'second',
        argv: ['repo', 'view', 'northstar/agent-skills'],
      );
      final hashes = f.repo.credentialExecutions
          .map((e) => e.operationPlan!.planHash)
          .toList();
      await f.service.close();
      await f.repo.close();
      final db = sqlite.sqlite3.open('${f.root.path}/source/library.db');
      try {
        final hex = f.keys.key!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        db.execute('PRAGMA key = "x\'$hex\'"');
        expect(db.select('PRAGMA user_version').single.values.single, 36);
      } finally {
        db.close();
      }
      f.repo = await EncryptedInformationRepository.open(
        '${f.root.path}/source',
        f.keys,
      );
      f.service = InformationService(repository: f.repo);
      expect(f.repo.credentialExecutions.map((e) => e.operationId), [
        'first',
        'second',
      ]);
      expect(
        f.repo.credentialExecutions.map((e) => e.operationPlan!.planHash),
        hashes,
      );
      expect(f.repo.credentialExecutions.map((e) => e.state), [
        'start_failed',
        'unknown',
      ]);
      expect(
        f.service.owner.credentialGrantState(
          f.repo.credentialUseRequests.single,
        ),
        'revoked',
      );
      await expectLater(
        f.service.agent.beginCredentialUseOperation(
          f.session,
          f.input('after-reopen'),
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'session_required',
          ),
        ),
      );
      await expectLater(
        f.service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: second.execution.id,
            executionCapability: second.material!.executionCapability,
            state: 'start_failed',
            finishedAt: f.clock.now,
          ),
        ),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'session_mismatch',
          ),
        ),
      );
      for (final file
          in Directory('${f.root.path}/source')
              .listSync()
              .whereType<File>()
              .where((file) => !file.path.endsWith('.lock'))) {
        expect(
          String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('SYNTHETIC_STORAGE_ONLY_638291')),
        );
      }
    },
  );

  for (final activeFirst in [true, false]) {
    test(
      'backup6 restores per-operation plans and terminal states independently (activeFirst=$activeFirst)',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final first = await f.add('first'),
            second = await f.add('second', argv: ['repo', 'list']);
        await f.finish(activeFirst ? second : first);
        final plans = {
          for (final e in f.repo.credentialExecutions)
            e.operationId: e.operationPlan!.planHash,
        };
        final fingerprints = {
          for (final e in f.repo.credentialExecutions)
            e.operationId: e.operationFingerprint,
        };
        await f.repo.commitCredentialRuntime(f.repo.credentialUseRequests, [
          for (final e in f.repo.credentialExecutions)
            e.changed({
              'pid': 99991,
              'supervisorPid': 99992,
              'supervisorCreatedAt': 'windows:private-supervisor',
              'workerPid': 99993,
              'workerCreatedAt': 'windows:private-worker',
              'jobName': 'Local\\AgentInfoRuntime-private-registration',
            }),
        ]);
        final (path, key) = await f.backup();
        final preview = await f.repo.backups.inspect(path, key);
        expect(preview.formatVersion, 7);
        expect(preview.credentialExecutionCount, 2);
        final payload = _payload(path, key);
        final rows = payload['tables']['credential_executions'] as List;
        final archived = rows
            .map((row) => jsonDecode(row['payload'] as String))
            .toList();
        for (final absent in [
          'pid',
          'workerPid',
          'workerCreatedAt',
          'supervisorPid',
          'supervisorCreatedAt',
          'jobName',
          'materialLease',
          'executionCapability',
        ]) {
          expect(
            archived.every((j) => !(j as Map).containsKey(absent)),
            isTrue,
            reason: absent,
          );
        }
        final target = await EncryptedInformationRepository.open(
          '${f.root.path}/target',
          TestKeyStore(),
          clock: () => f.clock.now,
        );
        final restored = InformationService(
          repository: target,
          clock: () => f.clock.now,
        );
        addTearDown(() async {
          await restored.close();
          await target.close();
        });
        await restored.owner.restoreLibrary(
          () => target.backups.restoreFrom(path, key),
        );
        expect({
          for (final e in target.credentialExecutions)
            e.operationId: e.operationPlan!.planHash,
        }, plans);
        expect({
          for (final e in target.credentialExecutions)
            e.operationId: e.operationFingerprint,
        }, fingerprints);
        expect(
          {for (final e in target.credentialExecutions) e.operationId: e.state},
          activeFirst
              ? {'first': 'unknown', 'second': 'start_failed'}
              : {'first': 'start_failed', 'second': 'unknown'},
        );
        expect(
          target.credentialExecutions.every(
            (e) => e.cleanupState == 'not_needed' && e.restoredAt != null,
          ),
          isTrue,
        );
        expect(
          restored.owner.credentialGrantState(
            target.credentialUseRequests.single,
          ),
          'revoked',
        );
        await expectLater(
          restored.agent.beginCredentialUseOperation(
            f.session,
            f.input('restored'),
          ),
          throwsA(isA<CredentialUseFailure>()),
        );
        expect(
          archived.map((j) => j['operationId']),
          unorderedEquals(['first', 'second']),
        );
      },
    );
  }

  test(
    'backup retention checks every operation rather than only the latest pointer',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final first = await f.add('long-preparation'),
          last = await f.add('finished-early');
      await f.finish(last);
      f.clock.now = f.clock.now.add(const Duration(days: 100));
      await f.finish(first);
      final (path, key) = await f.backup();
      final preview = await f.repo.backups.inspect(path, key);
      expect(preview.credentialUseHistoryCount, 1);
      expect(preview.credentialExecutionCount, 2);
    },
  );

  test(
    'current format rejects malformed operation identity, plan, legacy downgrade and request links',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      await f.add('a');
      await f.add('b', argv: ['repo', 'list']);
      final (path, key) = await f.backup();
      for (final defect in [
        'duplicate-operation',
        'bad-fingerprint',
        'missing-plan',
        'receiver-change',
        'alias-change',
        'plan-identity',
        'wrong-request',
        'missing-latest',
        'unknown-private',
        'protocol3',
        'downgrade5',
        'consumed-grant',
      ]) {
        final bad = '${f.root.path}/$defect.aimbackup';
        await File(path).copy(bad);
        final db = _openBackup(bad, key);
        try {
          final payload =
              jsonDecode(
                    db
                            .select('SELECT payload FROM backup_snapshot')
                            .single['payload']
                        as String,
                  )
                  as Map;
          final rows = payload['tables']['credential_executions'] as List,
              requests = payload['tables']['credential_use_requests'] as List;
          final e = jsonDecode(rows[1]['payload'] as String) as Map,
              r = jsonDecode(requests[0]['payload'] as String) as Map;
          switch (defect) {
            case 'duplicate-operation':
              e['operationId'] = 'a';
            case 'bad-fingerprint':
              e['operationFingerprint'] = 'not-a-digest';
            case 'missing-plan':
              e.remove('operationPlan');
            case 'receiver-change':
              e['operationPlan']['receiver'] = 'aws_shared_credentials';
            case 'alias-change':
              e['operationPlan']['env']['GH_TOKEN']['secret'] = 'other-alias';
            case 'plan-identity':
              e['operationPlan']['executableIdentity']['sha256'] =
                  'invalid-digest';
            case 'wrong-request':
              e['requestId'] = 'other-request';
              rows[1]['request_id'] = 'other-request';
            case 'missing-latest':
              r['executionId'] = 'no-execution';
            case 'unknown-private':
              e['executionCapability'] = 'not-a-real-capability';
            case 'protocol3':
              e['protocolVersion'] = 3;
            case 'downgrade5':
              payload['version'] = 5;
            case 'consumed-grant':
              r['attemptConsumed'] = true;
          }
          rows[1]['payload'] = jsonEncode(e);
          requests[0]['payload'] = jsonEncode(r);
          db.execute('UPDATE backup_snapshot SET payload=?', [
            jsonEncode(payload),
          ]);
        } finally {
          db.close();
        }
        await expectLater(
          f.repo.backups.inspect(bad, key),
          throwsA(
            isA<StorageFailure>().having(
              (e) => e.code,
              'code',
              'invalid_backup',
            ),
          ),
          reason: defect,
        );
      }
    },
  );
}
