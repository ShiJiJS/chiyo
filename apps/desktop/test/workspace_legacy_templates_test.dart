import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/plugin_authoring_guide.dart';
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
