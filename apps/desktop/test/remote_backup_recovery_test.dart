@TestOn('!windows')
library;

// Real OnlineServer fixture uses POSIX secret mounts. Windows behavior is
// exercised by the explicit existing-NAS tests, without relaxing that boundary.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/backup_controller.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../../server/test/support/owner_reply_proxy.dart';
import 'support/synthetic_backup_picker.dart';
import 'support/complete_backup_library.dart';

class _Http extends HttpOverrides {}

class _Client {
  _Client(this.source, this.model);
  final RemoteWorkspaceSource source;
  final BackupController model;
  bool closed = false;
  static Future<_Client> open(
    DeviceCredentialFixture f,
    SyntheticBackupPicker picker,
    String directory, {
    OwnerReplyProxy? proxy,
  }) async {
    final client = await OwnerClient.connect(
      address: proxy?.address ?? f.owner.address,
      token: f.token,
      trust: f.trust,
    );
    final source = RemoteWorkspaceSource(
      client,
      deviceFilesDirectory: directory,
      outputPicker: picker,
    );
    final model = BackupController(source.backups, source.changes);
    final c = _Client(source, model);
    addTearDown(c.close);
    await model.load();
    return c;
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    model.dispose();
    await source.dispose();
  }

  Future<void> pick(WorkspaceBackupPick kind) =>
      model.pick(kind, source.backups.pick);
}

Future<void> _setupKey(_Client c) async {
  expect(c.model.available, isTrue);
  await c.model.write(WorkspaceBackupAction.enableKey);
  expect(c.model.failure, isNull);
  expect(c.model.value!.keyCreated, isTrue);
  await c.pick(WorkspaceBackupPick.keyOutput);
  await c.model.write(WorkspaceBackupAction.saveKey);
  expect(c.model.failure, isNull);
  expect(c.model.value!.keySaved, isTrue);
}

void main() {
  test(
    'complete remote library survives App native encrypted backup and a differently keyed server restore, including large attachment versions and actual device execution history',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final root = await f.root.resolveSymbolicLinks();
        final picker = SyntheticBackupPicker()
          ..keyOutput = '$root/complete-recovery.key'
          ..archiveOutput = '$root/complete.aimbackup';
        final c = await _Client.open(f, picker, '$root/complete-device');
        await prepareCompleteBackupLibrary(f, c.source);
        final before = await completeBackupRows(f);
        final originals = await completeBackupAttachmentBytes(f);
        expect(originals, hasLength(2));
        for (final rows in before.entries) {
          expect(
            rows.value,
            isNotEmpty,
            reason: 'Fixture must actually exercise ${rows.key}',
          );
        }
        final originalCatalog = await c.source.loadCatalog();
        final originalPlugins = await c.source.plugins.load();
        final originalExecutions = f.repo.credentialExecutions
            .map((e) => e.toArchiveJson())
            .toList();
        final originalRequests = f.repo.credentialUseRequests
            .where((r) => r.decidedAt != null)
            .map((r) => r.toJson())
            .toList();
        final history = await f.runtime.run(
          () => f.runtime.service.owner.history(),
        );
        final originalTextRequests = f.repo.requestHistory
            .map((r) => r.toJson())
            .toList();
        expect(originalExecutions, hasLength(1));
        expect(history.accesses, isNotEmpty);
        await _setupKey(c);
        await c.pick(WorkspaceBackupPick.archiveOutput);
        await c.model.write(WorkspaceBackupAction.export);
        expect(c.model.failure, isNull);
        final counts = c.model.result!.counts!;
        expect(counts[WorkspaceBackupCategory.fileBytes], 14 * 1024 * 1024);
        expect(
          await File(picker.archiveOutput!).length(),
          greaterThan(10 * 1024 * 1024),
        );
        await c.close();

        final target = await DeviceCredentialFixture.create();
        addTearDown(target.dispose);
        final targetRoot = await target.root.resolveSymbolicLinks();
        final inputs = SyntheticBackupPicker()
          ..archiveInput = picker.archiveOutput
          ..keyInput = picker.keyOutput;
        final d = await _Client.open(
          target,
          inputs,
          '$targetRoot/complete-device',
        );
        await d.pick(WorkspaceBackupPick.archiveInput);
        await d.pick(WorkspaceBackupPick.keyInput);
        await d.model.inspect();
        expect(d.model.failure, isNull);
        expect(d.model.preview!.counts.same(counts), isTrue);
        await d.model.write(WorkspaceBackupAction.restore);
        expect(d.model.failure, isNull);
        expect(d.model.result!.counts!.same(counts), isTrue);
        final after = await completeBackupRows(target);
        for (final table in before.keys) {
          expect(after[table], unorderedEquals(before[table]!), reason: table);
        }
        final restoredBytes = await completeBackupAttachmentBytes(target);
        expect(restoredBytes.keys, unorderedEquals(originals.keys));
        for (final entry in originals.entries) {
          expect(
            listEquals(restoredBytes[entry.key], entry.value),
            isTrue,
            reason: 'Exact bytes ${entry.key}',
          );
        }
        final restoredCatalog = await d.source.loadCatalog();
        expect(
          restoredCatalog.directories.map((v) => v.id),
          originalCatalog.directories.map((v) => v.id),
        );
        expect(
          restoredCatalog.tags.map((v) => v.id),
          originalCatalog.tags.map((v) => v.id),
        );
        final plugins = await d.source.plugins.load();
        expect(
          plugins.packages.map((p) => p.id),
          originalPlugins.packages.map((p) => p.id),
        );
        expect(
          restoredCatalog.types.map((p) => p.id),
          originalCatalog.types.map((p) => p.id),
        );
        final restoredHistory = await target.runtime.run(
          () => target.runtime.service.owner.history(),
        );
        expect(
          restoredHistory.accesses.map((a) => a.toJson()),
          history.accesses.map((a) => a.toJson()),
        );
        expect(
          restoredHistory.grants.map((g) => g.id),
          history.grants.map((g) => g.id),
        );
        for (final grant in restoredHistory.grants) {
          expect(
            Map<String, Object?>.from(grant.toJson())..remove('restoredAt'),
            history.grants.singleWhere((g) => g.id == grant.id).toJson(),
          );
        }
        expect(
          target.repo.requestHistory.map(
            (r) => Map<String, Object?>.from(r.toJson())..remove('restoredAt'),
          ),
          unorderedEquals(originalTextRequests),
        );
        expect(
          restoredHistory.grants.every(
            (g) => !g.active && g.restoredAt != null,
          ),
          isTrue,
        );
        expect(target.runtime.service.owner.requests, isEmpty);
        expect(target.runtime.service.owner.importProposals, isEmpty);
        expect(
          target.repo.credentialUseRequests,
          hasLength(originalRequests.length),
        );
        for (final request in target.repo.credentialUseRequests) {
          final old = originalRequests.singleWhere(
            (r) => r['id'] == request.id,
          );
          final restored = Map<String, Object?>.from(request.toJson())
            ..remove('restoredAt')
            ..['invalidatedCode'] = old['invalidatedCode'];
          expect(restored, old);
          expect(request.restoredAt, isNotNull);
          expect(request.invalidatedCode, 'grant_revoked');
        }
        for (final execution in target.repo.credentialExecutions) {
          final old = Map<String, Object?>.from(
            originalExecutions.singleWhere(
              (r) => r['executionId'] == execution.id,
            ),
          )..['cleanupState'] = 'not_needed';
          expect(
            Map<String, Object?>.from(execution.toArchiveJson())
              ..remove('restoredAt'),
            old,
          );
          expect(execution.restoredAt, isNotNull);
          expect(execution.pid, isNull);
          expect(execution.workerPid, isNull);
          expect(execution.materialLease, isNull);
        }
        // A later reopen must preserve exactly the installed library as well.
        await d.close();
        await target.reopen();
        final reopened = await completeBackupRows(target);
        for (final table in after.keys) {
          expect(
            reopened[table],
            unorderedEquals(after[table]!),
            reason: 'reopen $table',
          );
        }
      }, _Http());
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
  test(
    'normal recovery control reselects the original saved key after lost native access, without a second publication',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final root = await f.root.resolveSymbolicLinks();
        final picker = SyntheticBackupPicker()
          ..keyOutput = '$root/key-with-access'
          ..scoped = true
          ..failBookmark = true;
        final c = await _Client.open(f, picker, '$root/device');
        await c.model.write(WorkspaceBackupAction.enableKey);
        await c.pick(WorkspaceBackupPick.keyOutput);
        await c.model.write(WorkspaceBackupAction.saveKey);
        expect(c.model.needsAccess, isTrue);
        expect(c.model.uncertain, isTrue);
        final bytes = await File(picker.keyOutput!).readAsBytes();
        expect(await f.repo.backups.recoveryKeySaved(), isFalse);
        picker.cancelReselect = true;
        await c.model.recoverAccess();
        expect(c.model.needsAccess, isTrue);
        expect(picker.stages, 1);
        picker.cancelReselect = false;
        await c.model.recoverAccess();
        expect(c.model.failure, isNull);
        expect(c.model.value!.keySaved, isTrue);
        expect(await File(picker.keyOutput!).readAsBytes(), bytes);
        expect(picker.stages, 1);
        expect(picker.reselections, 2);
        expect(picker.leases, picker.stopped);
      }, _Http());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'normal backup controller saves independent key and encrypted archive, refuses overwrite and restores through real TLS and native publication',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final root = await f.root.resolveSymbolicLinks();
        final note = await f.runtime.run(
          () => f.runtime.service.owner.createInformation('合成资料', '', [
            const core.FieldInput('正文', '', 'SYNTHETIC_NORMAL_BACKUP'),
          ]),
        );
        await f.runtime.run(
          () => f.runtime.service.owner.createStringCredential(
            name: '合成密码',
            publicPurpose: '',
            secret: 'SYNTHETIC_NATIVE_PASSWORD',
          ),
        );
        final picker = SyntheticBackupPicker()
          ..keyOutput = '$root/recovery.key'
          ..archiveOutput = '$root/backup.aimbackup';
        final c = await _Client.open(f, picker, '$root/device');
        await _setupKey(c);
        expect(await File(picker.keyOutput!).exists(), isTrue);
        await c.pick(WorkspaceBackupPick.archiveOutput);
        await c.model.write(WorkspaceBackupAction.export);
        expect(c.model.failure, isNull);
        expect(c.model.result!.action, WorkspaceBackupAction.export);
        expect(c.model.result!.counts![WorkspaceBackupCategory.credentials], 1);
        expect(await File(picker.archiveOutput!).length(), greaterThan(4096));
        final recovery = await File(picker.keyOutput!).readAsString();
        final raw = await File(picker.archiveOutput!).readAsBytes();
        expect(
          latin1.decode(raw).contains('SYNTHETIC_NATIVE_PASSWORD'),
          isFalse,
        );
        expect(recovery.startsWith('aim-recovery-v1:'), isTrue);
        // Same existing destination cannot be overwritten by a later export.
        await c.pick(WorkspaceBackupPick.archiveOutput);
        await c.model.write(WorkspaceBackupAction.export);
        expect(c.model.failure!.code, 'not_submitted');
        expect(await File(picker.archiveOutput!).readAsBytes(), raw);
        expect(c.model.uncertain, isFalse);
        await c.close();
        final target = await DeviceCredentialFixture.create();
        addTearDown(target.dispose);
        final targetRoot = await target.root.resolveSymbolicLinks();
        final inputs = SyntheticBackupPicker()
          ..archiveInput = picker.archiveOutput
          ..keyInput = picker.keyOutput;
        final d = await _Client.open(target, inputs, '$targetRoot/device');
        await d.pick(WorkspaceBackupPick.archiveInput);
        await d.pick(WorkspaceBackupPick.keyInput);
        expect(d.model.canInspect, isTrue);
        await d.model.inspect();
        expect(d.model.failure, isNull);
        expect(d.model.canRestore, isTrue);
        expect(d.model.preview!.counts[WorkspaceBackupCategory.information], 1);
        await d.model.write(WorkspaceBackupAction.restore);
        expect(d.model.failure, isNull);
        expect(d.model.result!.action, WorkspaceBackupAction.restore);
        expect(d.model.value!.recipientEmpty, isFalse);
        expect((await target.owner.information()).single.id, note.id);
        expect(
          (await target.owner.information()).single.fields.single.value,
          'SYNTHETIC_NORMAL_BACKUP',
        );
        expect(
          utf8.decode(target.repo.credentialMaterials.single.bytes),
          'SYNTHETIC_NATIVE_PASSWORD',
        );
        await d.close();
        await target.reopen();
        final reopened = await _Client.open(
          target,
          inputs,
          '$targetRoot/device',
        );
        expect(reopened.model.uncertain, isFalse);
        expect(reopened.model.value!.recipientEmpty, isFalse);
        expect((await target.owner.information()).single.id, note.id);
      }, _Http());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a saved native key with unknown server confirmation resumes its original metadata acknowledgement after App restart without another file write',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final root = await f.root.resolveSymbolicLinks();
        final proxy = await OwnerReplyProxy.start(
          tls: f.tls,
          trust: f.trust,
          target: () => f.owner.address,
          serverId: f.owner.serverId,
        );
        addTearDown(proxy.close);
        final picker = SyntheticBackupPicker()..keyOutput = '$root/key-once';
        var c = await _Client.open(f, picker, '$root/device', proxy: proxy);
        await c.model.write(WorkspaceBackupAction.enableKey);
        expect(c.model.failure, isNull);
        await c.pick(WorkspaceBackupPick.keyOutput);
        proxy.dropNextPath = '/v1/owner/backups/outputs/confirm';
        proxy.failPostsAfterDrop = '/v1/owner/backups/outputs/confirm';
        await c.model.write(WorkspaceBackupAction.saveKey);
        expect(c.model.uncertain, isTrue);
        expect(await File(picker.keyOutput!).exists(), isTrue);
        final original = await File(picker.keyOutput!).readAsBytes();
        final modified = await File(picker.keyOutput!).lastModified();
        expect(picker.stages, 1);
        await c.close();
        await f.reopen();
        c = await _Client.open(f, picker, '$root/device', proxy: proxy);
        expect(c.model.uncertain, isTrue);
        await c.model.reconcile();
        expect(c.model.uncertain, isTrue);
        proxy.failPostPrefix = null;
        await c.model.reconcile();
        expect(c.model.failure, isNull);
        expect(c.model.value!.keySaved, isTrue);
        expect(picker.stages, 1);
        expect(picker.keyPicks, 1);
        expect(await File(picker.keyOutput!).readAsBytes(), original);
        expect(await File(picker.keyOutput!).lastModified(), modified);
        expect((await f.repo.backups.pendingOwnerOperations()), isEmpty);
      }, _Http());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'lost restore reply and failed receipt lookup persist the original restore across App and encrypted service restart',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final source = await DeviceCredentialFixture.create();
        addTearDown(source.dispose);
        final sourceRoot = await source.root.resolveSymbolicLinks();
        final note = await source.runtime.run(
          () => source.runtime.service.owner.createInformation('合成旧版资料', '', [
            const core.FieldInput('正文', '', 'SYNTHETIC_RESTORE_ONCE'),
          ]),
        );
        // Existing single-machine-format export through the same original backup
        // implementation; the destination uses only normal App backup controls.
        final key = await source.repo.backups.enable();
        await source.repo.backups.saveRecoveryKeyTo('$sourceRoot/recovery.key');
        await source.runtime.run(
          () => source.runtime.service.owner.exportLibrary(
            () => source.repo.backups.exportTo('$sourceRoot/archive.aimbackup'),
          ),
        );
        expect(key, isNotEmpty);
        final f = await DeviceCredentialFixture.create();
        addTearDown(f.dispose);
        final root = await f.root.resolveSymbolicLinks();
        final proxy = await OwnerReplyProxy.start(
          tls: f.tls,
          trust: f.trust,
          target: () => f.owner.address,
          serverId: f.owner.serverId,
        );
        addTearDown(proxy.close);
        final picker = SyntheticBackupPicker()
          ..archiveInput = '$sourceRoot/archive.aimbackup'
          ..keyInput = '$sourceRoot/recovery.key';
        var c = await _Client.open(f, picker, '$root/device', proxy: proxy);
        await c.pick(WorkspaceBackupPick.archiveInput);
        await c.pick(WorkspaceBackupPick.keyInput);
        await c.model.inspect();
        expect(c.model.canRestore, isTrue);
        proxy.dropNextPath = '/v1/owner/backups/changes';
        proxy.failGetsAfterDrop = '/v1/owner/backups/operations/';
        await c.model.write(WorkspaceBackupAction.restore);
        expect(c.model.uncertain, isTrue);
        expect((await f.owner.information()).single.id, note.id);
        final posts = proxy.requests['POST /v1/owner/backups/changes'];
        expect(posts, 1);
        await c.model.write(WorkspaceBackupAction.restore);
        expect(proxy.requests['POST /v1/owner/backups/changes'], posts);
        await c.close();
        await f.reopen();
        c = await _Client.open(f, picker, '$root/device', proxy: proxy);
        expect(c.model.uncertain, isTrue);
        await c.model.reconcile();
        expect(c.model.uncertain, isTrue);
        proxy.failGetPrefix = null;
        await c.model.reconcile();
        expect(c.model.failure, isNull);
        expect(c.model.result!.action, WorkspaceBackupAction.restore);
        expect(proxy.requests['POST /v1/owner/backups/changes'], posts);
        expect(
          (await f.owner.information()).single.fields.single.value,
          'SYNTHETIC_RESTORE_ONCE',
        );
      }, _Http());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
