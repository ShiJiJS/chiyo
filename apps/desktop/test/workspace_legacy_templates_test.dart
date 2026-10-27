import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/legacy_templates_controller.dart';
import 'package:info_desktop/workspace/plugin_authoring_guide.dart';
import 'package:info_desktop/workspace/plugin_mutation.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/template_package_decoder.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

WorkspaceCreate legacyDraft(
  WorkspaceLegacyTemplate t, {
  String? operation,
  Map<String, String>? files,
}) => WorkspaceCreate(
  operationId: operation ?? workspaceOperationId(),
  typeId: 'generic',
  name: '独立旧版录入',
  legacyTemplateId: t.id,
  expectedLegacyVersion: t.version,
  values: {
    for (final f in t.definition['fields'] as List)
      if (f['type'] != 'file') f['key'] as String: '合成内容',
  },
  fileSelections: files ?? {},
);

class _DeferredLegacy extends Fake implements WorkspaceLegacyTemplateSource {
  final reads = <Completer<List<WorkspaceLegacyTemplate>>>[];
  @override
  Future<List<WorkspaceLegacyTemplate>> load() {
    final c = Completer<List<WorkspaceLegacyTemplate>>();
    reads.add(c);
    return c.future;
  }
}

void main() {
  Matcher failure(String code) =>
      isA<WorkspaceFailure>().having((e) => e.code, 'code', code);
  WorkspaceFailure rejected(WorkspaceSaveResult value) =>
      (value as WorkspaceRejected).failure;
  test(
    'legacy templates remain form aids; each generic record gets independent instance identities and a versioned source map',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final t = await s.legacyTemplates.read('legacy-resource');
      final a = (await s.createRecord(legacyDraft(t))) as WorkspaceSaved,
          b = (await s.createRecord(legacyDraft(t))) as WorkspaceSaved;
      expect(a.detail.record.type.id, 'generic');
      expect(a.detail.record.ref, isNot(b.detail.record.ref));
      expect(a.detail.definition, t.definition);
      expect(a.detail.definition['packageId'], isNull);
      expect(
        a.detail.definition['legacyDefinitionIds'],
        t.definition['legacyDefinitionIds'],
      );
      expect(
        a.detail.fieldIds.values.toSet().intersection(
          b.detail.fieldIds.values.toSet(),
        ),
        isEmpty,
      );
      expect(
        a.detail.fieldIds.values.toSet().intersection(
          t.fields.map((f) => f.id).toSet(),
        ),
        isEmpty,
      );
      final before = a.detail;
      s.reviseLegacyTemplate(t.id);
      expect(
        (await s.readDetail(before.record.ref)).definition,
        before.definition,
      );
      expect(rejected(await s.createRecord(legacyDraft(t))).code, 'conflict');
      final fresh = await s.legacyTemplates.read(t.id);
      expect(fresh.version, 2);
      expect(fresh.fields.first.id, isNot(t.fields.first.id));
      expect(
        rejected(
          await s.createRecord(
            WorkspaceCreate(
              operationId: 'missing-map',
              typeId: 'generic',
              name: '缺字段',
              legacyTemplateId: fresh.id,
              expectedLegacyVersion: fresh.version,
            ),
          ),
        ).code,
        'validation',
      );
    },
  );
  test(
    'legacy file fields require typed selections and create ordinary attachments atomically; existing file APIs still work',
    () async {
      final s = SampleWorkspaceSource(readAsset: (p) => File(p).readAsBytes());
      addTearDown(s.dispose);
      final t = await s.legacyTemplates.read('legacy-handover'),
          fields = t.definition['fields'] as List;
      final key =
          fields.singleWhere((f) => f['type'] == 'file')['key'] as String;
      final count = (await s.loadSummary()).records;
      expect(rejected(await s.createRecord(legacyDraft(t))).code, 'validation');
      expect((await s.loadSummary()).records, count);
      s.nextSaveFailure = const WorkspaceFailure('offline', '合成失败');
      expect(
        rejected(
          await s.createRecord(
            legacyDraft(t, operation: 'failed-file', files: {key: 'image'}),
          ),
        ).code,
        'offline',
      );
      expect(await s.recordOperationReceipt('failed-file'), isNull);
      expect((await s.loadSummary()).records, count);
      final saved =
          (await s.createRecord(legacyDraft(t, files: {key: 'image'})))
              as WorkspaceSaved;
      final h = await s.loadFileHistory(saved.detail.record.ref, key);
      expect(h.current.ref.version, 1);
      expect(h.versions, hasLength(1));
      expect(
        (await s.readFilePreview(saved.detail.record.ref, key)).kind,
        WorkspaceFilePreviewKind.image,
      );
      await s.changeFile(
        WorkspaceFileChange(
          operationId: 'legacy-replace',
          record: saved.detail.record.ref,
          fieldKey: key,
          expectedRecordVersion: saved.detail.version,
          expectedFileVersion: 1,
          kind: WorkspaceFileChangeKind.replace,
          selectionId: 'pdf-v2',
        ),
      );
      expect(
        (await s.loadFileHistory(saved.detail.record.ref, key)).versions,
        hasLength(2),
      );
      expect(
        rejected(
          await s.createRecord(
            WorkspaceCreate(
              operationId: 'file-forgery',
              typeId: 'generic',
              name: '不能绕过',
              fileSelections: {key: 'image'},
            ),
          ),
        ).code,
        'unsupported',
      );
    },
  );
  test(
    'concurrent legacy changes or a reset during attachment verification cannot partially create a record',
    () async {
      for (final reset in [false, true]) {
        final started = Completer<void>(), gate = Completer<void>();
        var held = false;
        final s = SampleWorkspaceSource(
          readAsset: (p) async {
            if (!held) {
              held = true;
              started.complete();
              await gate.future;
            }
            return File(p).readAsBytes();
          },
        );
        addTearDown(s.dispose);
        final t = await s.legacyTemplates.read('legacy-handover'),
            key =
                (t.definition['fields'] as List).singleWhere(
                      (f) => f['type'] == 'file',
                    )['key']
                    as String;
        final count = (await s.loadSummary()).records;
        final pending = s.createRecord(legacyDraft(t, files: {key: 'image'}));
        await started.future;
        if (reset) {
          s.reset();
        } else {
          s.reviseLegacyTemplate(t.id);
        }
        gate.complete();
        expect(rejected(await pending).code, reset ? 'cancelled' : 'conflict');
        expect((await s.loadSummary()).records, count);
      }
    },
  );
  test(
    'concurrent attachment deliveries commit once and reject reused operation identities with different input',
    () async {
      final started = Completer<void>(), gate = Completer<void>();
      var held = false;
      final s = SampleWorkspaceSource(
        readAsset: (p) async {
          if (!held && !p.endsWith('manifest.json')) {
            held = true;
            started.complete();
            await gate.future;
          }
          return File(p).readAsBytes();
        },
      );
      addTearDown(s.dispose);
      final t = await s.legacyTemplates.read('legacy-handover'),
          key =
              (t.definition['fields'] as List).singleWhere(
                    (f) => f['type'] == 'file',
                  )['key']
                  as String,
          count = (await s.loadSummary()).records;
      final draft = legacyDraft(
        t,
        operation: 'concurrent-file',
        files: {key: 'image'},
      );
      final delayed = s.createRecord(draft);
      await started.future;
      final first = (await s.createRecord(draft)) as WorkspaceSaved;
      gate.complete();
      final repeated = (await delayed) as WorkspaceSaved;
      expect(repeated.detail.record.ref, first.detail.record.ref);
      expect((await s.loadSummary()).records, count + 1);
      expect(
        (await s.loadFileHistory(first.detail.record.ref, key)).versions,
        hasLength(1),
      );
      expect(
        rejected(
          await s.createRecord(
            legacyDraft(
              t,
              operation: draft.operationId,
              files: {key: 'pdf-v2'},
            ),
          ),
        ).code,
        'operation_conflict',
      );
      expect(
        (await s.recordOperationReceipt(draft.operationId))!.result.ref,
        first.detail.record.ref,
      );
    },
  );
  test(
    'conversion uses the same declarative decoder and explicit install, keeps provenance and never migrates records',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final t = await s.legacyTemplates.read('legacy-resource'),
          before = (await s.createRecord(legacyDraft(t))) as WorkspaceSaved;
      final c = await s.legacyTemplates.prepareConversion(t.id, t.version),
          p = await s.plugins.previewInstall(c.selectionId);
      expect((await s.plugins.load()).packages, hasLength(3));
      expect(p.package.id, t.packageId);
      expect(p.package.version, '1.1.0');
      expect(p.package.legacySource!['templateId'], t.id);
      expect(
        p.package.legacySource!['definitionIds'],
        t.definition['legacyDefinitionIds'],
      );
      expect(p.package.panels, isEmpty);
      final receipt = await s.plugins.change(
        WorkspacePluginChange(
          operationId: 'convert',
          action: WorkspacePluginAction.install,
          packageId: p.package.id,
          expectedVersion: p.catalogVersion,
          selectionId: c.selectionId,
          expectedDigest: p.package.digest,
        ),
      );
      await s.plugins.releaseCandidate(c.selectionId);
      expect(
        (await s.readDetail(before.detail.record.ref)).definition,
        before.detail.definition,
      );
      expect(
        (await s.readDetail(before.detail.record.ref)).fieldIds,
        before.detail.fieldIds,
      );
      final installed = (await s.plugins.load()).packages.singleWhere(
        (p) => p.id == receipt.packageId,
      );
      final created =
          (await s.createRecord(
                WorkspaceCreate(
                  operationId: 'converted-create',
                  typeId: installed.templates.single.type.id,
                  name: '新插件资料',
                  expectedTemplateVersion: installed.version,
                  expectedTemplateDigest: installed.digest,
                ),
              ))
              as WorkspaceSaved;
      expect(created.detail.definition['legacySource'], installed.legacySource);
      expect((await s.createRecord(legacyDraft(t))), isA<WorkspaceSaved>());
    },
  );
  test(
    'conversion guards the original legacy version before install; a new version changes only new definitions',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final t = await s.legacyTemplates.read('legacy-resource'),
          c = await s.legacyTemplates.prepareConversion(t.id, t.version);
      final p = await s.plugins.previewInstall(c.selectionId);
      s.reviseLegacyTemplate(t.id);
      await expectLater(
        s.plugins.change(
          WorkspacePluginChange(
            operationId: 'stale-conversion',
            action: WorkspacePluginAction.install,
            packageId: p.package.id,
            expectedVersion: p.catalogVersion,
            selectionId: c.selectionId,
            expectedDigest: p.package.digest,
          ),
        ),
        throwsA(failure('conflict')),
      );
      expect((await s.plugins.load()).packages, hasLength(3));
      final fresh = await s.legacyTemplates.read(t.id),
          next = await s.legacyTemplates.prepareConversion(
            fresh.id,
            fresh.version,
          );
      final preview = await s.plugins.previewInstall(next.selectionId);
      expect(preview.package.id, p.package.id);
      expect(preview.package.version, '1.2.0');
      expect(
        preview.package.templates.single.definition['fields'],
        isNot(p.package.templates.single.definition['fields']),
      );
      await s.plugins.releaseCandidate(c.selectionId);
      await s.plugins.releaseCandidate(next.selectionId);
    },
  );
  test(
    'file and oversized legacy templates stay usable but cannot be lossy-converted to hostApi1',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final file = await s.legacyTemplates.read('legacy-handover');
      await expectLater(
        s.legacyTemplates.prepareConversion(file.id, file.version),
        throwsA(failure('conversion_unsupported')),
      );
      final large = SampleWorkspaceSource(
        legacyInputs: [
          (
            id: 'large',
            name: '较多字段',
            description: '兼容结构',
            fields: [
              for (var i = 0; i < 200; i++)
                WorkspaceLegacyField(
                  'old-definition-$i',
                  '字段$i',
                  '用途$i',
                  WorkspaceLegacyFieldKind.structured,
                ),
            ],
          ),
        ],
      );
      addTearDown(large.dispose);
      final t = await large.legacyTemplates.read('large');
      expect((await large.createRecord(legacyDraft(t))), isA<WorkspaceSaved>());
      await expectLater(
        large.legacyTemplates.prepareConversion(t.id, t.version),
        throwsA(failure('conversion_unsupported')),
      );
    },
  );
  test(
    'lost conversion reply reconciles after the source changed and lease released, without re-installing or losing provenance',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final m = PluginMutation(s.plugins);
      addTearDown(m.dispose);
      final t = await s.legacyTemplates.read('legacy-resource'),
          c = await s.legacyTemplates.prepareConversion(t.id, t.version),
          p = await s.plugins.previewInstall(c.selectionId);
      s.loseNextPluginReply = true;
      await m.submit(
        (id) => WorkspacePluginChange(
          operationId: id,
          action: WorkspacePluginAction.install,
          packageId: p.package.id,
          expectedVersion: p.catalogVersion,
          selectionId: c.selectionId,
          expectedDigest: p.package.digest,
        ),
      );
      expect(m.uncertain, true);
      s.reviseLegacyTemplate(t.id);
      await s.plugins.releaseCandidate(c.selectionId);
      expect((await m.reconcile())!.digest, p.package.digest);
      final installed = (await s.plugins.load()).packages.singleWhere(
        (n) => n.id == p.package.id,
      );
      expect(installed.legacySource!['version'], 1);
      expect(installed.version, '1.1.0');
    },
  );
  test(
    'legacy controller discards stale reads, distinguishes real empty and contains failures after disposal',
    () async {
      final s = SampleWorkspaceSource();
      addTearDown(s.dispose);
      final item = await s.legacyTemplates.read('legacy-resource');
      final f = _DeferredLegacy(),
          changes = StreamController<WorkspaceRecordRef?>.broadcast(),
          model = LegacyTemplatesController(f, changes.stream);
      addTearDown(changes.close);
      final a = model.load(), b = model.load();
      expect(model.templates, isNull);
      f.reads[1].complete([item]);
      await b;
      f.reads[0].complete([]);
      await a;
      expect(model.selected!.id, item.id);
      final c = model.load();
      f.reads[2].completeError(StateError('offline'));
      await c;
      expect(model.failure, isNotNull);
      expect(model.selected!.id, item.id);
      final d = model.load();
      f.reads[3].complete([]);
      await d;
      expect(model.templates, isEmpty);
      final e = model.load();
      model.dispose();
      f.reads[4].completeError(StateError('late'));
      await e;
    },
  );
  test(
    'the authoring example passes the real decoder and cannot forge host conversion provenance',
    () {
      final bytes = utf8.encode(authoringExample),
          decoder = TemplatePackageDecoder();
      final package = decoder.decode(bytes, origin: 'guide.json');
      expect(package.id, 'local.resource');
      expect(package.legacySource, isNull);
      expect(pluginAuthoringBrief, contains('录入提案'));
      expect(pluginAuthoringBrief, contains('不包含秘密'));
      final forged = jsonDecode(authoringExample) as Map<String, dynamic>;
      forged['legacySource'] = {'templateId': 'forged'};
      expect(
        () => decoder.decode(
          utf8.encode(jsonEncode(forged)),
          origin: 'forged.json',
        ),
        throwsA(failure('invalid_package')),
      );
    },
  );
}
