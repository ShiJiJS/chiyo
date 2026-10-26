import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/host_mutation.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const aliyun = WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun');
const tokyo = WorkspaceHostTarget.record(azure);
const hangzhou = WorkspaceHostTarget.record(aliyun);

class _DeferredHosts extends Fake implements WorkspaceHostSource {
  final commit = Completer<WorkspaceHostReceipt>();
  WorkspaceHostChange? command;
  WorkspaceHostReceipt? found;
  bool failRead = false;
  int writes = 0;
  @override
  Future<WorkspaceHostReceipt> change(WorkspaceHostChange c) {
    writes++;
    command = c;
    return commit.future;
  }

  @override
  Future<WorkspaceHostReceipt?> receipt(String id) async {
    if (failRead) throw StateError('offline');
    return found;
  }
}

void main() {
  Matcher failure(String code) =>
      isA<WorkspaceFailure>().having((e) => e.code, 'code', code);
  Future<void> toggle(SampleWorkspaceSource source, bool enabled) async {
    final catalog = await source.plugins.load();
    await source.plugins.change(
      WorkspacePluginChange(
        operationId: workspaceOperationId(),
        action: enabled
            ? WorkspacePluginAction.enable
            : WorkspacePluginAction.disable,
        packageId: 'builtin.server',
        expectedVersion: catalog.version,
        expectedDigest: catalog.packages
            .firstWhere((p) => p.id == 'builtin.server')
            .digest,
      ),
    );
  }

  test(
    'host normalization distinguishes ports and rejects URI/option text without IO',
    () {
      expect(
        WorkspaceHostEndpoint.parse(' TOKYO.Beichen.example. ', '02222')!.key,
        'tokyo.beichen.example|2222',
      );
      expect(WorkspaceHostEndpoint.parse('host.example', null)!.port, 22);
      expect(WorkspaceHostEndpoint.parse('127.000.0.1', 22)!.host, '127.0.0.1');
      expect(
        WorkspaceHostEndpoint.parse('[2001:DB8::1]', 22)!.key,
        WorkspaceHostEndpoint.parse('2001:0db8:0:0:0:0:0:0001', 22)!.key,
      );
      for (final host in [
        '',
        '-oProxyCommand',
        'user@host',
        'ssh://host',
        'host/path',
        'host name',
        '[::gggg]',
        '999.1.2.3',
        'h..example',
      ]) {
        expect(WorkspaceHostEndpoint.parse(host, 22), isNull, reason: host);
      }
      for (final port in [0, -1, 65536, '22x', '2.0']) {
        expect(WorkspaceHostEndpoint.parse('host.example', port), isNull);
      }
    },
  );

  test(
    'registered panels cannot be inherited from external definitions and reads expose the shared host fact',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final plugins = await s.plugins.load();
      expect(
        plugins.packages.where((p) => p.panels.isNotEmpty).single.id,
        'builtin.server',
      );
      expect((await s.hosts.read(tokyo)).state, WorkspaceHostState.trusted);
      expect(
        (await s.hosts.read(hangzhou)).state,
        WorkspaceHostState.unconfirmed,
      );
      final state = await s.hosts.read(hangzhou);
      final receipt = await s.hosts.change(
        WorkspaceHostChange(
          operationId: 'confirm-shared',
          action: WorkspaceHostAction.confirm,
          reviewed: state,
        ),
      );
      expect(receipt.version, greaterThan(state.version));
      expect(
        (await s.hosts.load())
            .singleWhere((h) => h.target.key == aliyun.key)
            .state,
        WorkspaceHostState.trusted,
      );
      expect((await s.readDetail(aliyun)).version, state.recordVersion);
      await expectLater(
        s.hosts.read(
          const WorkspaceHostTarget.record(
            WorkspaceRecordRef(WorkspaceRecordKind.information, 'blinko'),
          ),
        ),
        throwsA(failure('not_found')),
      );
    },
  );

  test(
    'normalized aliases share decisions; endpoint edits do not inherit; old identity remains revocable',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final initial = await s.readDetail(azure);
      final trusted = await s.hosts.read(tokyo);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'alias',
          expectedVersion: initial.version,
          record: initial.record,
          values: {'host': 'TOKYO.BEICHEN.EXAMPLE.', 'port': '02222'},
        ),
      );
      expect((await s.hosts.read(tokyo)).state, WorkspaceHostState.trusted);
      final alias = await s.readDetail(azure);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'new-port',
          expectedVersion: alias.version,
          record: alias.record,
          values: {'port': '2223'},
        ),
      );
      final moved = await s.hosts.read(tokyo);
      expect(moved.state, WorkspaceHostState.missingFingerprint);
      expect(moved.identityId, isNot(trusted.identityId));
      expect(moved.canConfirm, isFalse);
      final orphan = (await s.hosts.load()).singleWhere(
        (h) => h.target.record == null,
      );
      expect(orphan.identityId, trusted.identityId);
      await s.hosts.change(
        WorkspaceHostChange(
          operationId: 'revoke-old-endpoint',
          action: WorkspaceHostAction.revoke,
          reviewed: orphan,
        ),
      );
      expect(
        (await s.hosts.read(orphan.target)).state,
        WorkspaceHostState.revoked,
      );
      expect(
        (await s.hosts.read(tokyo)).state,
        WorkspaceHostState.missingFingerprint,
      );
    },
  );

  test(
    'fingerprint change requires explicit review, no fingerprint can be confirmed, disable permits revoke only',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final known = await s.hosts.read(tokyo);
      s.observeHost(known.endpoint!, 'SHA256:DemoRotatedTokyoFingerprint');
      final rotated = await s.hosts.read(tokyo);
      expect(rotated.state, WorkspaceHostState.changed);
      await expectLater(
        s.hosts.change(
          WorkspaceHostChange(
            operationId: 'unreviewed',
            action: WorkspaceHostAction.confirm,
            reviewed: rotated,
          ),
        ),
        throwsA(failure('identity_changed')),
      );
      await s.hosts.change(
        WorkspaceHostChange(
          operationId: 'reviewed',
          action: WorkspaceHostAction.confirm,
          reviewed: rotated,
          acknowledgeChanged: true,
        ),
      );
      await toggle(s, false);
      final disabled = await s.hosts.read(tokyo);
      expect(disabled.canConfirm, false);
      expect(disabled.canRevoke, true);
      await s.hosts.change(
        WorkspaceHostChange(
          operationId: 'disabled-revoke',
          action: WorkspaceHostAction.revoke,
          reviewed: disabled,
        ),
      );
      final revoked = await s.hosts.read(tokyo);
      await expectLater(
        s.hosts.change(
          WorkspaceHostChange(
            operationId: 'disabled-confirm',
            action: WorkspaceHostAction.confirm,
            reviewed: revoked,
          ),
        ),
        throwsA(failure('unavailable')),
      );
      await toggle(s, true);
      expect((await s.hosts.read(tokyo)).state, WorkspaceHostState.revoked);
      s.observeHost(known.endpoint!, null);
      final missing = await s.hosts.read(tokyo);
      expect(missing.state, WorkspaceHostState.missingFingerprint);
      await expectLater(
        s.hosts.change(
          WorkspaceHostChange(
            operationId: 'missing-confirm',
            action: WorkspaceHostAction.confirm,
            reviewed: missing,
          ),
        ),
        throwsA(failure('unavailable')),
      );
    },
  );

  test(
    'record, observed fingerprint and package revisions invalidate review before any write; errors preserve facts',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      var seen = await s.hosts.read(hangzhou);
      final detail = await s.readDetail(aliyun);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'rename',
          expectedVersion: detail.version,
          record: detail.record.copyWith(name: '重命名服务器'),
          values: const {},
        ),
      );
      await expectLater(
        s.hosts.change(
          WorkspaceHostChange(
            operationId: 'stale-record',
            action: WorkspaceHostAction.confirm,
            reviewed: seen,
          ),
        ),
        throwsA(failure('conflict')),
      );
      seen = await s.hosts.read(hangzhou);
      await toggle(s, false);
      await toggle(s, true);
      await expectLater(
        s.hosts.change(
          WorkspaceHostChange(
            operationId: 'stale-package',
            action: WorkspaceHostAction.confirm,
            reviewed: seen,
          ),
        ),
        throwsA(failure('conflict')),
      );
      seen = await s.hosts.read(hangzhou);
      s.nextSaveFailure = const WorkspaceFailure('save_failed', '合成保存失败');
      await expectLater(
        s.hosts.change(
          WorkspaceHostChange(
            operationId: 'failed',
            action: WorkspaceHostAction.confirm,
            reviewed: seen,
          ),
        ),
        throwsA(failure('save_failed')),
      );
      expect(await s.hosts.receipt('failed'), isNull);
      expect(
        (await s.hosts.read(hangzhou)).state,
        WorkspaceHostState.unconfirmed,
      );
      s.observeHost(seen.endpoint!, 'SHA256:DemoChangedDuringReview');
      await expectLater(
        s.hosts.change(
          WorkspaceHostChange(
            operationId: 'stale-fingerprint',
            action: WorkspaceHostAction.confirm,
            reviewed: seen,
          ),
        ),
        throwsA(failure('conflict')),
      );
    },
  );

  test(
    'committed reply loss reconciles exact intent and reset restores fictional baseline',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final seen = await s.hosts.read(hangzhou);
      s.loseNextHostReply = true;
      final c = WorkspaceHostChange(
        operationId: 'lost',
        action: WorkspaceHostAction.confirm,
        reviewed: seen,
      );
      await expectLater(s.hosts.change(c), throwsA(failure('unknown_outcome')));
      final r = (await s.hosts.receipt('lost'))!;
      expect((await s.hosts.change(c)).version, r.version);
      await expectLater(
        s.hosts.change(
          WorkspaceHostChange(
            operationId: 'lost',
            action: WorkspaceHostAction.revoke,
            reviewed: seen,
          ),
        ),
        throwsA(failure('operation_conflict')),
      );
      expect((await s.hosts.read(hangzhou)).state, WorkspaceHostState.trusted);
      s.reset();
      expect(
        (await s.hosts.read(hangzhou)).state,
        WorkspaceHostState.unconfirmed,
      );
      expect((await s.hosts.read(tokyo)).state, WorkspaceHostState.trusted);
      expect(await s.hosts.receipt('lost'), isNull);
      s.setScenario(SampleWorkspaceScenario.empty);
      expect(await s.hosts.load(), isEmpty);
    },
  );

  test(
    'unknown mutation freezes replay and validates the original receipt; negative result permits only explicit new intent',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final seen = await s.hosts.read(hangzhou);
      final f = _DeferredHosts();
      final mutation = HostMutation(f);
      addTearDown(mutation.dispose);
      final pending = mutation.submit(seen, WorkspaceHostAction.confirm);
      expect(mutation.frozen, true);
      f.commit.completeError(StateError('lost'));
      expect(await pending, isNull);
      expect(mutation.uncertain, true);
      await mutation.submit(seen, WorkspaceHostAction.revoke);
      expect(f.writes, 1);
      f.failRead = true;
      await mutation.reconcile();
      expect(mutation.uncertain, true);
      f.failRead = false;
      f.found = WorkspaceHostReceipt(
        operationId: f.command!.operationId,
        action: WorkspaceHostAction.confirm,
        identityId: seen.identityId,
        expectedVersion: seen.version,
        version: seen.version + 1,
        targetKey: 'information:another-record',
        expectedRecordVersion: seen.recordVersion,
        expectedPluginVersion: seen.pluginVersion,
      );
      await mutation.reconcile();
      expect(mutation.uncertain, true);
      f.found = WorkspaceHostReceipt(
        operationId: 'wrong',
        action: WorkspaceHostAction.confirm,
        identityId: seen.identityId,
        expectedVersion: seen.version,
        version: seen.version + 1,
        targetKey: seen.target.key,
        expectedRecordVersion: seen.recordVersion,
        expectedPluginVersion: seen.pluginVersion,
      );
      await mutation.reconcile();
      expect(mutation.uncertain, true);
      f.found = null;
      await mutation.reconcile();
      expect(mutation.canSubmit, true);
      expect(f.writes, 1);
    },
  );

  test(
    'a late host result cannot update a disposed controller or become a new submission',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final seen = await s.hosts.read(hangzhou);
      final f = _DeferredHosts();
      final actual = HostMutation(f);
      var notifications = 0;
      actual.addListener(() => notifications++);
      final pending = actual.submit(seen, WorkspaceHostAction.confirm);
      expect(notifications, 1);
      actual.dispose();
      f.commit.completeError(StateError('lost after close'));
      expect(await pending, isNull);
      expect(notifications, 1);
      expect(await actual.submit(seen, WorkspaceHostAction.revoke), isNull);
      expect(f.writes, 1);
    },
  );

  test(
    'different server records at the same normalized endpoint share revocation, independent of their names',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final detail = await s.readDetail(aliyun);
      await s.saveRecord(
        WorkspaceEdit(
          operationId: 'same-endpoint',
          expectedVersion: detail.version,
          record: detail.record,
          values: {'host': 'TOKYO.BEICHEN.EXAMPLE.', 'port': '2222'},
        ),
      );
      final other = await s.hosts.read(hangzhou);
      expect(other.state, WorkspaceHostState.trusted);
      expect(other.identityId, (await s.hosts.read(tokyo)).identityId);
      await s.hosts.change(
        WorkspaceHostChange(
          operationId: 'shared-revoke',
          action: WorkspaceHostAction.revoke,
          reviewed: other,
        ),
      );
      expect((await s.hosts.read(tokyo)).state, WorkspaceHostState.revoked);
      expect((await s.hosts.read(hangzhou)).state, WorkspaceHostState.revoked);
      expect((await s.readDetail(azure)).version, 1);
    },
  );
}
