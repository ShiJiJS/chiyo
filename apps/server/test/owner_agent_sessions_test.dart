import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/agent_sessions.dart';
import 'package:info_workspace/agent_sessions_transport.dart';
import 'package:info_workspace/workspace_agents.dart';
import 'package:info_workspace/workspace_approvals.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

Future<WorkspaceAgentSessions> snapshot(DeviceCredentialFixture f) async =>
    agentSessionsFromJson(
      await f.owner.request('GET', '/v1/owner/agent-sessions'),
    );

void main() {
  test(
    'authenticated Owner observes distinct empty chats, request decisions, expiry, restart and end without receiving chat proofs or content',
    () async {
      var now = DateTime.utc(2026, 11, 9);
      final f = await DeviceCredentialFixture.create(clock: () => now);
      addTearDown(f.dispose);
      final item = await f.runtime.run(
        () => f.runtime.service.owner.createInformation('合成资料', '', [
          const FieldInput('内容', '', 'SYNTHETIC_PRIVATE_BODY'),
        ]),
      );
      final noChats = (await f.owner.request(
        'GET',
        '/v1/server',
      ))['workspaceObservation'];
      final first = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': '同名聊天',
      });
      final second = await f.agents.last.call('/session/lifecycle', {
        'chatLabel': '同名聊天',
      });
      expect(
        (await f.owner.request('GET', '/v1/server'))['workspaceObservation'],
        isNot(noChats),
      );
      final empty = await snapshot(f);
      expect(empty.valid, isTrue);
      expect(empty.sessions, hasLength(2));
      expect(empty.sessions.map((s) => s.id).toSet(), hasLength(2));
      expect(empty.sessions.every((s) => s.totalRequests == 0), isTrue);
      final r = await f.agents.first.call('/request', {
        'sessionSecret': first['sessionSecret'],
        'operationId': 'observe-request',
        'purpose': '合成读取',
        'fields': [
          {'itemId': item.id, 'fieldId': item.fields.single.id},
        ],
      });
      final requested = await snapshot(f);
      final id = requested.requests.single.sessionId;
      expect(
        requested.sessions.singleWhere((s) => s.id == id).pendingRequests,
        1,
      );
      final requestId = r['requestId'] as String;
      await f.runtime.run(
        () async => f.runtime.service.owner.approve(requestId, [
          FieldRef(item.id, item.fields.single.id),
        ], lifetime: const Duration(minutes: 2)),
      );
      final approved = await snapshot(f);
      expect(approved.sessions.singleWhere((s) => s.id == id).activeGrants, 1);
      expect(approved.revision, isNot(requested.revision));
      expect((await snapshot(f)).revision, approved.revision);
      await f.reopen();
      final reopened = await snapshot(f);
      expect(reopened.sessions.singleWhere((s) => s.id == id).activeGrants, 1);
      now = now.add(const Duration(minutes: 3));
      final expired = await snapshot(f);
      expect(expired.sessions.singleWhere((s) => s.id == id).activeGrants, 0);
      expect(expired.requests.single.state, WorkspaceApprovalState.expired);
      await f.agents.first.call('/session/end', {
        'endCapability': first['endCapability'],
      });
      final ended = await snapshot(f);
      expect(
        ended.sessions.singleWhere((s) => s.id == id).state,
        WorkspaceAgentSessionState.ended,
      );
      final public = jsonEncode(agentSessionsToJson(ended));
      for (final value in [
        first['sessionSecret'],
        first['endCapability'],
        second['sessionSecret'],
        second['endCapability'],
        f.token,
        f.profiles.first.deviceToken,
        'SYNTHETIC_PRIVATE_BODY',
      ]) {
        expect(public, isNot(contains(value)));
      }
      final http = HttpClient(context: f.trust);
      try {
        final req = await http.getUrl(
          f.owner.address.resolve('/v1/owner/agent-sessions'),
        );
        req.headers.set(
          'authorization',
          'Bearer ${f.profiles.first.deviceToken}',
        );
        final response = await req.close();
        expect(response.statusCode, 401);
        await response.drain<void>();
      } finally {
        http.close(force: true);
      }
    },
  );
  test(
    'credential requests use the same shared projection and portable restore cannot revive a live association',
    () async {
      final f = await DeviceCredentialFixture.create();
      var disposed = false;
      addTearDown(() async {
        if (!disposed) await f.dispose();
      });
      await f.tokenOperation();
      final before = await snapshot(f);
      expect(before.requests.single.kind, WorkspaceApprovalKind.credential);
      expect(before.sessions.single.activeGrants, 1);
      final key = await f.runtime.run(() => f.repo.backups.enable());
      final archive = '${f.root.path}/agents.aimbackup';
      await f.runtime.run(() async {
        await f.repo.backups.saveRecoveryKeyTo('${f.root.path}/recovery.key');
        await f.runtime.service.owner.exportLibrary(
          () => f.repo.backups.exportTo(archive),
        );
      });
      final copy = await Directory.systemTemp.createTemp(
        'agent-snapshot-recovery-',
      );
      addTearDown(() => copy.delete(recursive: true));
      final retainedArchive = (await File(
        archive,
      ).copy('${copy.path}/encrypted.aimbackup')).path;
      await f.dispose();
      disposed = true;
      final target = await DeviceCredentialFixture.create();
      addTearDown(target.dispose);
      await target.runtime.run(
        () => target.runtime.service.owner.restoreLibrary(
          () => target.repo.backups.restoreFrom(retainedArchive, key),
        ),
      );
      final restored = await snapshot(target);
      expect(restored.valid, isTrue);
      expect(restored.revision, isNot(before.revision));
      expect(
        restored.sessions.every(
          (s) =>
              s.state == WorkspaceAgentSessionState.ended &&
              s.activeGrants == 0,
        ),
        isTrue,
      );
      expect(restored.requests.single.kind, WorkspaceApprovalKind.credential);
      expect(
        jsonEncode(agentSessionsToJson(restored)),
        isNot(contains('SYNTHETIC_LOST_CLAIM_TOKEN')),
      );
    },
  );
  test(
    'session wire rejects injected private fields, duplicate identities and inconsistent request counts',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      await f.agents.first.call('/session/lifecycle', {'chatLabel': '合成'});
      final wire = agentSessionsToJson(await snapshot(f));
      expect(agentSessionsFromJson(wire).valid, isTrue);
      expect(
        () => agentSessionsFromJson({...wire, 'sessionSecret': 'synthetic'}),
        throwsFormatException,
      );
      expect(
        () => agentSessionsFromJson({...wire, 'serviceAvailable': 1}),
        throwsFormatException,
      );
      final session = (wire['sessions'] as List).single as Map;
      for (final rows in [
        [session, session],
        [
          {...session, 'grants': 1},
        ],
        [
          {...session, 'endCapability': 'synthetic'},
        ],
        [
          {...session, 'state': 'unknown'},
        ],
      ]) {
        expect(
          () => agentSessionsFromJson({...wire, 'sessions': rows}),
          throwsFormatException,
        );
      }
    },
  );
}
