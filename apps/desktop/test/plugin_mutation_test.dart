import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/plugin_mutation.dart';
import 'package:info_desktop/workspace/plugins_controller.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class DeferredPlugins extends Fake implements WorkspacePluginSource {
  final reads = <Completer<WorkspacePluginCatalog>>[];
  @override
  Future<WorkspacePluginCatalog> load() {
    final c = Completer<WorkspacePluginCatalog>();
    reads.add(c);
    return c.future;
  }
}

void main() {
  Future<WorkspacePluginPreview> preview(SampleWorkspaceSource s) async {
    final choices = await s.pluginChoices();
    final c = choices.first;
    for (final other in choices.skip(1)) {
      await s.plugins.releaseCandidate(other.selectionId);
    }
    return s.plugins.previewInstall(c.selectionId);
  }

  WorkspacePluginChange command(String id, WorkspacePluginPreview p) =>
      WorkspacePluginChange(
        operationId: id,
        action: WorkspacePluginAction.install,
        packageId: p.package.id,
        expectedVersion: p.catalogVersion,
        selectionId: p.selectionId,
        expectedDigest: p.package.digest,
      );

  test(
    'committed reply loss freezes original action through failed lookup, then reconciles without reinstalling',
    () async {
      final s = SampleWorkspaceSource();
      final m = PluginMutation(s.plugins);
      addTearDown(s.dispose);
      addTearDown(m.dispose);
      final p = await preview(s);
      var builds = 0;
      s.loseNextPluginReply = true;
      expect(
        await m.submit((id) {
          builds++;
          return command(id, p);
        }),
        isNull,
      );
      expect(m.frozen, isTrue);
      expect((await s.plugins.load()).packages, hasLength(4));
      s.setScenario(SampleWorkspaceScenario.failure);
      expect(await m.reconcile(), isNull);
      m.reviewed();
      expect(
        await m.submit((id) {
          builds++;
          return command(id, p);
        }),
        isNull,
      );
      expect(builds, 1);
      s.setScenario(SampleWorkspaceScenario.ready);
      final result = await m.reconcile();
      expect(result!.packageId, p.package.id);
      expect(builds, 1);
      expect((await s.plugins.load()).packages, hasLength(4));
      await s.plugins.releaseCandidate(p.selectionId);
      expect(
        (await s.plugins.receipt(result.operationId))!.packageId,
        p.package.id,
      );
    },
  );
  test(
    'confirmed absence permits one explicit new operation identity and released selections cannot be installed',
    () async {
      final s = SampleWorkspaceSource();
      final m = PluginMutation(s.plugins);
      addTearDown(s.dispose);
      addTearDown(m.dispose);
      final p = await preview(s), ids = <String>[];
      s.nextSaveFailure = const WorkspaceFailure('unknown_outcome', '未知');
      await m.submit((id) {
        ids.add(id);
        return command(id, p);
      });
      expect(await m.reconcile(), isNull);
      expect(m.canSubmit, isTrue);
      expect(ids, hasLength(1));
      final result = await m.submit((id) {
        ids.add(id);
        return command(id, p);
      });
      expect(result, isNotNull);
      expect(ids.toSet(), hasLength(2));
      final second = await s.pluginChoices();
      final update = second.firstWhere((c) => c.filename == '域名管理-1.1.0.json');
      for (final c in second) {
        await s.plugins.releaseCandidate(c.selectionId);
      }
      await expectLater(
        s.plugins.previewInstall(update.selectionId),
        throwsA(isA<WorkspaceFailure>()),
      );
    },
  );
  test(
    'projection discards late reads, preserves current metadata on failed refresh and filters without loading record values',
    () async {
      final source = DeferredPlugins(),
          changes = StreamController<WorkspaceRecordRef?>.broadcast();
      final c = PluginsController(source, changes.stream);
      addTearDown(c.dispose);
      addTearDown(changes.close);
      final first = c.load(), second = c.load();
      source.reads[1].complete(WorkspacePluginCatalog(2, []));
      await second;
      source.reads[0].complete(WorkspacePluginCatalog(1, []));
      await first;
      expect(c.catalog!.version, 2);
      final pending = c.load();
      source.reads[2].completeError(const WorkspaceFailure('offline', '读取失败'));
      await pending;
      expect(c.catalog!.version, 2);
      expect(c.failure!.code, 'offline');
      expect(c.loading, isFalse);
      c.setFilter(PluginFilter.disabled);
      expect(c.visible, isEmpty);
    },
  );
}
