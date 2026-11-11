import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';
import '../../info_core/test/fixtures/ssh_session_fixture.dart'
    show knownHostBytes;

void main() {
  late Directory root;
  late TestKeyStore keys;
  late EncryptedInformationRepository repo;
  late OnlineInformationRuntime runtime;
  late DateTime now;
  const device = 'synthetic_device_12345';
  late ManagedCredential credential;
  late InformationItem item;
  late OpenedSession chat;
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
    root = await Directory.systemTemp.createTemp('online-credential-state-');
    keys = TestKeyStore();
    now = DateTime.utc(2026, 11, 8);
    await open();
    credential = await runtime.run(() async {
      final c = await runtime.service.owner.createStringCredential(
        name: 'Synthetic token',
        publicPurpose: 'Tests only',
        secret: 'SYNTHETIC_ONLINE_PRIVATE_TOKEN',
      );
      return runtime.service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: c.publicPurpose,
        privateNote: '',
        suggestedBinding: 'GH_TOKEN',
        discoverable: true,
      );
    });
    item = await runtime.run(
      () => runtime.service.owner.createInformation('Synthetic account', '', [
        const FieldInput('Selected', '', 'SYNTHETIC_SELECTED'),
        const FieldInput('Other', '', 'SYNTHETIC_OUTSIDE'),
      ]),
    );
    chat = await runtime.run(
      () => runtime.service.agent.openSessionWithEndCapability(
        'Synthetic device chat',
      ),
    );
  });
  tearDown(() async {
    await runtime.close();
    await repo.close();
    await root.delete(recursive: true);
  });
  Matcher fails(String code) =>
      throwsA(isA<CredentialUseFailure>().having((e) => e.code, 'code', code));
  CredentialUseInput input() => CredentialUseInput.fromJson({
    'protocolVersion': 2,
    'command': 'request-use',
    'purpose': 'Synthetic work',
    'credentials': [
      {
        'alias': 'token',
        'credentialId': credential.id,
        'version': credential.version,
      },
    ],
    'readFields': item.fields
        .map((f) => FieldRef(item.id, f.id).toJson())
        .toList(),
    'launch': {
      'receiver': 'gh_token',
      'executable': '/executing-device/gh',
      'argv': ['api', 'user'],
      'cwd': '/executing-device/work',
      'env': {
        'GH_TOKEN': {'secret': 'token'},
      },
    },
  }, allowPortableLaunchPaths: true);
  // A synthetic device preflight snapshot; these tests exercise server rules
  // and SQLCipher persistence, not a real native tool/version probe or launch.
  DeviceCredentialLaunch prepared(CredentialUseInput value) =>
      DeviceCredentialLaunch.fromPrivateJson({
        'version': 1,
        'planHash': value.launch.planHash,
        'executable': {
          'path': value.launch.path,
          'byteLength': 100,
          'modifiedMicros': 1,
          'sha256': 'sha256:${'a' * 64}',
        },
        'cwd': value.launch.cwd,
      });
  Future<CredentialUseRequest> request() {
    final value = input();
    return runtime.run(
      () => runtime.service.agent.requestDeviceCredentialUse(
        device,
        chat.sessionSecret,
        value,
        prepared(value),
      ),
    );
  }

  Future<void> approve(String id) => runtime.run(
    () => runtime.service.owner.decideCredentialUse(
      id,
      approveCredential: true,
      lifetime: const Duration(minutes: 15),
      fields: [FieldRef(item.id, item.fields.first.id)],
      fieldLifetime: const Duration(minutes: 30),
    ),
  );
  Map<String, dynamic> decision(String id) =>
      ((runtime.service.agent.credentialUseStatus(
                    chat.sessionSecret,
                    id,
                  )['decision']
                  as Map)['credentialUse']
              as Map)
          .cast<String, dynamic>();

  test(
    'pending and approved device requests keep original chat, scope, proof and deadlines after encrypted reopen',
    () async {
      final r = await request();
      expect(await Directory('/executing-device/work').exists(), false);
      expect(r.plan.cwd, '/executing-device/work');
      await reopen();
      expect(
        runtime.service.agent.credentialUseStatus(
          chat.sessionSecret,
          r.id,
        )['status'],
        'pending',
      );
      runtime.service.agent.checkDeviceCredentialRequest(
        device,
        chat.sessionSecret,
        r.id,
      );
      expect(
        () => runtime.service.agent.checkDeviceCredentialRequest(
          'other-device',
          chat.sessionSecret,
          r.id,
        ),
        fails('session_mismatch'),
      );
      final other = await runtime.run(
        () => runtime.service.agent.openSession('Synthetic device chat'),
      );
      expect(
        () => runtime.service.agent.checkDeviceCredentialRequest(
          device,
          other,
          r.id,
        ),
        fails('session_mismatch'),
      );
      await approve(r.id);
      final grant = await runtime.run(
        () => runtime.service.agent.claim(chat.sessionSecret, r.id),
      );
      final deadline = decision(r.id)['expiresAt'];
      now = now.add(const Duration(minutes: 3));
      await reopen();
      expect(decision(r.id)['state'], 'available');
      expect(decision(r.id)['expiresAt'], deadline);
      final resumed = await runtime.run(
        () => runtime.service.agent.claim(chat.sessionSecret, r.id),
      );
      expect(resumed.token, grant.token);
      expect(resumed.expiresAt, grant.expiresAt);
      expect(
        await runtime.run(
          () => runtime.service.agent.read(
            grant.token,
            FieldRef(item.id, item.fields.first.id),
          ),
        ),
        'SYNTHETIC_SELECTED',
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.read(
            grant.token,
            FieldRef(item.id, item.fields.last.id),
          ),
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(runtime.service.owner.credentialExecutions, isEmpty);
      expect(
        jsonEncode((await repo.openServerState()).payload),
        isNot(contains('SYNTHETIC_ONLINE_PRIVATE_TOKEN')),
      );
    },
  );

  test(
    'observed request and grant expiry persist through clock correction without expiring independent field scope early',
    () async {
      final approved = await request();
      await approve(approved.id);
      final grant = await runtime.run(
        () => runtime.service.agent.claim(chat.sessionSecret, approved.id),
      );
      now = now.add(const Duration(minutes: 16));
      await runtime.run(
        () => expect(decision(approved.id)['state'], 'expired'),
      );
      expect(
        await runtime.run(
          () => runtime.service.agent.read(
            grant.token,
            FieldRef(item.id, item.fields.first.id),
          ),
        ),
        'SYNTHETIC_SELECTED',
      );
      now = now.subtract(const Duration(minutes: 15));
      await reopen();
      expect(decision(approved.id)['state'], 'expired');
      final pending = await request();
      now = now.add(const Duration(hours: 2, minutes: 1));
      await runtime.run(
        () => expect(
          runtime.service.agent.credentialUseStatus(
            chat.sessionSecret,
            pending.id,
          )['status'],
          'expired',
        ),
      );
      now = now.subtract(const Duration(hours: 2));
      await reopen();
      expect(
        runtime.service.agent.credentialUseStatus(
          chat.sessionSecret,
          pending.id,
        )['status'],
        'expired',
      );
      await expectLater(approve(pending.id), fails('request_terminal'));
    },
  );

  for (final cause in ['revoked', 'ended', 'disabled', 'rotated']) {
    test('$cause does not revive a device grant after restart', () async {
      final r = await request();
      await approve(r.id);
      await runtime.run(() async {
        switch (cause) {
          case 'revoked':
            await runtime.service.owner.revokeCredentialUse(r.id);
          case 'ended':
            runtime.service.agent.endSessionWithCapability(chat.endCapability);
          case 'disabled':
            await runtime.service.owner.setCredentialEnabled(
              credential.id,
              credential.revision,
              false,
            );
          case 'rotated':
            await runtime.service.owner.rotateStringCredential(
              credential.id,
              credential.revision,
              'SYNTHETIC_CHANGED_TOKEN',
            );
        }
      });
      await reopen();
      expect(decision(r.id)['state'], isNot('available'));
    });
  }

  test(
    'committed mixed approval before snapshot publication recovers only the original field scope',
    () async {
      final r = await request();
      final before = (await repo.openServerState()).payload['textRuntime'];
      await approve(r.id);
      await runtime.close();
      final latest = await repo.openServerState();
      await repo.commitServerState(latest, {
        ...latest.payload,
        'textRuntime': before,
      });
      await repo.close();
      await open();
      expect(decision(r.id)['state'], 'available');
      final grant = await runtime.run(
        () => runtime.service.agent.claim(chat.sessionSecret, r.id),
      );
      expect(grant.fields, [FieldRef(item.id, item.fields.first.id)]);
      expect(
        await runtime.run(
          () => runtime.service.agent.read(grant.token, grant.fields.single),
        ),
        'SYNTHETIC_SELECTED',
      );
      expect(runtime.service.owner.credentialExecutions, isEmpty);
    },
  );

  test(
    'portable restore retains history but creates no device or chat authority',
    () async {
      final r = await request();
      await approve(r.id);
      final recovery = await enableTestBackups(repo.backups);
      final path = '${root.path}/portable.aimbackup';
      await repo.backups.exportTo(path);
      final target = await EncryptedInformationRepository.openOnline(
        '${root.path}/restored',
        TestKeyStore(),
      );
      try {
        await target.backups.restoreFrom(path, recovery);
        final restored = await OnlineInformationRuntime.open(
          repository: target,
          clock: () => now,
        );
        try {
          expect(
            restored.service.owner.credentialUseRequests.single.restoredAt,
            isNotNull,
          );
          expect(
            restored.service.owner.credentialGrantState(
              restored.service.owner.credentialUseRequests.single,
            ),
            'revoked',
          );
          expect(
            () => restored.service.agent.checkDeviceCredentialRequest(
              device,
              chat.sessionSecret,
              r.id,
            ),
            fails('session_mismatch'),
          );
        } finally {
          await restored.close();
        }
      } finally {
        await target.close();
      }
    },
  );

  test(
    'unconfirmed approval stays inactive after restart instead of reviving from history',
    () async {
      final r = await request();
      await approve(r.id);
      await runtime.close();
      final snapshot = await repo.openServerState();
      final state =
          jsonDecode(jsonEncode(snapshot.payload['textRuntime']))
              as Map<String, dynamic>;
      ((state['credentialRuntime'] as Map)['requests'] as List)
              .single['inactive'] =
          true;
      state['requests'] = <Object>[];
      await repo.commitServerState(snapshot, {
        ...snapshot.payload,
        'textRuntime': state,
      });
      await repo.close();
      await open();
      expect(decision(r.id)['state'], 'revoked');
      expect(
        runtime.service.owner.credentialUseDecisionUnconfirmed(
          runtime.service.owner.credentialUseRequests.single,
        ),
        true,
      );
      await expectLater(
        runtime.run(
          () => runtime.service.agent.claim(chat.sessionSecret, r.id),
        ),
        throwsA(isA<AccessFailure>()),
      );
    },
  );

  for (final revoke in [false, true]) {
    test(
      'exact original ${revoke ? 'revoke' : 'approval'} receipt settles encrypted unknown state after reopen',
      () async {
        final r = await request();
        final field = FieldRef(item.id, item.fields.first.id);
        if (revoke) await approve(r.id);
        final before =
            jsonDecode(
                  jsonEncode(
                    (await repo.openServerState()).payload['textRuntime'],
                  ),
                )
                as Map<String, dynamic>;
        final receipt = await runtime.run(
          () => runtime.service.owner.performAdditionalApproval(
            operationId: 'encrypted-original',
            requestId: r.id,
            kind: 'credential',
            action: revoke
                ? InformationApprovalAction.revoke
                : InformationApprovalAction.approve,
            reviewToken: 'a' * 64,
            commandDigest: 'b' * 64,
            validate: () {},
            decide: revoke
                ? () => runtime.service.owner.revokeCredentialRequest(r.id)
                : () => runtime.service.owner.decideCredentialUse(
                    r.id,
                    approveCredential: true,
                    fields: [field],
                    fieldLifetime: const Duration(minutes: 30),
                  ),
          ),
        );
        await runtime.close();
        var snapshot = await repo.openServerState();
        final state =
            jsonDecode(jsonEncode(snapshot.payload['textRuntime']))
                as Map<String, dynamic>;
        state['requests'] = before['requests'];
        final private = state['credentialRuntime'] as Map;
        (private['requests'] as List).single['inactive'] = !revoke;
        private['decisions'] = {'encrypted-original': receipt.toJson()};
        await repo.commitServerState(snapshot, {
          ...snapshot.payload,
          'textRuntime': state,
        });
        final original = (await repo.openServerState()).payload;
        // A different command must not settle even when it names an existing
        // receipt. Startup rejects it without replacing private state.
        final forged = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
        (((forged['textRuntime'] as Map)['credentialRuntime']
                    as Map)['decisions']
                as Map)['encrypted-original']['commandDigest'] =
            'c' * 64;
        snapshot = await repo.openServerState();
        await repo.commitServerState(snapshot, forged);
        await repo.close();
        await expectLater(open(), throwsA(isA<AccessFailure>()));
        expect((await repo.openServerState()).payload, forged);
        snapshot = await repo.openServerState();
        await repo.commitServerState(snapshot, original);
        await repo.close();
        now = now.add(const Duration(minutes: 2));
        await open();
        expect(
          await runtime.run(
            () => runtime.service.owner.additionalApprovalReceipt(
              'encrypted-original',
            ),
          ),
          isA<InformationApprovalReceipt>().having(
            (r) => r.commandDigest,
            'original digest',
            receipt.commandDigest,
          ),
        );
        expect(
          runtime.service.owner.credentialUseDecisionUnconfirmed(
            runtime.service.owner.credentialUseRequests.single,
          ),
          false,
        );
        final persisted =
            (await repo.openServerState()).payload['textRuntime'] as Map;
        expect((persisted['credentialRuntime'] as Map)['decisions'], isEmpty);
        if (revoke) {
          expect(decision(r.id)['state'], 'revoked');
          await expectLater(
            runtime.run(
              () => runtime.service.agent.claim(chat.sessionSecret, r.id),
            ),
            throwsA(isA<AccessFailure>()),
          );
        } else {
          expect(decision(r.id)['state'], 'available');
          final grant = await runtime.run(
            () => runtime.service.agent.claim(chat.sessionSecret, r.id),
          );
          expect(grant.fields, [field]);
          expect(
            grant.expiresAt,
            DateTime.utc(2026, 11, 8).add(const Duration(minutes: 30)),
          );
          expect(
            await runtime.run(
              () => runtime.service.agent.read(grant.token, field),
            ),
            'SYNTHETIC_SELECTED',
          );
        }
        await reopen();
        expect(decision(r.id)['state'], revoke ? 'revoked' : 'available');
      },
    );
  }

  test(
    'malformed private device binding rejects startup without overwriting the saved state',
    () async {
      await request();
      await runtime.close();
      final snapshot = await repo.openServerState();
      final state =
          jsonDecode(jsonEncode(snapshot.payload['textRuntime']))
              as Map<String, dynamic>;
      ((state['credentialRuntime'] as Map)['requests'] as List)
              .single['deviceId'] =
          'invalid';
      final damaged = await repo.commitServerState(snapshot, {
        ...snapshot.payload,
        'textRuntime': state,
      });
      await expectLater(
        OnlineInformationRuntime.open(repository: repo),
        throwsA(isA<FormatException>()),
      );
      final preserved = await repo.openServerState();
      expect(preserved.revision, damaged.revision);
      expect(preserved.payload, damaged.payload);
    },
  );

  test(
    'older text runtime without a device binding does not activate credential history',
    () async {
      final r = await request();
      await runtime.close();
      final snapshot = await repo.openServerState();
      final state =
          jsonDecode(jsonEncode(snapshot.payload['textRuntime']))
              as Map<String, dynamic>;
      state['version'] = 2;
      state.remove('credentialRuntime');
      await repo.commitServerState(snapshot, {
        ...snapshot.payload,
        'textRuntime': state,
      });
      await repo.close();
      await open();
      expect(
        runtime.service.owner.credentialUseState(
          runtime.service.owner.credentialUseRequests.single,
        ),
        'cancelled',
      );
      expect(
        () => runtime.service.agent.checkDeviceCredentialRequest(
          device,
          chat.sessionSecret,
          r.id,
        ),
        fails('session_mismatch'),
      );
    },
  );

  test(
    'session SSH grant survives days and restart but ends with the original chat',
    () async {
      final c = await runtime.run(() async {
        await runtime.service.owner.configureSshKnownHosts(
          'Synthetic trust',
          knownHostBytes(),
        );
        final raw = await runtime.service.owner.createFileCredential(
          name: 'Synthetic SSH',
          publicPurpose: '',
          fileName: 'identity',
          bytes: utf8.encode('SYNTHETIC_NOT_A_REAL_KEY'),
        );
        return runtime.service.owner.updateCredentialMetadata(
          raw.id,
          raw.revision,
          name: raw.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'key',
          discoverable: true,
        );
      });
      final value = CredentialUseInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-use',
        'purpose': 'Synthetic SSH',
        'credentials': [
          {'alias': 'key', 'credentialId': c.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'ssh_identity',
          'executable': '/executing-device/ssh',
          'argv': [
            '-T',
            '-o',
            'BatchMode=yes',
            '-i',
            {'file': 'key'},
            '-p',
            '2222',
            'developer@test.beichen.example',
            '/usr/bin/true',
          ],
          'cwd': '/executing-device/work',
          'env': <String, dynamic>{},
        },
      }, allowPortableLaunchPaths: true);
      final r = await runtime.run(
        () => runtime.service.agent.requestDeviceCredentialUse(
          device,
          chat.sessionSecret,
          value,
          prepared(value),
        ),
      );
      await runtime.run(
        () => runtime.service.owner.decideCredentialUse(
          r.id,
          approveCredential: true,
          lifetime: null,
        ),
      );
      now = now.add(const Duration(days: 4));
      await reopen();
      expect(decision(r.id)['state'], 'available');
      expect(decision(r.id)['validity'], 'session');
      expect(decision(r.id)['expiresAt'], isNull);
      await runtime.run(
        () =>
            runtime.service.agent.endSessionWithCapability(chat.endCapability),
      );
      await reopen();
      expect(decision(r.id)['state'], 'revoked');
    },
  );
}
