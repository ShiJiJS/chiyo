import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_cli/macos_agent_bundle.dart';
import 'package:info_desktop/workspace/owner_workspace_agents.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/agents_controller.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late DateTime now;
  var resourcesClosed = false;
  Future<void> open() async {
    resourcesClosed = false;
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo, clock: () => now);
    source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
  }

  Future<void> close() async {
    if (resourcesClosed) return;
    await source.dispose();
    await service.close();
    await repo.close();
    resourcesClosed = true;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-agents-');
    keys = _Keys();
    now = DateTime.utc(2026, 10, 30);
    await open();
  });
  tearDown(() async {
    if (!resourcesClosed) await close();
    root.deleteSync(recursive: true);
  });
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

  test(
    'zero-request sessions expose public distinct associations without guessing a chat',
    () async {
      final first = service.agent.openSessionWithEndCapability('同名合成聊天');
      final second = service.agent.openSessionWithEndCapability('同名合成聊天');
      final v = await source.agents.read();
      expect(v.valid, isTrue);
      expect(v.session.state, WorkspaceAgentSessionState.unselected);
      expect(v.sessions, hasLength(2));
      expect(v.sessions.map((s) => s.id).toSet(), hasLength(2));
      expect(v.sessions.every((s) => s.totalRequests == 0), isTrue);
      expect(v.cli, WorkspaceAgentCheck.unavailable);
      expect(v.skill, WorkspaceAgentCheck.unavailable);
      expect(v.hooks, isEmpty);
      expect(v.connection, WorkspaceAgentConnection.unverified);
      final public = jsonEncode(v.sessions.map((s) => s.json).toList());
      for (final secret in [
        first.sessionSecret,
        first.endCapability,
        second.sessionSecret,
        second.endCapability,
      ]) {
        expect(public, isNot(contains(secret)));
      }
      for (final s in v.sessions) {
        expect(
          () => service.agent.validateSession(s.id!),
          throwsA(isA<core.AccessFailure>()),
        );
      }
      final id = v.sessions.first.id;
      final selected = await source.agents.read(sessionId: id);
      expect(selected.session.id, id);
      expect(
        (await source.agents.currentSession(
          selected.version,
        )).matches(selected),
        isTrue,
      );
      expect(service.owner.informationRequests, isEmpty);
      final missing = await source.agents.read(sessionId: 'not-a-session');
      expect(missing.session.state, WorkspaceAgentSessionState.missing);
      expect(missing.session.id, isNull);
      expect(missing.sessions, hasLength(2));
    },
  );

  test(
    'diagnostics reobserve changes and controller preserves explicitly selected session',
    () async {
      final item = await service.owner.createInformation('合成资料', '', [
        const core.FieldInput('地址', '', 'PRIVATE-VALUE'),
      ]);
      final ref = core.FieldRef(item.id, item.fields.single.id);
      final first = service.agent.openSession('first');
      final second = service.agent.openSession('second');
      final firstId = service.owner.sessions
          .firstWhere((s) => s.chatLabel == 'first')
          .id;
      final m = WorkspaceAgentsController(source.agents, const Stream.empty());
      addTearDown(m.dispose);
      await m.selectSession(firstId);
      final prior = m.value!;
      expect(
        (await source.agents.diagnose(prior.version)).fingerprint,
        prior.fingerprint,
      );
      final r = service.agent.request(first, 'first request', [ref]);
      service.agent.request(second, 'newer request', [ref]);
      await expectLater(
        source.agents.diagnose(prior.version),
        fails('observation_changed'),
      );
      await m.load();
      expect(m.value!.session.id, firstId);
      m.open(WorkspaceAgentView.session);
      await m.readDetails();
      expect(m.session!.requests.single.id, r.id);
      expect(m.session!.session.pendingRequests, 1);
      expect(m.session!.matches(m.value!), isTrue);
      final beforeApprove = m.value!;
      service.owner.approve(r.id, [ref], lifetime: const Duration(minutes: 2));
      await expectLater(
        source.agents.currentSession(beforeApprove.version),
        fails('observation_changed'),
      );
      await m.load();
      expect(m.session!.session.pendingRequests, 0);
      expect(m.session!.session.activeGrants, 1);
      now = now.add(const Duration(minutes: 3));
      await expectLater(
        source.agents.diagnose(m.value!.version),
        fails('observation_changed'),
      );
      await m.load();
      expect(m.session!.session.activeGrants, 0);
      expect(m.session!.requests.single.state, WorkspaceApprovalState.expired);
      service.agent.endSession(first);
      await m.load();
      expect(m.value!.session.state, WorkspaceAgentSessionState.ended);
      expect(m.session!.matches(m.value!), isTrue);
      expect(service.owner.informationRequests, hasLength(2));
    },
  );

  test(
    'SQLCipher reopen exposes history without live authorization or automatic selection',
    () async {
      final item = await service.owner.createInformation('persisted', '', [
        const core.FieldInput('text', '', 'PRIVATE-HISTORY'),
      ]);
      final secret = service.agent.openSession('old chat');
      final ref = core.FieldRef(item.id, item.fields.single.id);
      final request = service.agent.request(secret, 'history', [ref]);
      service.owner.approve(request.id, [ref]);
      final id = service.owner.sessions.single.id;
      final oldSource = source.agents;
      await close();
      await open();
      expect(service.owner.sessions, isEmpty);
      final v = await source.agents.read();
      expect(v.session.state, WorkspaceAgentSessionState.unselected);
      expect(v.sessions.single.state, WorkspaceAgentSessionState.ended);
      final selected = await source.agents.read(sessionId: id);
      final detail = await source.agents.currentSession(selected.version);
      expect(detail.matches(selected), isTrue);
      expect(detail.session.activeGrants, 0);
      expect(detail.session.pendingRequests, 0);
      expect(detail.requests.single.state, WorkspaceApprovalState.sessionEnded);
      expect(
        () => service.agent.validateSession(secret),
        throwsA(isA<core.AccessFailure>()),
      );
      await expectLater(oldSource.read(), fails('library_changed'));
    },
  );

  test('workspace refresh observes empty session creation and end', () async {
    source.refreshFromOwner();
    await Future<void>.delayed(Duration.zero);
    final events = <WorkspaceRecordRef?>[];
    final sub = source.changes.listen(events.add);
    addTearDown(sub.cancel);
    final secret = service.agent.openSession('empty');
    source.refreshFromOwner();
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    service.agent.endSession(secret);
    source.refreshFromOwner();
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(2));
  });
  test(
    'verified delivery stays separate from host trust and stale package observations',
    () async {
      var digest = 'first-manifest';
      final refreshes = <bool>[];
      final agents = OwnerWorkspaceAgents(
        owner: service.owner,
        readBundle: ({bool rehash = false}) async {
          refreshes.add(rehash);
          return MacAgentBundleObservation(
            status: 'verified',
            directory: '/synthetic/完整包',
            sourceCommit: 'a' * 40,
            manifestDigest: digest,
          );
        },
      );
      final first = await agents.read();
      expect(first.cli, WorkspaceAgentCheck.ready);
      expect(first.skill, WorkspaceAgentCheck.unavailable);
      expect(first.hooks, isEmpty);
      expect(first.connection, WorkspaceAgentConnection.unverified);
      expect(first.cliReason, contains('不代表宿主已安装或信任'));
      expect(first.packageDirectory, '/synthetic/完整包');
      expect(
        (await agents.diagnose(first.version)).fingerprint,
        first.fingerprint,
      );
      expect(refreshes, [false, true]);
      digest = 'replacement-manifest';
      await expectLater(
        agents.diagnose(first.version),
        fails('observation_changed'),
      );
      final next = await agents.read();
      expect(next.packageDigest, digest);
      expect(next.fingerprint, isNot(first.fingerprint));
      expect(service.owner.sessions, isEmpty);
    },
  );

  test(
    'missing delivery or probe failure cannot manufacture trusted or installed state',
    () async {
      for (final status in [
        'not_packaged',
        'manifest_missing',
        'bundle_invalid',
        'exception',
      ]) {
        final agents = OwnerWorkspaceAgents(
          owner: service.owner,
          readBundle: ({bool rehash = false}) async {
            if (status == 'exception') throw StateError('PRIVATE-PATH');
            return MacAgentBundleObservation(status: status);
          },
        );
        final v = await agents.read();
        expect(v.cli, WorkspaceAgentCheck.unavailable);
        expect(v.connection, WorkspaceAgentConnection.unverified);
        expect(v.packageDirectory, isNull);
        expect(v.cliReason, isNot(contains('PRIVATE-PATH')));
        expect(v.cliReason, isNotEmpty);
      }
    },
  );
}
