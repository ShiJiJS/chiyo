import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/host_import_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');

class _ReceiptSwap extends Fake implements WorkspaceHostSource {
  _ReceiptSwap(this.inner);
  final WorkspaceHostSource inner;
  bool wrong = true;
  @override
  Future<WorkspaceHostImportPreview> previewImport(String id) =>
      inner.previewImport(id);
  @override
  Future<void> releaseImport(String id) => inner.releaseImport(id);
  WorkspaceHostImportReceipt swap(WorkspaceHostImportReceipt r) => !wrong
      ? r
      : WorkspaceHostImportReceipt(
          operationId: 'another-import',
          selectionId: r.selectionId,
          expectedVersion: r.expectedVersion,
          expectedPluginVersion: r.expectedPluginVersion,
          result: r.result,
        );
  @override
  Future<WorkspaceHostImportReceipt> importFile(
    WorkspaceHostImportChange c,
  ) async => swap(await inner.importFile(c));
  @override
  Future<WorkspaceHostImportReceipt?> importReceipt(String id) async {
    final r = await inner.importReceipt(id);
    return r == null ? null : swap(r);
  }
}

void main() {
  Matcher code(String value) =>
      isA<WorkspaceFailure>().having((e) => e.code, 'code', value);
  SampleWorkspaceSource source() {
    final s = SampleWorkspaceSource();
    addTearDown(s.dispose);
    return s;
  }

  Future<WorkspaceHostFile> file(
    SampleWorkspaceSource s, {
    bool invalid = false,
  }) async {
    final choices = await s.hostFileChoices(),
        chosen = invalid ? choices.last : choices.first;
    for (final f in choices) {
      if (f != chosen) await s.hosts.releaseImport(f.selectionId);
    }
    return chosen;
  }

  test(
    'host-owned update is real metadata, preserves old instance snapshots and does not grant host trust',
    () async {
      final s = source(),
          before = await s.readDetail(azure),
          catalog = await s.plugins.load();
      final offer = catalog.updates.single;
      expect(offer.packageId, 'builtin.server');
      final selected = await s.plugins.prepareUpdate(offer, catalog.version);
      final preview = await s.plugins.previewInstall(selected.selectionId);
      expect(preview.package.builtin, true);
      expect(preview.package.panels, {WorkspacePluginPanel.sshTrust});
      expect(preview.differences, contains('新增字段：维护负责人'));
      await s.plugins.change(
        WorkspacePluginChange(
          operationId: 'bundled-update',
          action: WorkspacePluginAction.install,
          packageId: offer.packageId,
          expectedVersion: preview.catalogVersion,
          expectedDigest: preview.package.digest,
          selectionId: selected.selectionId,
        ),
      );
      await s.plugins.releaseCandidate(selected.selectionId);
      expect((await s.plugins.load()).updates, isEmpty);
      expect((await s.loadTemplate('server'))['templateVersion'], '1.1.0');
      final after = await s.readDetail(azure);
      expect(after.version, before.version);
      expect(after.definition, before.definition);
      expect(
        (await s.hosts.read(const WorkspaceHostTarget.record(azure))).state,
        WorkspaceHostState.trusted,
      );
      await expectLater(
        s.plugins.prepareUpdate(offer, catalog.version),
        throwsA(code('conflict')),
      );
      s.reset();
      expect((await s.plugins.load()).updates.single.version, '1.1.0');
      await expectLater(
        s.plugins.previewInstall(selected.selectionId),
        throwsA(code('selection_unavailable')),
      );
    },
  );

  test(
    'file selection and invalid format never mutate imported status; confirmed bytes survive lease release',
    () async {
      final s = source(),
          first = await file(s),
          before = await s.hosts.read(const WorkspaceHostTarget.record(azure));
      final p = await s.hosts.previewImport(first.selectionId);
      expect(p.entries, hasLength(2));
      expect(p.entries.first.pattern, '[demo-import.example]:2222');
      expect(p.entries.first.fingerprint, startsWith('SHA256:'));
      expect(await s.hosts.importedFile(), isNull);
      final receipt = await s.hosts.importFile(
        WorkspaceHostImportChange('import-one', p),
      );
      await s.hosts.releaseImport(first.selectionId);
      final saved = await s.hosts.importedFile();
      expect(saved!.digest, receipt.result.digest);
      expect(saved.entryCount, 2);
      final invalid = await file(s, invalid: true);
      await expectLater(
        s.hosts.previewImport(invalid.selectionId),
        throwsA(code('invalid_ssh_known_hosts')),
      );
      expect((await s.hosts.importedFile())!.version, saved.version);
      final after = await s.hosts.read(const WorkspaceHostTarget.record(azure));
      expect(after.state, before.state);
      expect(after.trustedFingerprint, before.trustedFingerprint);
    },
  );

  test(
    'failed and stale file imports preserve the previous file and exact host/plugin review',
    () async {
      final s = source(),
          selected = await file(s),
          p = await s.hosts.previewImport(selected.selectionId);
      s.nextSaveFailure = const WorkspaceFailure('disk_full', '合成写入失败');
      await expectLater(
        s.hosts.importFile(WorkspaceHostImportChange('failed', p)),
        throwsA(code('disk_full')),
      );
      expect(await s.hosts.importedFile(), isNull);
      final host = await s.hosts.read(const WorkspaceHostTarget.record(azure));
      await s.hosts.change(
        WorkspaceHostChange(
          operationId: 'revoke-host',
          action: WorkspaceHostAction.revoke,
          reviewed: host,
        ),
      );
      await expectLater(
        s.hosts.importFile(WorkspaceHostImportChange('stale', p)),
        throwsA(code('conflict')),
      );
      final current = await s.hosts.previewImport(selected.selectionId);
      await s.hosts.importFile(WorkspaceHostImportChange('fresh', current));
      final saved = await s.hosts.importedFile(),
          cat = await s.plugins.load(),
          server = cat.packages.firstWhere((p) => p.id == 'builtin.server');
      await s.plugins.change(
        WorkspacePluginChange(
          operationId: 'disable',
          action: WorkspacePluginAction.disable,
          packageId: server.id,
          expectedVersion: cat.version,
          expectedDigest: server.digest,
        ),
      );
      await expectLater(
        s.hosts.previewImport(selected.selectionId),
        throwsA(code('unavailable')),
      );
      expect((await s.hosts.importedFile())!.digest, saved!.digest);
    },
  );

  test(
    'lost import reply freezes writes and reconciles the original receipt without replay',
    () async {
      final s = source(), m = HostImportController(s.hosts);
      addTearDown(m.dispose);
      final selected = await file(s);
      await m.pick(() async => selected);
      s.loseNextHostImportReply = true;
      await m.submit();
      expect(m.uncertain, true);
      final committed = await s.hosts.importedFile();
      await m.submit();
      expect((await s.hosts.importedFile())!.version, committed!.version);
      await m.reconcile();
      expect(m.uncertain, false);
      expect(m.result!.result.version, committed.version);
      expect((await s.hosts.importedFile())!.version, committed.version);
    },
  );

  test(
    'a mismatched receipt cannot complete an import or release the unknown-operation gate',
    () async {
      final s = source(),
          wrong = _ReceiptSwap(s.hosts),
          m = HostImportController(wrong);
      addTearDown(m.dispose);
      await m.pick(() => file(s));
      await m.submit();
      expect(m.uncertain, true);
      expect(m.result, isNull);
      await m.reconcile();
      expect(m.uncertain, true);
      wrong.wrong = false;
      await m.reconcile();
      expect(m.result, isNotNull);
      expect(m.uncertain, false);
    },
  );
}
