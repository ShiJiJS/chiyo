import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'backup_setup.dart';
import 'storage_test.dart' show TestKeyStore;

class _Driver implements FocusedFillDriver {
  FocusedFillBatchResult result = const FocusedFillBatchResult(
    FocusedFillState.sent,
  );
  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication app) async =>
      _Prepared(app, result);
}

class _Prepared implements PreparedFocusedFill {
  _Prepared(this.application, this.result);
  final FocusedFillBatchResult result;
  @override
  final FocusedFillApplication application;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async => result;
  @override
  Future<void> close() async {}
}

class _Fixture {
  _Fixture(this.root, this.keys, this.repo, this.service);
  final Directory root;
  final TestKeyStore keys;
  EncryptedInformationRepository repo;
  InformationService service;
  final driver = _Driver();
  DateTime now = DateTime.utc(2026, 10, 19);
  late final session = service.agent.openSession(
    'Synthetic fill storage session',
  );
  late ManagedCredential credential;
  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('focused-fill-storage-');
    final keys = TestKeyStore();
    final repo = await EncryptedInformationRepository.open(
      '${root.path}/source',
      keys,
      clock: () => DateTime.utc(2026, 10, 19),
    );
    final f = _Fixture(root, keys, repo, InformationService(repository: repo));
    await f.service.close();
    f.service = f.newService(repo);
    var c = await f.service.owner.createStringCredential(
      name: 'Synthetic portal password',
      publicPurpose: '',
      secret: 'SYNTHETIC_FILL_中文_🧭_349826',
      suggestedBinding: '',
    );
    c = await f.service.owner.updateCredentialMetadata(
      c.id,
      c.revision,
      name: c.name,
      publicPurpose: '',
      privateNote: '',
      suggestedBinding: '',
      discoverable: true,
    );
    f.credential = c;
    return f;
  }

  InformationService newService(EncryptedInformationRepository target) =>
      InformationService(
        repository: target,
        clock: () => now,
        focusedFillDriver: driver,
        focusedFillApplicationInspector: (a) async => a,
        credentialExecutableInspector: (p, r) async =>
            ExecutableIdentity(p, 10, 100, 'sha256:${'a' * 64}'),
      );
  Future<CredentialUseRequest> request({bool approve = true}) async {
    final r = await service.agent.requestFocusedFill(
      session,
      FocusedFillInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Synthetic fill storage',
        'credentials': [
          {'alias': 'password', 'credentialId': credential.id, 'version': 1},
        ],
        'fill': {
          'application': {
            'executable': r'C:\Synthetic\Browser.exe',
            'sha256': 'b' * 64,
          },
          'targetHint': 'Synthetic portal',
        },
      }),
    );
    if (approve)
      await service.owner.decideCredentialUse(r.id, approveCredential: true);
    return repo.credentialUseRequests.singleWhere((v) => v.id == r.id);
  }

  FocusedFillOperationInput input(String request, String operation) =>
      FocusedFillOperationInput.fromJson({
        'protocolVersion': 2,
        'command': 'fill-use',
        'requestId': request,
        'operationId': operation,
      });
  Future<FocusedFillOperation> fill(String request, String operation) async {
    await service.agent.startFocusedFill(session, input(request, operation));
    await service.drainFocusedFills();
    return repo.focusedFillOperations.last;
  }

  Future<CredentialOperationClaim> claimCommand() async {
    final r = await service.agent.requestCredentialUse(
      session,
      CredentialUseInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Synthetic command next to fill',
        'credentials': [
          {'alias': 'token', 'credentialId': credential.id, 'version': 1},
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
    await service.owner.decideCredentialUse(r.id, approveCredential: true);
    final claim = await service.agent.beginCredentialUseOperation(
      session,
      CredentialOperationInput.fromJson({
        'protocolVersion': 2,
        'command': 'run-use',
        'requestId': r.id,
        'operationId': 'command-operation',
        'launch': r.toRequestInputJson()['launch'],
      }),
    );
    return claim;
  }

  Future<CredentialExecution> command() async {
    final claim = await claimCommand();
    await service.agent.reportCredentialExecution(
      CredentialExecutionReport(
        executionId: claim.execution.id,
        executionCapability: claim.material!.executionCapability,
        state: 'start_failed',
        errorCode: 'process_start_failed',
        finishedAt: now,
      ),
    );
    return repo.credentialExecutions.single;
  }

  Future<void> intent(CredentialUseRequest r, {bool released = false}) async {
    final operation = FocusedFillOperation(
      id: 'interrupted-fill',
      requestId: r.id,
      operationId: 'interrupted',
      fingerprint: input(r.id, 'interrupted').fingerprint,
      createdAt: now,
      application: r.focusedFill!.application,
      inputReleased: released,
      checkedAt: released ? now : null,
    );
    await repo.commitFocusedFillRuntime(
      [
        for (final old in repo.credentialUseRequests)
          old.id == r.id
              ? old.changed({'attemptedAt': now.toIso8601String()})
              : old,
      ],
      [...repo.focusedFillOperations, operation],
    );
  }

  Future<(String, String)> backup(String name) async {
    final key = await enableTestBackups(repo.backups);
    final path = '${root.path}/$name.aimbackup';
    await service.owner.exportLibrary(() => repo.backups.exportTo(path));
    return (path, key);
  }

  Future<void> reopen() async {
    await service.close();
    await repo.close();
    repo = await EncryptedInformationRepository.open(
      '${root.path}/source',
      keys,
      clock: () => now,
    );
    service = newService(repo);
  }

  Future<void> close() async {
    await service.close();
    await repo.close();
    final actual = (await root.resolveSymbolicLinks()).toLowerCase();
    final temp = (await Directory.systemTemp.resolveSymbolicLinks())
        .toLowerCase();
    if (actual != root.absolute.path.toLowerCase() ||
        !actual.startsWith('$temp${Platform.pathSeparator}')) {
      throw StateError('Unexpected fixture root');
    }
    await root.delete(recursive: true);
  }
}

sqlite.Database _backupDb(String path, String recovery) {
  final db = sqlite.sqlite3.open(path);
  final key = base64Url.decode(recovery.substring('aim-recovery-v1:'.length));
  final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  db.execute('PRAGMA key = "x\'$hex\'"');
  return db;
}

Map<String, dynamic> _payload(String path, String recovery) {
  final db = _backupDb(path, recovery);
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
  test(
    'portable Mac metadata cannot silently enter the current persisted fill format',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final original = await f.request();
      final changed = original.changed({
        'fill': {
          ...original.focusedFill!.toJson(),
          'application': {
            'executable': '/Applications/中文 Browser.app/Contents/MacOS/Browser',
            'sha256': 'b' * 64,
          },
        },
      });
      await expectLater(
        f.repo.commitFocusedFillRuntime([changed], []),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'invalid_runtime_snapshot',
          ),
        ),
      );
      expect(
        f.repo.credentialUseRequests.single.focusedFill!.application.executable,
        r'C:\Synthetic\Browser.exe',
      );
      expect(f.repo.focusedFillOperations, isEmpty);
      final (backup, recovery) = await f.backup('existing-windows-fill');
      expect(
        (await f.repo.backups.inspect(
          backup,
          recovery,
        )).credentialUseHistoryCount,
        1,
      );
      final altered = _payload(backup, recovery);
      final rows = altered['tables']['credential_use_requests'] as List;
      final raw =
          jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
      (raw['fill']['application'] as Map)['executable'] =
          '/Applications/中文 Browser.app/Contents/MacOS/Browser';
      rows.single['payload'] = jsonEncode(raw);
      final incompatible = '${f.root.path}/unmarked-mac-fill.aimbackup';
      await File(backup).copy(incompatible);
      final db = _backupDb(incompatible, recovery);
      try {
        db.execute('UPDATE backup_snapshot SET payload=?', [
          jsonEncode(altered),
        ]);
      } finally {
        db.close();
      }
      await expectLater(
        f.repo.backups.inspect(incompatible, recovery),
        throwsA(isA<StorageFailure>()),
      );
      await f.reopen();
      expect(
        f.repo.credentialUseRequests.single.focusedFill!.application.executable,
        r'C:\Synthetic\Browser.exe',
      );
    },
  );

  test(
    'metadata admission reserves command and released fill outcomes at the actual64MiB boundary',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final request = await f.request();
      await f.intent(request, released: true);
      final command = await f.claimCommand();
      await f.service.owner.createTemplate('文件定义', '', [
        const TemplateFieldInput('文件', '', kind: FieldKind.file),
      ]);
      await f.repo.writeSetting('auditRetentionDays', 90);
      final large = await f.service.owner.createInformation('合法容量样本', '', [
        for (var i = 0; i < 67; i++) FieldInput('字段$i', '', 'x' * 1000000),
        const FieldInput('填充', '', ''),
      ]);
      final (path, key) = await f.backup('boundary');
      final backup = _backupDb(path, key);
      late int count;
      try {
        count =
            backup
                    .select(
                      'SELECT length(CAST(payload AS BLOB)) AS n FROM backup_snapshot',
                    )
                    .single['n']
                as int;
      } finally {
        backup.close();
      }
      final db = sqlite.sqlite3.open('${f.root.path}/source/library.db');
      final hex = f.keys.key!
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      try {
        var low = AttachmentBackupContainer.maxPayloadBytes - count - 8192;
        var high = AttachmentBackupContainer.maxPayloadBytes - count;
        expect(low, greaterThan(0));
        expect(high, lessThan(1000000));
        void setPadding(int n) => db.execute(
          'UPDATE information_fields SET value=? WHERE id=?',
          ['p' * n, large.fields.last.id],
        );
        setPadding(low);
        await f.repo.writeSetting('auditRetentionDays', 90);
        // Discover the largest admitted valid fixture through the real writer,
        // without knowing or copying the reservation implementation.
        while (low < high) {
          final middle = (low + high + 1) ~/ 2;
          setPadding(middle);
          try {
            await f.repo.writeSetting('auditRetentionDays', 90);
            low = middle;
          } on StorageFailure {
            high = middle - 1;
          }
        }
        setPadding(low);
        await f.repo.writeSetting('auditRetentionDays', 90);
        await f.service.agent.reportCredentialExecution(
          CredentialExecutionReport(
            executionId: command.execution.id,
            executionCapability: command.material!.executionCapability,
            state: 'start_failed',
            errorCode: 'material_prepare_failed',
            finishedAt: f.now,
          ),
        );
        expect(f.repo.credentialExecutions.single.state, 'start_failed');
        final current = f.repo.focusedFillOperations.single;
        final finished = current.changed({
          'fillState': 'partial',
          'finishedAt': f.now.toIso8601String(),
          'errorCode': 'credential_version_changed',
        });
        await f.repo.commitFocusedFillRuntime(f.repo.credentialUseRequests, [
          finished,
        ]);
        expect(
          f.repo.focusedFillOperations.single.state,
          FocusedFillState.partial,
        );
        expect(f.repo.focusedFillOperations.single.inputReleased, isTrue);
        final acknowledged = finished.changed({
          'attentionAcknowledgedAt': f.now.toIso8601String(),
        });
        await f.repo.commitFocusedFillRuntime(f.repo.credentialUseRequests, [
          acknowledged,
        ]);
        expect(
          f.repo.focusedFillOperations.single.attentionAcknowledgedAt,
          f.now,
        );
        await f.service.owner.revokeCredentialUse(request.id);
        await f.service.owner.revokeCredentialUse(command.execution.requestId);
        expect(
          f.repo.credentialUseRequests.every(
            (r) => r.invalidatedCode == 'grant_revoked',
          ),
          isTrue,
        );
      } finally {
        db.execute('UPDATE information_fields SET value=? WHERE item_id=?', [
          '',
          large.id,
        ]);
        db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  test(
    'format9 preserves command, fill and credential archives alongside ordinary originals without file delivery authority',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final r = await f.request();
      await f.fill(r.id, 'first');
      final command = await f.command();
      await f.fill(r.id, 'second');
      final source = File('${f.root.path}/ordinary.pdf');
      await source.writeAsBytes([0, 255, 7]);
      final draft = await f.service.owner.beginInformationFileDraft();
      final stage = await f.service.owner.stageInformationFile(
        draft,
        source.path,
      );
      final item = await f.service.owner.commitInformationDraft(
        draft,
        'file',
        InformationDraftInput(
          name: '普通附件',
          description: '',
          fields: [InformationDraftField.stagedFile('简历', '', stage.id)],
        ),
      );
      await f.service.owner.releaseInformationFileDraft(draft);
      final version = (await f.repo.informationAttachmentVersions(
        item.fields.single.attachment!.attachmentId,
      )).single;
      final preparing = InformationFileDelivery.preparing(
        id: 'archived-file',
        sessionBinding: 'past-session',
        operationId: 'past-op',
        requestId: 'past-request',
        grantId: 'past-grant',
        field: RecordedField(
          item.id,
          item.fields.single.id,
          item.name,
          item.fields.single.name,
        ),
        fieldVersion: 1,
        version: version,
        createdAt: f.now,
        expiresAt: f.now.add(const Duration(hours: 8)),
      );
      final fact = InformationFileDelivery.fromArchiveJson({
        ...preparing.toArchiveJson(),
        'state': 'ready',
      });
      await f.repo.saveInformationFileDelivery(fact);
      final materials = f.repo.credentialMaterials
          .map((m) => m.toStorageJson())
          .toList();
      final (path, key) = await f.backup('complete-format9');
      final target = await EncryptedInformationRepository.open(
        '${f.root.path}/recipient',
        TestKeyStore(),
        clock: () => f.now,
      );
      addTearDown(target.close);
      final restored = await target.backups.restoreFrom(path, key);
      expect(restored.formatVersion, 9);
      expect(restored.fileDeliveryCount, 1);
      expect(restored.focusedFillCount, 2);
      expect(restored.credentialExecutionCount, 1);
      expect(
        target.credentialMaterials.map((m) => m.toStorageJson()).toList(),
        materials,
      );
      expect(target.credentialExecutions.single.id, command.id);
      expect(
        target.credentialUseRequests.every(
          (u) => u.invalidatedCode == 'grant_revoked',
        ),
        isTrue,
      );
      expect(target.focusedFillOperations.map((o) => o.state), [
        FocusedFillState.sent,
        FocusedFillState.sent,
      ]);
      expect(target.informationFileDeliveries.single.runtime, isFalse);
      expect(target.informationFileDeliveries.single.lease, isNull);
      expect(
        await target.readInformationAttachmentChunk(
          item.fields.single.attachment!,
          0,
          3,
        ),
        [0, 255, 7],
      );
      final fresh = f.newService(target);
      addTearDown(fresh.close);
      expect(
        () => fresh.agent.validateSession(f.session),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'clock rollback preserves actual fill and audit facts through backup/reopen',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final r = await f.request();
      f.now = f.now.subtract(const Duration(hours: 1));
      final op = await f.fill(r.id, 'after-clock-rollback');
      expect(op.state, FocusedFillState.sent);
      expect(op.createdAt.isBefore(r.createdAt), true);
      final (path, key) = await f.backup('clock-rollback');
      expect((await f.repo.backups.inspect(path, key)).focusedFillCount, 1);
      await f.reopen();
      expect(f.repo.focusedFillOperations.single.state, FocusedFillState.sent);
    },
  );
  for (final state in [
    FocusedFillState.refused,
    FocusedFillState.partial,
    FocusedFillState.unknown,
  ]) {
    test(
      'terminal ${state.name} remains an input fact across owner review and backup',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final r = await f.request();
        f.driver.result = FocusedFillBatchResult(
          state,
          state == FocusedFillState.refused
              ? 'focus_changed'
              : state == FocusedFillState.partial
              ? 'input_partial'
              : 'fill_unknown',
        );
        final op = await f.fill(r.id, 'original');
        expect(op.state, state);
        if (state != FocusedFillState.refused) {
          await expectLater(
            f.service.agent.startFocusedFill(
              f.session,
              f.input(r.id, 'not-reviewed'),
            ),
            throwsA(
              isA<CredentialUseFailure>().having(
                (e) => e.code,
                'code',
                'fill_needs_attention',
              ),
            ),
          );
          await f.service.owner.acknowledgeFocusedFillAttention(op.id);
        }
        f.driver.result = const FocusedFillBatchResult(FocusedFillState.sent);
        expect(
          (await f.fill(r.id, 'explicit-new-operation')).state,
          FocusedFillState.sent,
        );
        final (path, key) = await f.backup('terminal-${state.name}');
        final target = await EncryptedInformationRepository.open(
          '${f.root.path}/target',
          TestKeyStore(),
          clock: () => f.now,
        );
        addTearDown(target.close);
        await target.backups.restoreFrom(path, key);
        expect(target.focusedFillOperations.first.state, state);
        expect(target.focusedFillOperations.last.state, FocusedFillState.sent);
        final old = await f.service.agent.startFocusedFill(
          f.session,
          f.input(r.id, 'original'),
        );
        expect(old['duplicate'], true);
        expect(old['fillState'], state.name);
        expect(f.repo.focusedFillOperations, hasLength(2));
      },
    );
  }
  test(
    'SQLCipher keeps interleaved command and fill operations, no restart capabilities',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final r = await f.request();
      final a = await f.fill(r.id, 'first');
      final command = await f.command();
      final b = await f.fill(r.id, 'second');
      expect(
        [a.state, b.state],
        [FocusedFillState.sent, FocusedFillState.sent],
      );
      final before = f.repo.focusedFillOperations
          .map((o) => o.toStorageJson())
          .toList();
      final deadline = f.repo.credentialUseRequests.first.credentialExpiresAt;
      expect(f.repo.credentialUseRequests.first.credentialExpiresAt, deadline);
      final duplicate = await f.service.agent.startFocusedFill(
        f.session,
        f.input(r.id, 'first'),
      );
      expect(duplicate['duplicate'], true);
      expect(f.repo.focusedFillOperations, hasLength(2));
      await f.reopen();
      expect(
        f.repo.focusedFillOperations.map((o) => o.toStorageJson()).toList(),
        before,
      );
      expect(f.repo.credentialExecutions.single.id, command.id);
      expect(f.repo.managedCredentials.single.suggestedBinding, '');
      expect(
        f.repo.credentialUseRequests.every(
          (r) => r.invalidatedCode == 'grant_revoked',
        ),
        true,
      );
      await expectLater(
        f.service.agent.startFocusedFill(
          f.session,
          f.input(r.id, 'after-restart'),
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      final bytes = await File(
        '${f.root.path}/source/library.db',
      ).readAsBytes();
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('SYNTHETIC_FILL')),
      );
    },
  );
  for (final released in [false, true]) {
    test(
      'reopen archives interrupted fill, released=$released, without resending',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.close);
        final r = await f.request();
        await f.intent(r, released: released);
        final pending = await f.request(approve: false);
        await f.reopen();
        final op = f.repo.focusedFillOperations.single;
        expect(op.state, FocusedFillState.unknown);
        expect(op.inputReleased, released);
        expect(op.finishedAt, f.now);
        expect(op.attentionAcknowledgedAt, isNull);
        expect(
          f.repo.credentialUseRequests
              .singleWhere((r) => r.id == pending.id)
              .state,
          'cancelled',
        );
        await f.service.owner.acknowledgeFocusedFillAttention(op.id);
        await f.reopen();
        expect(
          f.repo.focusedFillOperations.single.attentionAcknowledgedAt,
          f.now,
        );
        expect(
          f.repo.focusedFillOperations.single.state,
          FocusedFillState.unknown,
        );
      },
    );
  }
  test(
    'atomic snapshots refuse bad links, plan identity, duplicate IDs and rolled-back validation',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final r = await f.request();
      final a = await f.fill(r.id, 'one');
      await f.command();
      final before = jsonEncode(
        f.repo.focusedFillOperations.map((o) => o.toStorageJson()).toList(),
      );
      for (final defect in [
        'orphan',
        'command',
        'duplicate',
        'fingerprint',
        'application',
        'checked',
        'request-attempt',
      ]) {
        var operations = List<FocusedFillOperation>.of(
          f.repo.focusedFillOperations,
        );
        var requests = List<CredentialUseRequest>.of(
          f.repo.credentialUseRequests,
        );
        switch (defect) {
          case 'orphan':
            operations = [
              a.changed({'requestId': 'missing'}),
            ];
          case 'command':
            operations = [
              a.changed({
                'requestId': f.repo.credentialExecutions.single.requestId,
              }),
            ];
          case 'duplicate':
            operations.add(a);
          case 'fingerprint':
            operations = [
              a.changed({'fingerprint': 'sha256:${'f' * 64}'}),
            ];
          case 'application':
            operations = [
              a.changed({
                'application': {
                  'executable': r'C:\Other.exe',
                  'sha256': 'b' * 64,
                },
              }),
            ];
          case 'checked':
            operations = [
              a.changed({'checkedAt': null}),
            ];
          case 'request-attempt':
            requests = [
              for (final old in requests)
                old.id == r.id ? old.changed({'attemptedAt': null}) : old,
            ];
        }
        await expectLater(
          f.repo.commitFocusedFillRuntime(requests, operations),
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
            f.repo.focusedFillOperations.map((o) => o.toStorageJson()).toList(),
          ),
          before,
        );
      }
      var validations = 0;
      await expectLater(
        f.repo.commitFocusedFillRuntime(
          f.repo.credentialUseRequests,
          [
            a.changed({'fillState': 'unknown', 'errorCode': 'fill_unknown'}),
          ],
          validate: () {
            if (++validations == 2)
              throw const CredentialUseFailure('grant_revoked');
          },
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      await f.reopen();
      expect(
        jsonEncode(
          f.repo.focusedFillOperations.map((o) => o.toStorageJson()).toList(),
        ),
        before,
      );
      expect(f.repo.credentialExecutions, hasLength(1));
    },
  );
  test(
    'format7 encrypted backup includes both result types, excludes pending and restores facts only',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final r = await f.request();
      final sent = await f.fill(r.id, 'sent');
      await f.command();
      await f.request(approve: false);
      final interrupted = await f.request();
      await f.intent(interrupted, released: true);
      final (path, key) = await f.backup('mixed');
      final preview = await f.repo.backups.inspect(path, key);
      expect(preview.formatVersion, 7);
      expect(preview.focusedFillCount, 2);
      expect(preview.credentialExecutionCount, 1);
      expect(preview.credentialUseHistoryCount, 3);
      expect(
        f.repo.focusedFillOperations.last.state,
        FocusedFillState.checking,
      );
      final target = await EncryptedInformationRepository.open(
        '${f.root.path}/target',
        TestKeyStore(),
        clock: () => f.now,
      );
      addTearDown(target.close);
      await target.backups.restoreFrom(path, key);
      expect(target.focusedFillOperations.first.state, FocusedFillState.sent);
      expect(target.focusedFillOperations.first.id, sent.id);
      expect(target.focusedFillOperations.last.state, FocusedFillState.unknown);
      expect(
        target.focusedFillOperations.every((o) => o.restoredAt == f.now),
        true,
      );
      expect(
        target.credentialUseRequests.every(
          (r) => r.invalidatedCode == 'grant_revoked',
        ),
        true,
      );
      expect(
        utf8.decode(target.credentialMaterials.single.bytes),
        'SYNTHETIC_FILL_中文_🧭_349826',
      );
      expect(target.managedCredentials.single.suggestedBinding, '');
      final runtimeJson = jsonEncode(
        _payload(path, key)['tables']['credential_focused_fills'],
      );
      for (final forbidden in [
        'SYNTHETIC_FILL',
        'exitCode',
        'cleanup',
        'materialLease',
        'sessionCapability',
        'hwnd',
        'inputLength',
      ]) {
        expect(runtimeJson, isNot(contains(forbidden)), reason: forbidden);
      }
      final service = f.newService(target);
      addTearDown(service.close);
      await expectLater(
        service.agent.startFocusedFill(f.session, f.input(r.id, 'new')),
        throwsA(isA<CredentialUseFailure>()),
      );
    },
  );
  test(
    'format7 refuses extra/private data and mismatched fill associations without changing recipient',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final r = await f.request();
      await f.fill(r.id, 'one');
      final (path, key) = await f.backup('original');
      final original = _payload(path, key);
      final target = await EncryptedInformationRepository.open(
        '${f.root.path}/target',
        TestKeyStore(),
      );
      addTearDown(target.close);
      for (final defect in [
        'secret',
        'handle',
        'exitCode',
        'orphan',
        'row-id',
        'duplicate',
        'fingerprint',
        'date',
        'v6',
        'launch',
      ]) {
        final payload =
            jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
        final rows = payload['tables']['credential_focused_fills'] as List;
        final op =
            jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
        switch (defect) {
          case 'secret':
            op['secret'] = 'MUST_NOT_ENTER_ARCHIVE';
          case 'handle':
            op['hwnd'] = 123;
          case 'exitCode':
            op['exitCode'] = 0;
          case 'orphan':
            op['requestId'] = 'missing';
            rows.first['request_id'] = 'missing';
          case 'row-id':
            rows.first['id'] = 'other';
          case 'duplicate':
            rows.add(Map<String, dynamic>.from(rows.first));
          case 'fingerprint':
            op['fingerprint'] = 'sha256:${'c' * 64}';
          case 'date':
            op['finishedAt'] = '2026-10-19';
          case 'v6':
            payload['version'] = 6;
            payload['tables'].remove('credential_focused_fills');
          case 'launch':
            final reqs = payload['tables']['credential_use_requests'] as List;
            final req =
                jsonDecode(reqs.first['payload'] as String)
                    as Map<String, dynamic>;
            req['plan'] = {};
            reqs.first['payload'] = jsonEncode(req);
        }
        rows.first['payload'] = jsonEncode(op);
        final corrupt = '${f.root.path}/$defect.aimbackup';
        await File(path).copy(corrupt);
        final db = _backupDb(corrupt, key);
        try {
          db.execute('UPDATE backup_snapshot SET payload=?', [
            jsonEncode(payload),
          ]);
        } finally {
          db.close();
        }
        await expectLater(
          target.backups.restoreFrom(corrupt, key),
          throwsA(isA<StorageFailure>()),
          reason: defect,
        );
        expect(target.focusedFillOperations, isEmpty);
        expect(target.managedCredentials, isEmpty);
      }
    },
  );
  test(
    'unresolved input history survives retention; owner acknowledgement enables atomic pruning',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final r = await f.request();
      await f.intent(r, released: true);
      await f.reopen();
      f.now = f.now.add(const Duration(days: 400));
      final (old, key) = await f.backup('unresolved');
      expect((await f.repo.backups.inspect(old, key)).focusedFillCount, 1);
      await f.service.owner.acknowledgeFocusedFillAttention(
        f.repo.focusedFillOperations.single.id,
      );
      f.now = f.now.add(const Duration(days: 400));
      final (after, key2) = await f.backup('reviewed');
      expect((await f.repo.backups.inspect(after, key2)).focusedFillCount, 0);
      await f.service.owner.pruneCredentialUseHistory();
      expect(f.repo.focusedFillOperations, isEmpty);
      expect(f.repo.credentialUseRequests, isEmpty);
      await f.reopen();
      expect(f.repo.focusedFillOperations, isEmpty);
    },
  );
  final legacy = Platform.environment['ISSUE35_SCHEMA17_PROBE'];
  Future<Map<String, dynamic>> probe(List<String> args) async {
    final interpreted = legacy!.endsWith('.dart');
    final result = await Process.run(
      interpreted ? Platform.resolvedExecutable : legacy,
      [
        if (interpreted) ...['run', legacy],
        ...args,
      ],
      workingDirectory: File(legacy).parent.path,
    );
    expect(result.exitCode, 0, reason: 'Pinned schema17 helper process');
    return jsonDecode((result.stdout as String).trim().split('\n').last)
        as Map<String, dynamic>;
  }

  test(
    'actual schema17 reader upgrades to19 and format6 restores; old reader refuses new database/backup unchanged',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final created = await probe(['create', '${f.root.path}/legacy']);
      expect(created, {'status': 'created', 'schema': 17, 'backupVersion': 6});
      final keys = TestKeyStore()..key = List<int>.filled(32, 61);
      var db = sqlite.sqlite3.open('${f.root.path}/legacy/library.db');
      db.execute('PRAGMA key = "x\'${'3d' * 32}\'"');
      db.execute('PRAGMA user_version=10');
      db.close();
      final upgraded = await EncryptedInformationRepository.open(
        '${f.root.path}/legacy',
        keys,
      );
      expect(upgraded.credentialUseRequests, hasLength(2));
      expect(upgraded.credentialExecutions, hasLength(1));
      expect(upgraded.focusedFillOperations, isEmpty);
      await upgraded.close();
      final file = File('${f.root.path}/legacy/library.db');
      final before = sha256.convert(await file.readAsBytes()).toString();
      expect(await probe(['inspect', '${f.root.path}/legacy']), {
        'status': 'rejected',
        'errorCode': 'unsupported_schema',
      });
      expect(sha256.convert(await file.readAsBytes()).toString(), before);
      final target = await EncryptedInformationRepository.open(
        '${f.root.path}/target',
        TestKeyStore(),
      );
      addTearDown(target.close);
      final recovery = (await File(
        '${f.root.path}/legacy-recovery.txt',
      ).readAsString()).trim();
      final restored = await target.backups.restoreFrom(
        '${f.root.path}/legacy6.aimbackup',
        recovery,
      );
      expect(restored.formatVersion, 6);
      expect(restored.focusedFillCount, 0);
      expect(target.credentialUseRequests, hasLength(2));
      expect(target.items.single.name, 'Legacy fixture');
      final collisionPath = '${f.root.path}/collision/source';
      expect((await probe(['create', collisionPath]))['schema'], 17);
      final collisionDb = sqlite.sqlite3.open('$collisionPath/library.db');
      collisionDb.execute('PRAGMA key = "x\'${'3d' * 32}\'"');
      collisionDb.execute(
        'CREATE TABLE credential_focused_fills(unrelated TEXT)',
      );
      collisionDb.close();
      await expectLater(
        EncryptedInformationRepository.open(collisionPath, keys),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'unsupported_schema',
          ),
        ),
      );
      final unchanged = sqlite.sqlite3.open('$collisionPath/library.db');
      try {
        unchanged.execute('PRAGMA key = "x\'${'3d' * 32}\'"');
        expect(
          unchanged.select('PRAGMA user_version').single.values.single,
          17,
        );
        expect(
          unchanged
              .select('SELECT version FROM library_format')
              .single['version'],
          17,
        );
        expect(
          unchanged
              .select('SELECT count(*) FROM credential_operations')
              .single
              .values
              .single,
          1,
        );
      } finally {
        unchanged.close();
      }
      final r = await f.request();
      await f.fill(r.id, 'a');
      final (path, key) = await f.backup('new-format');
      final recoveryFile = File('${f.root.path}/new-format-recovery.txt');
      await recoveryFile.writeAsString(key);
      expect(
        await probe([
          'inspect-backup',
          '${f.root.path}/old-empty',
          path,
          recoveryFile.path,
        ]),
        {'status': 'rejected', 'errorCode': 'unsupported_backup'},
      );
    },
    skip: legacy == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
