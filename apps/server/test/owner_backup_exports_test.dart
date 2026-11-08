import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/backup_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';
import 'support/owner_reply_proxy.dart';

const base = '/v1/owner/backups';
Matcher fails(String code) =>
    throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', code));

Future<WorkspaceBackupStatus> status(OwnerClient owner) async =>
    backupStatusFromJson(await owner.request('GET', base));
WorkspaceBackupChange output(
  String id,
  WorkspaceBackupAction action,
  int version,
) => WorkspaceBackupChange(
  operationId: id,
  action: action,
  expectedVersion: version,
  selection: WorkspaceBackupResource(
    id: 'selection_$id',
    name: action == WorkspaceBackupAction.saveKey
        ? 'recovery.txt'
        : '$id.aimbackup',
    kind: action == WorkspaceBackupAction.saveKey
        ? WorkspaceBackupPick.keyOutput
        : WorkspaceBackupPick.archiveOutput,
  ),
);
Future<Map<String, dynamic>> enable(OwnerClient owner) async {
  final c = WorkspaceBackupChange(
    operationId: 'enable',
    action: WorkspaceBackupAction.enableKey,
    expectedVersion: (await status(owner)).version,
  );
  expect(
    backupReceiptFromJson(
      await owner.request('POST', '$base/changes', backupChangeToJson(c)),
    ).matches(c),
    isTrue,
  );
  expect((await status(owner)).keySaved, isFalse);
  return owner.request('GET', '$base/recovery-key');
}

Future<WorkspaceBackupReceipt> confirm(
  OwnerClient owner,
  WorkspaceBackupChange c,
  String digest,
) async => backupReceiptFromJson(
  await owner.request('POST', '$base/outputs/confirm', {
    'wireVersion': 1,
    'change': backupChangeToJson(c),
    'sha256': digest,
  }),
);
Future<WorkspaceBackupTransfer> prepare(
  OwnerClient owner,
  WorkspaceBackupChange c,
) async => backupTransferFromJson(
  await owner.request('POST', '$base/exports', backupChangeToJson(c)),
);
Future<List<int>> download(
  OwnerClient owner,
  WorkspaceBackupTransfer transfer,
) async {
  final builder = BytesBuilder();
  var offset = 0;
  while (offset < transfer.byteLength) {
    final length = (transfer.byteLength - offset).clamp(1, 512 * 1024);
    final r = await owner.request(
      'POST',
      '$base/exports/${transfer.command.operationId}/chunks',
      {'wireVersion': 1, 'offset': offset, 'length': length},
    );
    expect(r['wireVersion'], 1);
    expect(r['offset'], offset);
    expect(r['sha256'], transfer.sha256);
    expect(r['byteLength'], transfer.byteLength);
    final chunk = base64Decode(r['bytes'] as String);
    expect(chunk.length, length);
    builder.add(chunk);
    offset += length;
  }
  final bytes = builder.takeBytes();
  expect(sha256.convert(bytes).toString(), transfer.sha256);
  return bytes;
}

Future<void> sql(DeviceCredentialFixture f, String statement) async {
  final key = await MountedDatabaseKeyStore(
    '${f.root.path}/secrets/database.key',
  ).read();
  final db = sqlite3.open('${f.root.path}/data/library.db');
  try {
    db.execute(
      'PRAGMA key = "x\'${key!.map((n) => n.toRadixString(16).padLeft(2, '0')).join()}\'"',
    );
    db.execute(statement);
  } finally {
    db.close();
  }
}

void main() {
  test(
    'real TLS encrypted export preserves the original snapshot across response loss, server restart and independent restore',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final note = await f.runtime.run(
        () => f.runtime.service.owner.createInformation(
          'Synthetic export',
          '',
          [const FieldInput('Body', '', 'SYNTHETIC_EXPORT_ORIGINAL')],
        ),
      );
      final owner = f.runtime.service.owner;
      final oldBytes = Uint8List.fromList(
        List.generate(700000, (i) => i % 251),
      );
      Future<InformationItem> file(
        List<int> bytes,
        InformationItem? previous,
      ) => f.runtime.run(() async {
        final draft = await owner.beginInformationFileDraft();
        try {
          final staged = await owner.stageInformationBytes(
            draft,
            originalName: 'synthetic.bin',
            bytes: Uint8List.fromList(bytes),
          );
          return await owner.commitInformationDraft(
            draft,
            previous == null ? 'file-one' : 'file-two',
            InformationDraftInput(
              itemId: previous?.id,
              baseVersion: previous?.version,
              name: 'Synthetic file',
              description: '',
              fields: [
                InformationDraftField.stagedFile(
                  'File',
                  '',
                  staged.id,
                  fieldId: previous?.fields.single.id,
                ),
              ],
            ),
          );
        } finally {
          await owner.releaseInformationFileDraft(draft);
        }
      });
      final first = await file(oldBytes, null);
      final second = await file([0, 128, 255, 10], first);
      final credential = await f.runtime.run(
        () => owner.createStringCredential(
          name: 'Synthetic token',
          publicPurpose: '',
          secret: 'SYNTHETIC_EXPORT_PASSWORD',
        ),
      );
      await f.runtime.run(
        () => owner.setCredentialLinks(credential.id, credential.revision, [
          note.id,
        ]),
      );
      final key = await enable(f.owner);
      final keyFile = File('${f.root.path}/device-independent-key');
      await keyFile.create(exclusive: true);
      await keyFile.writeAsString('${key['recoveryKey']}\n', flush: true);
      expect(
        sha256.convert(await keyFile.readAsBytes()).toString(),
        key['sha256'],
      );
      final save = output(
        'save-key',
        WorkspaceBackupAction.saveKey,
        (await status(f.owner)).version,
      );
      expect(
        (await confirm(f.owner, save, key['sha256'] as String)).matches(save),
        isTrue,
      );
      expect((await status(f.owner)).keySaved, isTrue);
      final proxy = await OwnerReplyProxy.start(
        tls: f.tls,
        trust: f.trust,
        target: () => f.owner.address,
        serverId: f.owner.serverId,
      );
      addTearDown(proxy.close);
      final client = await OwnerClient.connect(
        address: proxy.address,
        token: f.token,
        trust: f.trust,
      );
      addTearDown(client.close);
      final c = output(
        'export-once',
        WorkspaceBackupAction.export,
        (await status(client)).version,
      );
      proxy.dropNextPath = '$base/exports';
      await expectLater(prepare(client, c), throwsA(isA<RemoteFailure>()));
      expect(proxy.requests['POST $base/exports'], 1);
      await expectLater(
        client.request('GET', '$base/operations/${c.operationId}'),
        fails('output_pending'),
      );
      proxy.failGetPrefix = '$base/exports/';
      await expectLater(
        client.request('GET', '$base/exports/${c.operationId}'),
        fails('synthetic_unavailable'),
      );
      await f.reopen();
      proxy.failGetPrefix = null;
      final t = backupTransferFromJson(
        await client.request('GET', '$base/exports/${c.operationId}'),
      );
      expect(t.command.digest, c.digest);
      expect(t.phase, 'prepared');
      expect(t.counts[WorkspaceBackupCategory.files], 2);
      expect(t.counts[WorkspaceBackupCategory.credentials], 1);
      expect(await f.repo.backups.pendingOutputCleanupCount(), 0);
      expect(await f.repo.backups.pendingOutputOperationIds(), isEmpty);
      expect(await f.repo.backups.latestExportOperation(), isNull);
      expect(proxy.requests['POST $base/exports'], 1);
      await f.runtime.run(
        () => f.runtime.service.owner.correctValue(
          FieldRef(note.id, note.fields.single.id),
          'SYNTHETIC_CHANGED_AFTER_EXPORT',
        ),
      );
      final duplicate = await prepare(client, c);
      expect(backupTransferToJson(duplicate), backupTransferToJson(t));
      final bytes = await download(client, t);
      expect(
        utf8
            .decode(bytes, allowMalformed: true)
            .contains('SYNTHETIC_EXPORT_PASSWORD'),
        isFalse,
      );
      final archive = File('${f.root.path}/device-backup.aimbackup');
      await archive.create(exclusive: true);
      await archive.writeAsBytes(bytes, flush: true);
      await expectLater(
        confirm(client, c, 'a' * 64),
        fails('operation_conflict'),
      );
      proxy.dropNextPath = '$base/outputs/confirm';
      await expectLater(
        confirm(client, c, t.sha256),
        throwsA(isA<RemoteFailure>()),
      );
      final acknowledged = backupReceiptFromJson(
        await client.request('GET', '$base/operations/${c.operationId}'),
      );
      expect(acknowledged.matches(c), isTrue);
      expect(
        proxy.requests['POST $base/outputs/confirm'],
        2,
      ); // wrong digest plus one real confirmation
      expect((await status(client)).pending, isNull);
      expect((await status(client)).latestArchive!.name, c.selection!.name);
      await expectLater(
        client.request('POST', '$base/exports/${c.operationId}/chunks', {
          'wireVersion': 1,
          'offset': 0,
          'length': 1,
        }),
        fails('backup_transfer_finished'),
      );
      expect(
        (await Directory(
          '${f.root.path}/backup-transfers',
        ).list().toList()).where((e) => e.path.contains('/out-')),
        isEmpty,
      );
      await f.reopen();
      expect(
        backupReceiptFromJson(
          await client.request('GET', '$base/operations/${c.operationId}'),
        ).matches(c),
        isTrue,
      );
      // A separately keyed empty target opens the actual downloaded encrypted
      // backup using only the independently saved recovery material.
      await initializeServerSecrets('${f.root.path}/other-secrets');
      final target = await EncryptedInformationRepository.openOnline(
        '${f.root.path}/other-data',
        MountedDatabaseKeyStore('${f.root.path}/other-secrets/database.key'),
      );
      final runtime = await OnlineInformationRuntime.open(repository: target);
      try {
        final recovery = await target.backups.readRecoveryKeyFrom(keyFile.path);
        final p = await target.backups.inspectRestore(
          path: archive.path,
          recoveryKey: recovery,
          archiveId: 'downloaded',
          archiveVersion: 1,
        );
        await runtime.run(
          () => runtime.service.owner.restoreLibrary(
            () => target.backups.restoreWithReceipt(
              operationId: 'independent-restore',
              commandDigest: 'c' * 64,
              expectedVersion: p.expectedVersion,
              preview: p,
            ),
          ),
        );
        final restored = runtime.service.owner;
        expect(
          restored.information
              .singleWhere((i) => i.id == note.id)
              .fields
              .single
              .value,
          'SYNTHETIC_EXPORT_ORIGINAL',
        );
        expect(
          (await restored.readInformationAttachment(
            first.fields.single.attachment!,
          )).bytes,
          oldBytes,
        );
        expect(
          (await restored.readInformationAttachment(
            second.fields.single.attachment!,
          )).bytes,
          [0, 128, 255, 10],
        );
        expect(
          target.credentialMaterials.single.bytes,
          utf8.encode('SYNTHETIC_EXPORT_PASSWORD'),
        );
        expect(restored.credentials.single.linkedItemIds, [note.id]);
        expect(await target.backups.remoteOutputs(), isEmpty);
        expect(
          (await target.openServerState()).payload.toString().contains(
            'recoveryKey',
          ),
          isFalse,
        );
      } finally {
        await runtime.close();
        await target.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'independent key confirmation is atomic; failed or abandoned exports never become saved files',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final key = await enable(f.owner);
      final save = output(
        'save-key-fault',
        WorkspaceBackupAction.saveKey,
        (await status(f.owner)).version,
      );
      await sql(
        f,
        "CREATE TRIGGER fail_remote_backup BEFORE INSERT ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='remoteOutput' BEGIN SELECT RAISE(ABORT,'synthetic remote backup failure'); END",
      );
      await expectLater(
        confirm(f.owner, save, key['sha256'] as String),
        throwsA(isA<RemoteFailure>()),
      );
      expect((await status(f.owner)).keySaved, isFalse);
      expect((await status(f.owner)).version, save.expectedVersion);
      await expectLater(
        f.owner.request('GET', '$base/operations/${save.operationId}'),
        fails('operation_not_found'),
      );
      await sql(f, 'DROP TRIGGER fail_remote_backup');
      await expectLater(
        confirm(f.owner, save, key['sha256'] as String),
        fails('not_submitted'),
      );
      final saved = output(
        'save-key-explicit-retry',
        WorkspaceBackupAction.saveKey,
        save.expectedVersion,
      );
      expect(
        (await confirm(f.owner, saved, key['sha256'] as String)).matches(saved),
        isTrue,
      );
      final failedExport = output(
        'export-transaction-fault',
        WorkspaceBackupAction.export,
        (await status(f.owner)).version,
      );
      await sql(
        f,
        "CREATE TRIGGER fail_remote_backup BEFORE INSERT ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='remoteOutput' BEGIN SELECT RAISE(ABORT,'synthetic export manifest failure'); END",
      );
      await expectLater(
        prepare(f.owner, failedExport),
        throwsA(isA<RemoteFailure>()),
      );
      expect((await status(f.owner)).version, failedExport.expectedVersion);
      expect((await status(f.owner)).latestArchive, isNull);
      await expectLater(
        f.owner.request('GET', '$base/operations/${failedExport.operationId}'),
        fails('operation_not_found'),
      );
      await sql(f, 'DROP TRIGGER fail_remote_backup');
      await expectLater(prepare(f.owner, failedExport), fails('not_submitted'));
      final cleanup = WorkspaceBackupChange(
        operationId: 'cleanup-failed-export',
        action: WorkspaceBackupAction.cleanup,
        expectedVersion: (await status(f.owner)).version,
      );
      expect(
        backupReceiptFromJson(
          await f.owner.request(
            'POST',
            '$base/changes',
            backupChangeToJson(cleanup),
          ),
        ).matches(cleanup),
        isTrue,
      );
      expect(
        (await Directory(
          '${f.root.path}/backup-transfers',
        ).list().toList()).where((e) => e.path.contains('/out-')),
        isEmpty,
      );
      final c = output(
        'export-abandoned',
        WorkspaceBackupAction.export,
        (await status(f.owner)).version,
      );
      final t = await prepare(f.owner, c);
      await f.owner.request('POST', '$base/outputs/abandon', {
        'wireVersion': 1,
        'change': backupChangeToJson(c),
        'sha256': t.sha256,
      });
      await expectLater(
        f.owner.request('GET', '$base/operations/${c.operationId}'),
        fails('backup_not_published'),
      );
      await expectLater(
        confirm(f.owner, c, t.sha256),
        fails('operation_conflict'),
      );
      expect((await status(f.owner)).latestArchive, isNull);
      expect((await status(f.owner)).pending, isNull);
      await f.reopen();
      await expectLater(
        f.owner.request('GET', '$base/operations/${c.operationId}'),
        fails('backup_not_published'),
      );
      final next = output(
        'export-after-abandon',
        WorkspaceBackupAction.export,
        (await status(f.owner)).version,
      );
      final good = await prepare(f.owner, next);
      final record = (await f.repo.backups.remoteOutputs())
          .where((r) => r.operationId == next.operationId)
          .single;
      final path =
          '${f.root.path}/backup-transfers/out-${record.artifactId}/archive';
      await File(path).writeAsBytes([1, 2, 3], flush: true);
      await expectLater(
        f.owner.request('POST', '$base/exports/${next.operationId}/chunks', {
          'wireVersion': 1,
          'offset': 0,
          'length': 1,
        }),
        fails('backup_changed'),
      );
      expect(
        (backupTransferFromJson(
          await f.owner.request('GET', '$base/exports/${next.operationId}'),
        )).sha256,
        good.sha256,
      );
      expect(f.runtime.service.owner.information, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'restart reclaims old input folders and a new export reclaims unpublished orphan snapshots without removing unrelated directories',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final root = Directory('${f.root.path}/backup-transfers');
      final incoming = Directory('${root.path}/incoming-synthetic-old');
      await incoming.create();
      await File('${incoming.path}/archive').writeAsBytes(List.filled(4096, 0));
      final orphan = Directory('${root.path}/out-${'d' * 64}');
      await orphan.create();
      await File('${orphan.path}/archive').writeAsBytes(List.filled(4096, 0));
      final unrelated = Directory('${root.path}/unrelated');
      await unrelated.create();
      await f.reopen();
      await status(f.owner);
      expect(await incoming.exists(), isFalse);
      expect(
        await orphan.exists(),
        isTrue,
      ); // short crash grace, no false saved receipt
      expect(await unrelated.exists(), isTrue);
      final key = await enable(f.owner);
      final c = output(
        'independent-key',
        WorkspaceBackupAction.saveKey,
        (await status(f.owner)).version,
      );
      await confirm(f.owner, c, key['sha256'] as String);
      final exported = output(
        'after-orphan',
        WorkspaceBackupAction.export,
        (await status(f.owner)).version,
      );
      final t = await prepare(f.owner, exported);
      expect(t.phase, 'prepared');
      expect(await orphan.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      expect((await download(f.owner, t)).length, t.byteLength);
    },
  );
}
