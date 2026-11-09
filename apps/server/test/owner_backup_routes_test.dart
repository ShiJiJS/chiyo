import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/backup_transport.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

class _PortableFixture {
  _PortableFixture(
    this.file,
    this.key,
    this.item,
    this.firstFile,
    this.secondFile,
    this.fileBytes,
    this.credential,
    this.sourceToken,
    this.sourceField,
  );
  final File file;
  final String key, credential, sourceToken;
  final InformationItem item;
  final InformationAttachmentRef firstFile, secondFile;
  final Uint8List fileBytes;
  final FieldRef sourceField;

  static Future<_PortableFixture> create(Directory root) async {
    await initializeServerSecrets('${root.path}/old-secrets');
    final source = await EncryptedInformationRepository.open(
      '${root.path}/old-single-machine',
      MountedDatabaseKeyStore('${root.path}/old-secrets/database.key'),
    );
    final old = InformationService(repository: source);
    try {
      final dir = await old.owner.createDirectory('Synthetic servers');
      final tag = await old.owner.createTag('Synthetic local');
      final initial = await old.owner.createInformation(
        'Synthetic server',
        '',
        [const FieldInput('Address', '', 'SYNTHETIC_BEFORE')],
      );
      final field = FieldRef(initial.id, initial.fields.single.id);
      await old.owner.correctValue(field, 'SYNTHETIC_AFTER');
      await old.owner.organizeInformation(
        initial.id,
        directoryId: dir.id,
        tagIds: [tag.id],
      );
      final item = old.owner.information.single;
      final bytes = Uint8List.fromList(List.generate(700000, (i) => i % 251));
      Future<InformationItem> save(
        List<int> bytes,
        InformationItem? before,
      ) async {
        final draft = await old.owner.beginInformationFileDraft();
        try {
          final stage = await old.owner.stageInformationBytes(
            draft,
            originalName: 'synthetic.bin',
            bytes: Uint8List.fromList(bytes),
          );
          return await old.owner.commitInformationDraft(
            draft,
            before == null ? 'file-one' : 'file-two',
            InformationDraftInput(
              name: 'Synthetic attachment',
              description: '',
              itemId: before?.id,
              baseVersion: before?.version,
              fields: [
                InformationDraftField.stagedFile(
                  'File',
                  '',
                  stage.id,
                  fieldId: before?.fields.single.id,
                ),
              ],
            ),
          );
        } finally {
          await old.owner.releaseInformationFileDraft(draft);
        }
      }

      final first = await save(bytes, null);
      final second = await save([0, 128, 255, 10], first);
      final credential = await old.owner.createStringCredential(
        name: 'Synthetic password',
        publicPurpose: '',
        secret: 'SYNTHETIC_PASSWORD',
      );
      await old.owner.setCredentialLinks(credential.id, credential.revision, [
        item.id,
      ]);
      final session = old.agent.openSession('Old single-machine chat');
      final request = old.agent.request(session, 'Synthetic read', [field]);
      old.owner.approve(request.id, [field]);
      final token = old.agent.claim(session, request.id).token;
      expect(await old.agent.read(token, field), 'SYNTHETIC_AFTER');
      old.agent.request(session, 'Pending excluded from portable backup', [
        field,
      ]);
      final key = await source.backups.enable();
      await source.backups.saveRecoveryKeyTo(
        '${root.path}/independent-source-key',
      );
      final file = File('${root.path}/合成旧版完整备份.aimbackup');
      await old.owner.exportLibrary(() => source.backups.exportTo(file.path));
      return _PortableFixture(
        file,
        key,
        item,
        first.fields.single.attachment!,
        second.fields.single.attachment!,
        bytes,
        credential.id,
        token,
        field,
      );
    } finally {
      await old.close();
      await source.close();
    }
  }
}

class _Uploaded {
  const _Uploaded(this.id, this.resource, this.key);
  final String id;
  final WorkspaceBackupResource resource, key;
}

Future<_Uploaded> _upload(
  OwnerClient owner,
  File file, {
  String id = 'archive-upload',
}) async {
  final bytes = await file.readAsBytes();
  final resource = WorkspaceBackupResource(
    id: id,
    name: file.uri.pathSegments.last,
    kind: WorkspaceBackupPick.archiveInput,
  );
  final begin = {
    'wireVersion': 1,
    'uploadId': id,
    'resource': resource.json,
    'byteLength': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
  await owner.request('POST', '/v1/owner/backups/uploads', begin);
  var offset = 0;
  while (offset < bytes.length) {
    final end = (offset + 512 * 1024).clamp(0, bytes.length);
    final chunk = {
      'wireVersion': 1,
      'offset': offset,
      'bytes': base64Encode(bytes.sublist(offset, end)),
    };
    final result = await owner.request(
      'POST',
      '/v1/owner/backups/uploads/$id/chunks',
      chunk,
    );
    expect(result['received'], end);
    // A lost upload response may safely resend only the identical range.
    if (offset == 0) {
      final again = await owner.request(
        'POST',
        '/v1/owner/backups/uploads/$id/chunks',
        chunk,
      );
      expect(again, result);
    }
    offset = end;
  }
  expect(
    (await owner.request(
      'POST',
      '/v1/owner/backups/uploads',
      begin,
    ))['received'],
    bytes.length,
  );
  return _Uploaded(
    id,
    resource,
    const WorkspaceBackupResource(
      id: 'synthetic-key',
      name: 'recovery.txt',
      kind: WorkspaceBackupPick.keyInput,
    ),
  );
}

Future<WorkspaceBackupPreview> _inspect(
  OwnerClient owner,
  _Uploaded u,
  String key,
) async => backupPreviewFromJson(
  await owner.request('POST', '/v1/owner/backups/inspect', {
    'wireVersion': 1,
    'uploadId': u.id,
    'archive': u.resource.json,
    'key': u.key.json,
    'recoveryKey': key,
  }),
);

Matcher remoteFails(String code) =>
    throwsA(isA<RemoteFailure>().having((e) => e.code, 'code', code));

void main() {
  test(
    'normal Owner TLS restore migrates original single-device bytes and keeps new server live without old identities',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final source = await _PortableFixture.create(f.root);
      // This Agent identity is currently valid; it still cannot inspect or
      // restore Owner backups. Test before restoration revokes the identity.
      final agentHttp = HttpClient(context: f.trust);
      try {
        final request = await agentHttp.getUrl(
          f.owner.address.resolve('/v1/owner/backups'),
        );
        request.headers.set(
          'authorization',
          'Bearer ${f.profiles.first.deviceToken}',
        );
        final response = await request.close();
        expect(response.statusCode, 401);
        await response.drain<void>();
      } finally {
        agentHttp.close(force: true);
      }
      final before = await f.repo.openServerState();
      final scope = f.runtime.service.owner.captureLibraryScope();
      // Warm the real projections; restore must replace those exact old scopes.
      await f.owner.request('GET', '/v1/owner/catalog');
      await f.owner.request('POST', '/v1/owner/approvals/query', {
        'offset': 0,
        'limit': 25,
      });
      final oldChat = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Old target chat',
      });
      final uploaded = await _upload(f.owner, source.file);
      final p = await _inspect(f.owner, uploaded, source.key);
      expect(p.counts[WorkspaceBackupCategory.files], 2);
      expect(p.counts[WorkspaceBackupCategory.credentials], 1);
      expect(p.counts[WorkspaceBackupCategory.directories], 1);
      final version = backupStatusFromJson(
        await f.owner.request('GET', '/v1/owner/backups'),
      ).version;
      final c = WorkspaceBackupChange(
        operationId: 'restore-once',
        action: WorkspaceBackupAction.restore,
        expectedVersion: version,
        selection: p.archive,
        previewToken: p.token,
      );
      final restored = backupReceiptFromJson(
        await f.owner.request(
          'POST',
          '/v1/owner/backups/changes',
          backupChangeToJson(c),
        ),
      );
      expect(restored.matches(c), isTrue);
      expect(scope.isCurrent, isFalse);
      expect(
        (await f.repo.openServerState()).generation,
        isNot(before.generation),
      );
      expect(await f.owner.information(), hasLength(2));
      expect(
        informationToJson(
          f.runtime.service.owner.information.singleWhere(
            (i) => i.id == source.item.id,
          ),
        ),
        informationToJson(source.item),
      );
      expect(f.runtime.service.owner.credentials.single.id, source.credential);
      expect(f.runtime.service.owner.credentials.single.linkedItemIds, [
        source.item.id,
      ]);
      expect(
        f.repo.credentialMaterials.single.bytes,
        utf8.encode('SYNTHETIC_PASSWORD'),
      );
      expect(
        (await f.runtime.service.owner.readInformationAttachment(
          source.firstFile,
        )).bytes,
        source.fileBytes,
      );
      expect(
        (await f.runtime.service.owner.readInformationAttachment(
          source.secondFile,
        )).bytes,
        [0, 128, 255, 10],
      );
      expect(
        (await f.runtime.service.owner.history()).grants.every(
          (g) => !g.active,
        ),
        isTrue,
      );
      await expectLater(
        f.runtime.run(
          () => f.runtime.service.agent.read(
            source.sourceToken,
            source.sourceField,
          ),
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        (await f.agents.first.call('/session/lifecycle', {
          'chatLabel': 'Old target identity',
        }))['status'],
        'unauthorized',
      );
      expect(oldChat['sessionSecret'], isNotNull);
      expect(
        (await f.owner.request('GET', '/v1/owner/devices'))['devices'],
        isEmpty,
      );
      final catalog = await f.owner.request('GET', '/v1/owner/catalog');
      expect(catalog['directories'], isNotEmpty);
      final inbox = approvalResultsFromJson(
        await f.owner.request('POST', '/v1/owner/approvals/query', {
          'filter': 'pending',
        }),
      );
      expect(inbox.pending, 0);
      expect(inbox.items, isEmpty);
      // An exact retry reads the old receipt without invalidating a new identity.
      final newDevice = await f.owner.request('POST', '/v1/owner/devices', {
        'operationId': 'after-restore-device',
        'name': 'New target device',
      });
      final newAgent = AgentConnection(
        AgentConnectionProfile(
          address: f.owner.address,
          serverId: f.owner.serverId,
          deviceToken: newDevice['deviceToken'] as String,
          certificate: f.certificate,
        ),
      );
      try {
        expect((await newAgent.call('/plugins/catalog', {}))['status'], 'ok');
        final templates = await newAgent.call('/templates/catalog', {});
        expect(templates['status'], 'ok');
        expect(templates['templates'], isNotEmpty);
        final first = (templates['templates'] as List).first as Map;
        expect(
          (await newAgent.call('/templates/read', {
            'templateId': first['id'],
          }))['status'],
          'ok',
        );
      } finally {
        newAgent.close();
      }
      final after = (await f.repo.openServerState()).generation;
      final duplicate = backupReceiptFromJson(
        await f.owner.request(
          'POST',
          '/v1/owner/backups/changes',
          backupChangeToJson(c),
        ),
      );
      expect(backupReceiptToJson(duplicate), backupReceiptToJson(restored));
      expect((await f.repo.openServerState()).generation, after);
      expect(
        (await f.owner.request('GET', '/v1/owner/devices'))['devices'],
        hasLength(1),
      );
      final snapshot = jsonEncode((await f.repo.openServerState()).payload);
      expect(snapshot.contains(source.key), isFalse);
      expect(snapshot.contains('SYNTHETIC_PASSWORD'), isFalse);
      await f.reopen();
      expect(await f.owner.information(), hasLength(2));
      final recovered = backupReceiptFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/backups/operations/${c.operationId}',
        ),
      );
      expect(recovered.matches(c), isTrue);
      expect(
        (await f.runtime.service.owner.readInformationAttachment(
          source.firstFile,
        )).bytes,
        source.fileBytes,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'bad keys, unauthorized callers, nonempty target and transactional restore failure preserve original data and identity',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final source = await _PortableFixture.create(f.root);
      final corrupt = File('${f.root.path}/corrupt.aimbackup');
      await corrupt.writeAsBytes(List.filled(4096, 0));
      final corruptUpload = await _upload(
        f.owner,
        corrupt,
        id: 'corrupt-input',
      );
      await expectLater(
        _inspect(f.owner, corruptUpload, source.key),
        remoteFails('invalid_backup'),
      );
      final u = await _upload(f.owner, source.file);
      final original = await source.file.readAsBytes();
      await expectLater(
        f.owner.request('POST', '/v1/owner/backups/uploads/${u.id}/chunks', {
          'wireVersion': 1,
          'offset': 0,
          'bytes': base64Encode([original.first ^ 1]),
        }),
        remoteFails('operation_conflict'),
      );
      await expectLater(
        _inspect(
          f.owner,
          u,
          'aim-recovery-v1:${base64UrlEncode(List.filled(32, 0))}',
        ),
        remoteFails('invalid_backup'),
      );
      expect(f.runtime.service.owner.information, isEmpty);
      final state = await f.repo.openServerState();
      final p = await _inspect(f.owner, u, source.key);
      final version = backupStatusFromJson(
        await f.owner.request('GET', '/v1/owner/backups'),
      ).version;
      final c = WorkspaceBackupChange(
        operationId: 'failed-restore',
        action: WorkspaceBackupAction.restore,
        expectedVersion: version,
        selection: p.archive,
        previewToken: p.token,
      );
      Future<void> sql(String statement) async {
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

      await sql(
        "CREATE TRIGGER fail_portable_restore BEFORE INSERT ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='restore' BEGIN SELECT RAISE(ABORT,'synthetic restore failure'); END",
      );
      await expectLater(
        f.owner.request(
          'POST',
          '/v1/owner/backups/changes',
          backupChangeToJson(c),
        ),
        remoteFails('backup_restore_failed'),
      );
      expect(f.runtime.service.owner.information, isEmpty);
      expect((await f.repo.openServerState()).generation, state.generation);
      expect(
        (await f.owner.request('GET', '/v1/owner/devices'))['devices'],
        hasLength(2),
      );
      await expectLater(
        f.owner.request('GET', '/v1/owner/backups/operations/${c.operationId}'),
        remoteFails('operation_not_found'),
      );
      await sql('DROP TRIGGER fail_portable_restore');
      final p2 = await _inspect(f.owner, u, source.key);
      final retry = WorkspaceBackupChange(
        operationId: 'explicit-new-restore',
        action: c.action,
        expectedVersion: version,
        selection: p2.archive,
        previewToken: p2.token,
      );
      expect(
        backupReceiptFromJson(
          await f.owner.request(
            'POST',
            '/v1/owner/backups/changes',
            backupChangeToJson(retry),
          ),
        ).matches(retry),
        isTrue,
      );
      final u2 = await _upload(f.owner, source.file, id: 'second-import');
      await expectLater(
        _inspect(f.owner, u2, source.key),
        remoteFails('recipient_not_empty'),
      );
      expect(await f.owner.information(), hasLength(2));
      final raw = HttpClient(context: f.trust);
      try {
        final request = await raw.getUrl(
          f.owner.address.resolve('/v1/owner/backups'),
        );
        request.headers.set(
          'authorization',
          'Bearer ${f.profiles.first.deviceToken}',
        );
        final response = await request.close();
        expect(response.statusCode, 401);
        await response.drain<void>();
      } finally {
        raw.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
