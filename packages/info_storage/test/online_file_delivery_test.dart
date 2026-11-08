import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late OnlineInformationRuntime runtime;
  late DateTime now;
  late InformationItem item;
  final bytes = Uint8List.fromList(
    utf8.encode('SYNTHETIC_APPROVED_FILE_ORIGINAL'),
  );
  Future<void> open() async {
    repo = await EncryptedInformationRepository.openOnline(root.path, keys);
    runtime = await OnlineInformationRuntime.open(
      repository: repo,
      clock: () => now,
    );
  }

  Future<void> reopen() async {
    await runtime.close();
    await repo.close();
    await open();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('online-file-delivery-');
    keys = TestKeyStore();
    now = DateTime.utc(2026, 11, 8);
    await open();
    item = await runtime.run(() async {
      final owner = runtime.service.owner;
      final draft = await owner.beginInformationFileDraft();
      try {
        final a = await owner.stageInformationBytes(
          draft,
          originalName: 'synthetic.txt',
          mediaType: 'text/plain',
          bytes: bytes,
        );
        final b = await owner.stageInformationBytes(
          draft,
          originalName: 'unapproved.txt',
          bytes: Uint8List.fromList([1, 2, 3]),
        );
        return await owner.commitInformationDraft(
          draft,
          'seed',
          InformationDraftInput(
            name: 'Synthetic file information',
            description: '',
            fields: [
              InformationDraftField.stagedFile('Approved file', '', a.id),
              InformationDraftField.stagedFile('Unapproved file', '', b.id),
            ],
          ),
        );
      } finally {
        await owner.releaseInformationFileDraft(draft);
      }
    });
  });
  tearDown(() async {
    await runtime.close();
    await repo.close();
    await root.delete(recursive: true);
  });
  Matcher fails(String code) => throwsA(
    isA<InformationFileFailure>().having((e) => e.code, 'code', code),
  );
  Map<String, dynamic> manifest(Map<String, Object?> reply) =>
      Map<String, dynamic>.from(reply['delivery'] as Map);
  InformationFileFetchInput input(
    String request, {
    String op = 'fetch',
    int field = 0,
  }) => InformationFileFetchInput.fromJson({
    'protocolVersion': 2,
    'command': 'file-fetch',
    'operationId': op,
    'requestId': request,
    'itemId': item.id,
    'fieldId': item.fields[field].id,
  });
  Future<(OpenedSession, String)> requested({bool approve = true}) async {
    final session = await runtime.run(
      () =>
          runtime.service.agent.openSessionWithEndCapability('Synthetic chat'),
    );
    final request = await runtime.run(
      () => runtime.service.agent.request(
        session.sessionSecret,
        'Synthetic ordinary file use',
        item.fields.map((f) => FieldRef(item.id, f.id)).toList(),
      ),
    );
    if (approve)
      await runtime.run(() async {
        runtime.service.owner.approve(request.id, [
          FieldRef(item.id, item.fields.first.id),
        ], lifetime: const Duration(minutes: 10));
        await runtime.service.owner.retryAuditStorage();
      });
    return (session, request.id);
  }

  test(
    'older device records acquire a stable cleanup-only proof without changing the operation',
    () async {
      final (session, request) = await requested();
      final first = manifest(
        await runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            session.sessionSecret,
            input(request),
          ),
        ),
      );
      final id = first['deliveryId'] as String;
      await runtime.close();
      await repo.close();
      final db = sqlite3.open('${root.path}/library.db');
      try {
        final key = keys.key!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        db.execute('PRAGMA key = "x\'$key\'"');
        final payload =
            jsonDecode(
                  db.select(
                        'SELECT payload FROM information_deliveries WHERE id=?',
                        [id],
                      ).single['payload']
                      as String,
                )
                as Map<String, dynamic>;
        payload.remove('cleanupCapability');
        db.execute('UPDATE information_deliveries SET payload=? WHERE id=?', [
          jsonEncode(payload),
          id,
        ]);
        db.execute('PRAGMA user_version=54');
      } finally {
        db.close();
      }
      await open();
      final upgraded = manifest(
        await runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            session.sessionSecret,
            input(request),
          ),
        ),
      );
      expect(upgraded['deliveryId'], id);
      expect(upgraded['expiresAt'], first['expiresAt']);
      expect(upgraded['cleanupCapability'], isA<String>());
      final record = runtime.service.owner.informationFileDeliveries.single;
      await expectLater(
        repo.saveInformationFileDelivery(
          record.changed({'cleanupCapability': 'B' * 43}),
        ),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'delivery_conflict',
          ),
        ),
      );
      await reopen();
      expect(
        manifest(
          await runtime.run(
            () => runtime.service.agent.fetchInformationFile(
              session.sessionSecret,
              input(request),
            ),
          ),
        ),
        upgraded,
      );
    },
  );

  test(
    'online delivery reuses approved scope, exact original and original operation without a host path',
    () async {
      final (session, request) = await requested(approve: false);
      final secret = session.sessionSecret;
      await expectLater(
        runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            secret,
            input(request),
          ),
        ),
        fails('not_authorized'),
      );
      await runtime.run(() async {
        runtime.service.owner.approve(request, [
          FieldRef(item.id, item.fields.first.id),
        ], lifetime: const Duration(minutes: 10));
        await runtime.service.owner.retryAuditStorage();
      });
      await expectLater(
        runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            secret,
            input(request, field: 1),
          ),
        ),
        fails('not_authorized'),
      );
      final first = manifest(
        await runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            secret,
            input(request),
          ),
        ),
      );
      expect(first['state'], 'preparing');
      expect(first['deviceDelivery'], true);
      expect(first, isNot(contains('path')));
      expect(first, isNot(contains('bytes')));
      final id = first['deliveryId'] as String;
      final deadline = first['expiresAt'];
      expect(
        runtime.service.owner.informationFileDeliveries.single.lease,
        isNull,
      );
      expect(
        runtime.service.owner.informationFileDeliveries.single.holdsCopy,
        true,
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            secret,
            input(request, field: 1),
          ),
        ),
        fails('operation_conflict'),
      );
      final other = await requested();
      await expectLater(
        runtime.run(
          () => runtime.service.agent.downloadDeviceInformationFile(
            other.$1.sessionSecret,
            id,
          ),
        ),
        fails('not_authorized'),
      );
      final body = await runtime.run(
        () => runtime.service.agent.downloadDeviceInformationFile(secret, id),
      );
      expect(base64Decode(body['bytes'] as String), bytes);
      expect(manifest(body)['sha256'], sha256.convert(bytes).toString());
      await reopen();
      final pending = manifest(
        await runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            secret,
            input(request),
          ),
        ),
      );
      expect(pending['deliveryId'], id);
      expect(pending['state'], 'preparing');
      expect(pending['expiresAt'], deadline);
      await expectLater(
        runtime.run(
          () => runtime.service.agent.completeDeviceInformationFile(
            secret,
            id,
            bytes.length,
            '0' * 64,
          ),
        ),
        fails('attachment_integrity_failed'),
      );
      final done = manifest(
        await runtime.run(
          () => runtime.service.agent.completeDeviceInformationFile(
            secret,
            id,
            bytes.length,
            sha256.convert(bytes).toString(),
          ),
        ),
      );
      expect(done['state'], 'ready');
      expect(done, isNot(contains('path')));
      await reopen();
      expect(
        manifest(
          await runtime.run(
            () => runtime.service.agent.fetchInformationFile(
              secret,
              input(request),
            ),
          ),
        ),
        done,
      );
      expect(
        base64Decode(
          (await runtime.run(
                () => runtime.service.agent.downloadDeviceInformationFile(
                  secret,
                  id,
                ),
              ))['bytes']
              as String,
        ),
        bytes,
      );
      expect(runtime.service.owner.informationFileDeliveries, hasLength(1));
      final record = runtime.service.owner.informationFileDeliveries.single;
      final archive = record.toArchiveJson();
      expect(archive, isNot(contains('deviceDelivery')));
      expect(archive, isNot(contains('lease')));
      expect(archive, isNot(contains('cleanupCapability')));
      expect(
        InformationFileDelivery.fromArchiveJson(
          Map<String, dynamic>.from(archive),
        ).runtime,
        false,
      );
      final db = sqlite3.open('${root.path}/library.db');
      try {
        final key = keys.key!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        db.execute('PRAGMA key = "x\'$key\'"');
        expect(db.select('PRAGMA user_version').single.values.single, 55);
      } finally {
        db.close();
      }
    },
  );

  test(
    'replacement preserves old operation bytes while a new operation gets the current version under the original field grant',
    () async {
      final (session, request) = await requested();
      final secret = session.sessionSecret;
      final before = manifest(
        await runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            secret,
            input(request),
          ),
        ),
      );
      final id = before['deliveryId'] as String;
      await runtime.run(
        () => runtime.service.agent.completeDeviceInformationFile(
          secret,
          id,
          bytes.length,
          sha256.convert(bytes).toString(),
        ),
      );
      final nextBytes = Uint8List.fromList(
        utf8.encode('REPLACED_SYNTHETIC_FILE_ORIGINAL'),
      );
      item = await runtime.run(() async {
        final owner = runtime.service.owner;
        final draft = await owner.beginInformationFileDraft();
        try {
          final stage = await owner.stageInformationBytes(
            draft,
            originalName: 'replacement.txt',
            mediaType: 'text/plain',
            bytes: nextBytes,
          );
          return await owner.commitInformationDraft(
            draft,
            'replace',
            InformationDraftInput(
              name: item.name,
              description: '',
              itemId: item.id,
              baseVersion: item.version,
              fields: [
                InformationDraftField.stagedFile(
                  'Approved file',
                  '',
                  stage.id,
                  fieldId: item.fields.first.id,
                ),
                InformationDraftField.retainedFile(
                  'Unapproved file',
                  '',
                  item.fields[1].attachment,
                  fieldId: item.fields[1].id,
                ),
              ],
            ),
          );
        } finally {
          await owner.releaseInformationFileDraft(draft);
        }
      });
      await reopen();
      final duplicate = manifest(
        await runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            secret,
            input(request),
          ),
        ),
      );
      expect(duplicate['deliveryId'], id);
      expect(duplicate['attachmentVersion'], 1);
      expect(
        base64Decode(
          (await runtime.run(
                () => runtime.service.agent.downloadDeviceInformationFile(
                  secret,
                  id,
                ),
              ))['bytes']
              as String,
        ),
        bytes,
      );
      final latest = manifest(
        await runtime.run(
          () => runtime.service.agent.fetchInformationFile(
            secret,
            input(request, op: 'latest'),
          ),
        ),
      );
      expect(latest['attachmentVersion'], 2);
      expect(latest['expiresAt'], before['expiresAt']);
      expect(
        base64Decode(
          (await runtime.run(
                () => runtime.service.agent.downloadDeviceInformationFile(
                  secret,
                  latest['deliveryId'] as String,
                ),
              ))['bytes']
              as String,
        ),
        nextBytes,
      );
    },
  );
  test(
    'release, revoke, ended session and observed expiry never revive; cleanup acknowledges only the owning scope',
    () async {
      final (session, request) = await requested();
      final secret = session.sessionSecret;
      final id =
          manifest(
                await runtime.run(
                  () => runtime.service.agent.fetchInformationFile(
                    secret,
                    input(request),
                  ),
                ),
              )['deliveryId']
              as String;
      await runtime.run(
        () => runtime.service.agent.completeDeviceInformationFile(
          secret,
          id,
          bytes.length,
          sha256.convert(bytes).toString(),
        ),
      );
      final released = manifest(
        await runtime.run(
          () => runtime.service.agent.releaseInformationFile(secret, id),
        ),
      );
      expect(released['state'], 'cleanup_pending');
      await expectLater(
        runtime.run(
          () => runtime.service.agent.downloadDeviceInformationFile(secret, id),
        ),
        fails('not_authorized'),
      );
      final wrong = await requested();
      await expectLater(
        runtime.run(
          () => runtime.service.agent.cleanupDeviceInformationFile(
            wrong.$1.sessionSecret,
            id,
          ),
        ),
        fails('not_authorized'),
      );
      expect(
        manifest(
          await runtime.run(
            () =>
                runtime.service.agent.cleanupDeviceInformationFile(secret, id),
          ),
        )['state'],
        'released',
      );
      final id2 =
          manifest(
                await runtime.run(
                  () => runtime.service.agent.fetchInformationFile(
                    secret,
                    input(request, op: 'ended'),
                  ),
                ),
              )['deliveryId']
              as String;
      await runtime.run(
        () => runtime.service.agent.endSessionWithCapability(
          session.endCapability,
        ),
      );
      await reopen();
      await expectLater(
        runtime.run(
          () =>
              runtime.service.agent.downloadDeviceInformationFile(secret, id2),
        ),
        fails('session_ended'),
      );
      expect(
        manifest(
          await runtime.run(
            () =>
                runtime.service.agent.cleanupDeviceInformationFile(secret, id2),
          ),
        )['state'],
        'expired',
      );
      expect(
        runtime.service.owner.informationFileDeliveries.every(
          (r) => !r.holdsCopy,
        ),
        true,
      );
      final (revoked, revokedRequest) = await requested();
      final revokeId =
          manifest(
                await runtime.run(
                  () => runtime.service.agent.fetchInformationFile(
                    revoked.sessionSecret,
                    input(revokedRequest, op: 'revoked'),
                  ),
                ),
              )['deliveryId']
              as String;
      await runtime.run(() => runtime.service.owner.revoke(revokedRequest));
      await reopen();
      await expectLater(
        runtime.run(
          () => runtime.service.agent.downloadDeviceInformationFile(
            revoked.sessionSecret,
            revokeId,
          ),
        ),
        fails('not_authorized'),
      );
      expect(
        manifest(
          await runtime.run(
            () => runtime.service.agent.cleanupDeviceInformationFile(
              revoked.sessionSecret,
              revokeId,
            ),
          ),
        )['state'],
        'expired',
      );
      final (expiring, expiresRequest) = await requested();
      final expiresId =
          manifest(
                await runtime.run(
                  () => runtime.service.agent.fetchInformationFile(
                    expiring.sessionSecret,
                    input(expiresRequest, op: 'expiry'),
                  ),
                ),
              )['deliveryId']
              as String;
      now = now.add(const Duration(minutes: 11));
      await expectLater(
        runtime.run(
          () => runtime.service.agent.downloadDeviceInformationFile(
            expiring.sessionSecret,
            expiresId,
          ),
        ),
        fails('grant_expired'),
      );
      now = now.subtract(const Duration(minutes: 11));
      await reopen();
      await expectLater(
        runtime.run(
          () => runtime.service.agent.downloadDeviceInformationFile(
            expiring.sessionSecret,
            expiresId,
          ),
        ),
        fails('grant_expired'),
      );
      expect(
        manifest(
          await runtime.run(
            () => runtime.service.agent.cleanupDeviceInformationFile(
              expiring.sessionSecret,
              expiresId,
            ),
          ),
        )['state'],
        'expired',
      );
      expect(
        runtime.service.owner.informationFileDeliveries.every(
          (r) => !r.holdsCopy,
        ),
        true,
      );
    },
  );
}
