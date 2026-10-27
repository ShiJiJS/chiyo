import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/backup_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'workspace_approvals_test.dart' show decision;

class BackupPort implements WorkspaceBackupSource {
  BackupPort(this.inner);
  final WorkspaceBackupSource inner;
  final writes = <WorkspaceBackupChange>[], queries = <String>[];
  bool absent = false, wrong = false, wrongCounts = false, offline = false;
  WorkspaceBackupReceipt project(WorkspaceBackupReceipt r) =>
      WorkspaceBackupReceipt(
        operationId: r.operationId,
        commandDigest: wrong ? 'wrong' : r.commandDigest,
        action: r.action,
        expectedVersion: r.expectedVersion,
        version: r.version,
        resource: r.resource,
        counts: wrongCounts ? WorkspaceBackupCounts({}) : r.counts,
      );
  @override
  Future<WorkspaceBackupStatus> status() => inner.status();
  @override
  Future<String> revealRecoveryKey() => inner.revealRecoveryKey();
  @override
  Future<WorkspaceBackupPreview> inspect(
    WorkspaceBackupResource a,
    WorkspaceBackupResource k,
  ) => inner.inspect(a, k);
  @override
  Future<void> releasePreview(String token) => inner.releasePreview(token);
  @override
  Future<WorkspaceBackupReceipt> change(WorkspaceBackupChange c) async {
    writes.add(c);
    if (absent) throw const WorkspaceFailure('unknown_outcome', 'unknown');
    return project(await inner.change(c));
  }

  @override
  Future<WorkspaceBackupReceipt?> receipt(String id) async {
    queries.add(id);
    if (offline) throw const WorkspaceFailure('offline', 'offline');
    final r = await inner.receipt(id);
    return r == null ? null : project(r);
  }
}

void main() {
  const resume = WorkspaceRecordRef(WorkspaceRecordKind.information, 'resume'),
      azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure'),
      ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));
  late SampleWorkspaceSource s;
  bool allowAssets = true;
  setUp(() {
    allowAssets = true;
    s = SampleWorkspaceSource(
      readAsset: (p) {
        if (!allowAssets) throw StateError('restored files must be detached');
        return File(p).readAsBytes();
      },
    );
  });
  tearDown(() => s.dispose());
  Future<WorkspaceBackupReceipt> write(
    WorkspaceBackupAction action, {
    WorkspaceBackupResource? selection,
    String? token,
    String? id,
  }) async => s.backups.change(
    WorkspaceBackupChange(
      operationId: id ?? workspaceOperationId(),
      action: action,
      expectedVersion: (await s.backups.status()).version,
      selection: selection,
      previewToken: token,
    ),
  );
  Future<WorkspaceBackupResource> choice(WorkspaceBackupPick kind) async =>
      (await s.backups.choices(kind)).first;
  Future<
    ({
      WorkspaceBackupResource archive,
      WorkspaceBackupResource key,
      WorkspaceBackupCounts counts,
    })
  >
  exported() async {
    await s.prepareBackupExportFixture();
    await write(WorkspaceBackupAction.enableKey);
    final key = (await write(
      WorkspaceBackupAction.saveKey,
      selection: await choice(WorkspaceBackupPick.keyOutput),
    )).resource!;
    final r = await write(
      WorkspaceBackupAction.export,
      selection: await choice(WorkspaceBackupPick.archiveOutput),
    );
    return (archive: r.resource!, key: key, counts: r.counts!);
  }

  Future<WorkspaceBackupPreview> target(
    WorkspaceBackupResource a,
    WorkspaceBackupResource k,
  ) async {
    await s.prepareBackupRecipient();
    expect((await s.backups.status()).recipientEmpty, true);
    return s.backups.inspect(a, k);
  }

  test(
    'independent key must be saved first; output collisions preserve original and exact replay survives config changes',
    () async {
      await s.prepareBackupExportFixture();
      final out = await choice(WorkspaceBackupPick.archiveOutput);
      await expectLater(
        write(WorkspaceBackupAction.export, selection: out),
        fails('key_unavailable'),
      );
      await write(WorkspaceBackupAction.enableKey);
      expect(
        await s.backups.revealRecoveryKey(),
        startsWith('preview-recovery:'),
      );
      await expectLater(
        write(WorkspaceBackupAction.export, selection: out),
        fails('recovery_key_not_saved'),
      );
      final key = await choice(WorkspaceBackupPick.keyOutput);
      final c = WorkspaceBackupChange(
        operationId: 'save-key',
        action: WorkspaceBackupAction.saveKey,
        expectedVersion: (await s.backups.status()).version,
        selection: key,
      );
      final r = await s.backups.change(c);
      final collision = (await s.backups.choices(
        WorkspaceBackupPick.keyOutput,
      )).last;
      expect(collision.name, r.resource!.name);
      await expectLater(
        write(WorkspaceBackupAction.saveKey, selection: collision),
        fails('output_exists'),
      );
      await write(WorkspaceBackupAction.export, selection: out);
      expect(await s.backups.change(c), same(r));
      await expectLater(
        s.backups.change(
          WorkspaceBackupChange(
            operationId: 'save-key',
            action: c.action,
            expectedVersion: c.expectedVersion,
            selection: collision,
          ),
        ),
        fails('operation_conflict'),
      );
      expect((await s.backups.status()).latestArchive!.id, out.id);
    },
  );

  test(
    'unavailable ordinary originals fail the whole archive without publishing a partial success',
    () async {
      s.dispose();
      s = SampleWorkspaceSource(
        readAsset: (p) async {
          final bytes = await File(p).readAsBytes();
          if (!p.endsWith('manifest.json')) return bytes;
          final manifest =
              jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          manifest['files'] = (manifest['files'] as List)
              .where((f) => f['id'] != 'unknown')
              .toList();
          return Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
        },
      );
      await write(WorkspaceBackupAction.enableKey);
      await write(
        WorkspaceBackupAction.saveKey,
        selection: await choice(WorkspaceBackupPick.keyOutput),
      );
      final before = await s.backups.status(),
          out = await choice(WorkspaceBackupPick.archiveOutput);
      await expectLater(
        write(WorkspaceBackupAction.export, selection: out, id: 'missing'),
        fails('attachment_missing'),
      );
      final after = await s.backups.status();
      expect(after.version, before.version);
      expect(after.latestArchive, isNull);
      expect(await s.backups.receipt('missing'), isNull);
      expect(
        (await s.backups.choices(
          WorkspaceBackupPick.archiveInput,
        )).where((r) => r.id == out.id),
        isEmpty,
      );
    },
  );

  test(
    'full detached round trip retains fields, relations, revisions, files, preferences and history without active grants or pending work',
    () async {
      await s.prepareBackupExportFixture();
      final before = await s.readDetail(azure);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'edit-before-export',
          expectedVersion: before.version,
          record: before.record,
          values: {...before.values, 'port': '2200'},
        ),
      );
      final saved = await s.readDetail(azure),
          catalog = await s.loadCatalog(),
          file = await s.readFilePreview(resume, 'file', version: 1);
      final credential = await s.credentials.read(ssh),
          materials = await s.credentials.materials(ssh),
          plugins = await s.plugins.load();
      final prefs = await s.settings.read();
      await s.settings.change(
        WorkspaceSettingsChange(
          operationId: 'prefs',
          expectedVersion: prefs.version,
          desired: prefs.copyWith(
            theme: WorkspaceTheme.dark,
            notifications: false,
            requestMinutes: 60,
          ),
        ),
      );
      await s.approvals.change(decision(await s.approvals.read('server')));
      s.demonstrateApprovalExecutions('server');
      final oldSession = (await s.approvals.read(
        'server',
      )).credential!.session.id;
      await write(WorkspaceBackupAction.enableKey);
      final k = (await write(
        WorkspaceBackupAction.saveKey,
        selection: await choice(WorkspaceBackupPick.keyOutput),
      )).resource!;
      final export = await write(
        WorkspaceBackupAction.export,
        selection: await choice(WorkspaceBackupPick.archiveOutput),
      );
      expect(export.counts![WorkspaceBackupCategory.fileBytes], greaterThan(0));
      expect(
        export.counts![WorkspaceBackupCategory.plugins],
        plugins.packages.length,
      );
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'after-export',
          expectedVersion: saved.version,
          record: saved.record,
          values: {...saved.values, 'port': '3300'},
        ),
      );
      allowAssets = false;
      final p = await target(export.resource!, k);
      expect(p.counts.same(export.counts!), true);
      expect((await s.queryRecords(const WorkspaceQuery())).total, 0);
      await write(
        WorkspaceBackupAction.restore,
        selection: p.archive,
        token: p.token,
      );
      final restored = await s.readDetail(azure);
      expect(restored.values, saved.values);
      expect(restored.fieldIds, saved.fieldIds);
      expect(restored.relations, saved.relations);
      expect(restored.version, saved.version);
      expect(
        (await s.loadCatalog()).tags.map((x) => x.id),
        catalog.tags.map((x) => x.id),
      );
      expect((await s.loadRevisions(azure)).length, 1);
      expect(
        (await s.readFilePreview(resume, 'file', version: 1)).image,
        file.image,
      );
      expect(
        (await s.credentials.read(ssh)).materialVersion,
        credential.materialVersion,
      );
      expect(
        (await s.credentials.materials(ssh)).materials.length,
        materials.materials.length,
      );
      expect((await s.settings.read()).theme, WorkspaceTheme.dark);
      expect((await s.settings.read()).notifications, false);
      expect((await s.backups.status()).keyCreated, false);
      expect(
        (await s.approvals.query(
          const WorkspaceApprovalQuery(filter: WorkspaceApprovalFilter.pending),
        )).items,
        isEmpty,
      );
      expect(
        (await s.proposals.query(const WorkspaceProposalQuery())).items,
        isEmpty,
      );
      expect(
        (await s.grantHistory.query(
          const WorkspaceGrantQuery(filter: WorkspaceGrantFilter.active),
        )).items,
        isEmpty,
      );
      final history = await s.approvals.read('server');
      expect(history.credential!.session.id, oldSession);
      expect(history.executions, isNotEmpty);
      for (final e in history.executions) {
        expect(e.fromBackup, true);
        expect(e.cleanup, WorkspaceExecutionCleanup.notNeeded);
        expect(e.state, isNot(WorkspaceExecutionState.running));
      }
      s.publishApprovalExecutionObservation('server');
      expect(
        (await s.approvals.read(
          'server',
        )).executions.map((e) => e.bindingDigest),
        history.executions.map((e) => e.bindingDigest),
      );
      final d = await s.credentials.read(ssh),
          session = (await s.credentials.sessions()).first,
          receiver = (await s.credentials.receivers(ssh)).first;
      expect(session.id, isNot(oldSession));
      final requested = await s.credentials.requestUse(
        WorkspaceCredentialUseDraft(
          operationId: 'fresh',
          ref: ssh,
          expectedRecordVersion: d.recordVersion,
          expectedMaterialVersion: d.materialVersion,
          useGeneration: d.useGeneration,
          purpose: '恢复后的新申请',
          receiverId: receiver.id,
          sessionId: session.id,
        ),
      );
      final newRequest = await s.approvals.read(
        'credential:${requested.requestId}',
      );
      expect(newRequest.request.state, WorkspaceApprovalState.pending);
      await s.approvals.change(decision(newRequest));
      expect(
        (await s.approvals.read(newRequest.request.id)).request.state,
        WorkspaceApprovalState.approved,
      );
    },
  );

  test(
    'inspect is read-only; wrong key, bad archive, newer format and a nonempty target never restore',
    () async {
      final e = await exported();
      await expectLater(
        s.backups.inspect(e.archive, e.key),
        fails('recipient_not_empty'),
      );
      await s.prepareBackupRecipient();
      final state = await s.backups.status();
      final keys = await s.backups.choices(WorkspaceBackupPick.keyInput),
          archives = await s.backups.choices(WorkspaceBackupPick.archiveInput);
      await expectLater(
        s.backups.inspect(
          e.archive,
          keys.firstWhere((r) => r.id == 'wrong-key'),
        ),
        fails('invalid_backup'),
      );
      await expectLater(
        s.backups.inspect(e.archive, keys.firstWhere((r) => r.id == 'bad-key')),
        fails('invalid_recovery_key'),
      );
      await expectLater(
        s.backups.inspect(
          archives.firstWhere((r) => r.id == 'bad-archive'),
          e.key,
        ),
        fails('invalid_backup'),
      );
      await expectLater(
        s.backups.inspect(
          archives.firstWhere((r) => r.id == 'new-format'),
          e.key,
        ),
        fails('unsupported_backup'),
      );
      final p = await s.backups.inspect(e.archive, e.key);
      expect((await s.backups.status()).version, state.version);
      expect((await s.queryRecords(const WorkspaceQuery())).total, 0);
      await s.backups.releasePreview(p.token);
      await expectLater(
        write(
          WorkspaceBackupAction.restore,
          selection: e.archive,
          token: p.token,
        ),
        fails('backup_changed'),
      );
    },
  );

  test(
    'stale target and changed archive versions invalidate exact restore plans',
    () async {
      final e = await exported(), p = await target(e.archive, e.key);
      final c = await s.loadCatalog();
      await s.changeClassification(
        WorkspaceTagChange(
          operationId: 'target-tag',
          action: WorkspaceTagAction.create,
          expectedVersion: c.version,
          name: '新标签',
        ),
      );
      await expectLater(
        write(
          WorkspaceBackupAction.restore,
          selection: e.archive,
          token: p.token,
        ),
        fails('backup_changed'),
      );
      await s.prepareBackupRecipient();
      final again = await s.backups.inspect(e.archive, e.key);
      s.backups.changeResource(e.archive.id);
      await expectLater(
        write(
          WorkspaceBackupAction.restore,
          selection: e.archive,
          token: again.token,
        ),
        fails('backup_changed'),
      );
      expect((await s.backups.status()).recipientEmpty, true);
    },
  );

  test(
    'hidden empty view is not a restore recipient; classification-only state is also nonempty',
    () async {
      final e = await exported();
      s.setScenario(SampleWorkspaceScenario.empty);
      expect((await s.backups.status()).recipientEmpty, false);
      await s.prepareBackupRecipient();
      final catalog = await s.loadCatalog();
      await s.changeClassification(
        WorkspaceTagChange(
          operationId: 'only-tag',
          action: WorkspaceTagAction.create,
          expectedVersion: catalog.version,
          name: '唯一标签',
        ),
      );
      final status = await s.backups.status();
      expect(status.recipientEmpty, false);
      expect(status.blockers, contains('目录或标签'));
      await expectLater(
        s.backups.inspect(e.archive, e.key),
        fails('recipient_not_empty'),
      );
    },
  );

  test(
    'restore failure is atomic; cancelled staging cleanup can fail and be retried without a restore',
    () async {
      final e = await exported(), p = await target(e.archive, e.key);
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '写入失败');
      await expectLater(
        write(
          WorkspaceBackupAction.restore,
          selection: e.archive,
          token: p.token,
          id: 'failed',
        ),
        fails('disk_full'),
      );
      expect((await s.backups.status()).recipientEmpty, true);
      expect(await s.backups.receipt('failed'), isNull);
      s.backups.nextCleanupFailure = const WorkspaceFailure(
        'cleanup_failed',
        '清理失败',
      );
      await expectLater(
        s.backups.releasePreview(p.token),
        fails('cleanup_failed'),
      );
      expect((await s.backups.status()).cleanupCount, 1);
      s.backups.nextCleanupFailure = const WorkspaceFailure(
        'cleanup_failed',
        '再失败',
      );
      await expectLater(
        write(WorkspaceBackupAction.cleanup),
        fails('cleanup_failed'),
      );
      expect((await s.backups.status()).cleanupCount, 1);
      await write(WorkspaceBackupAction.cleanup);
      expect((await s.backups.status()).cleanupCount, 0);
      expect((await s.backups.status()).recipientEmpty, true);
    },
  );

  test(
    'committed restore with pending cleanup retains success and replays only original receipt',
    () async {
      final e = await exported(), p = await target(e.archive, e.key);
      s.backups.nextCleanupFailure = const WorkspaceFailure(
        'cleanup_failed',
        '清理失败',
      );
      final c = WorkspaceBackupChange(
        operationId: 'restore',
        action: WorkspaceBackupAction.restore,
        expectedVersion: (await s.backups.status()).version,
        selection: e.archive,
        previewToken: p.token,
      );
      final r = await s.backups.change(c);
      expect(r.matches(c), true);
      expect((await s.backups.status()).recipientEmpty, false);
      expect((await s.backups.status()).cleanupCount, 1);
      await write(WorkspaceBackupAction.cleanup);
      expect(await s.backups.change(c), same(r));
      expect((await s.backups.status()).cleanupCount, 0);
    },
  );

  test(
    'controller cancellation and definite failure preserve selection; unknown outcome freezes until exact original receipt',
    () async {
      await s.prepareBackupExportFixture();
      final port = BackupPort(s.backups),
          m = BackupController(port, const Stream.empty());
      addTearDown(m.dispose);
      await m.load();
      await m.write(WorkspaceBackupAction.enableKey);
      final out = await choice(WorkspaceBackupPick.keyOutput);
      await m.pick(WorkspaceBackupPick.keyOutput, (_) async => out);
      await m.pick(WorkspaceBackupPick.keyOutput, (_) async => null);
      expect(m.keyOutput, same(out));
      await m.pick(
        WorkspaceBackupPick.keyOutput,
        (_) async => throw const WorkspaceFailure('picker_failed', '选择失败'),
      );
      expect(m.keyOutput, same(out));
      expect(m.failure!.code, 'picker_failed');
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '保存失败');
      await m.write(WorkspaceBackupAction.saveKey);
      expect(m.failure!.code, 'disk_full');
      expect(m.keyOutput, same(out));
      expect((await s.backups.status()).keySaved, false);
      s.backups.loseNextReply = true;
      await m.write(WorkspaceBackupAction.saveKey);
      expect(m.uncertain, true);
      expect(await m.closeFlow(), false);
      final op = port.writes.last.operationId, writes = port.writes.length;
      await m.write(WorkspaceBackupAction.saveKey);
      await m.pick(WorkspaceBackupPick.keyOutput, (_) async => out);
      expect(port.writes.length, writes);
      port.offline = true;
      await m.reconcile();
      expect(m.uncertain, true);
      port.offline = false;
      port.wrong = true;
      await m.reconcile();
      expect(m.uncertain, true);
      port.wrong = false;
      await m.reconcile();
      expect(m.uncertain, false);
      expect(m.value!.keySaved, true);
      expect(m.keyOutput, isNull);
      expect(port.queries, everyElement(op));
      expect(port.writes.length, writes);
    },
  );

  test(
    'confirmed non-submission permits explicit retry but never automatically writes',
    () async {
      final port = BackupPort(s.backups)..absent = true,
          m = BackupController(port, const Stream.empty());
      addTearDown(m.dispose);
      await m.load();
      await m.write(WorkspaceBackupAction.enableKey);
      expect(m.uncertain, true);
      await m.reconcile();
      expect(m.failure!.code, 'not_submitted');
      expect(port.writes.length, 1);
      expect(m.value!.keyCreated, false);
      port.absent = false;
      await m.write(WorkspaceBackupAction.enableKey);
      expect(port.writes.length, 2);
      expect(
        port.writes.first.operationId,
        isNot(port.writes.last.operationId),
      );
    },
  );

  test(
    'restore counts are bound to inspected scope; a false receipt stays unknown even after lookup',
    () async {
      final e = await exported();
      await s.prepareBackupRecipient();
      final port = BackupPort(s.backups),
          m = BackupController(port, const Stream.empty());
      addTearDown(m.dispose);
      await m.load();
      await m.pick(WorkspaceBackupPick.archiveInput, (_) async => e.archive);
      await m.pick(WorkspaceBackupPick.keyInput, (_) async => e.key);
      await m.inspect();
      port.wrongCounts = true;
      await m.write(WorkspaceBackupAction.restore);
      expect(m.uncertain, true);
      await m.reconcile();
      expect(m.uncertain, true);
      port.wrongCounts = false;
      await m.reconcile();
      expect(m.result!.counts!.same(e.counts), true);
      expect(m.uncertain, false);
      expect(port.writes.length, 1);
    },
  );

  test(
    'fixture replacement during asynchronous file preparation cancels publication',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var gate = false;
      final slow = SampleWorkspaceSource(
        readAsset: (p) async {
          if (gate) {
            gate = false;
            entered.complete();
            await release.future;
          }
          return File(p).readAsBytes();
        },
      );
      addTearDown(slow.dispose);
      await slow.prepareBackupExportFixture();
      Future<WorkspaceBackupReceipt> mutate(
        WorkspaceBackupAction action, {
        WorkspaceBackupResource? selection,
      }) async => slow.backups.change(
        WorkspaceBackupChange(
          operationId: workspaceOperationId(),
          action: action,
          expectedVersion: (await slow.backups.status()).version,
          selection: selection,
        ),
      );
      await mutate(WorkspaceBackupAction.enableKey);
      await mutate(
        WorkspaceBackupAction.saveKey,
        selection: (await slow.backups.choices(
          WorkspaceBackupPick.keyOutput,
        )).first,
      );
      final out = (await slow.backups.choices(
        WorkspaceBackupPick.archiveOutput,
      )).first;
      gate = true;
      final pending = mutate(WorkspaceBackupAction.export, selection: out);
      final check = expectLater(pending, fails('conflict'));
      await entered.future;
      await slow.prepareBackupRecipient();
      release.complete();
      await check;
      expect((await slow.backups.status()).latestArchive, isNull);
    },
  );
}
