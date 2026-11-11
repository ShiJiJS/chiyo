import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_workspace_file_selections.dart';
import 'package:info_desktop/workspace/owner_workspace_plugins.dart';
import 'package:info_desktop/workspace/owner_workspace_legacy_templates.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async {
    value = List.of(key);
  }
}

class _Picker implements InformationFilePicker {
  String? path;
  @override
  Future<String?> choose() async => path;
  @override
  Future<String?> saveAs(String name) async => null;
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late OwnerWorkspacePlugins plugins;
  late OwnerWorkspaceLegacyTemplates legacy;
  late _Picker picker;
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
    picker = _Picker();
    plugins = OwnerWorkspacePlugins(
      owner: service.owner,
      picker: picker,
      changed: () => source.notifyExternalChange(),
    );
    legacy = OwnerWorkspaceLegacyTemplates(service.owner);
    source = OwnerWorkspaceSource(
      owner: service.owner,
      fileSelections: OwnerWorkspaceFileSelections(
        service.owner,
        picker: picker,
      ),
      plugins: plugins,
      legacyTemplates: legacy,
      definitionsReader: () => plugins.templates,
      templateState: plugins.stateFor,
      refreshInterval: Duration.zero,
    );
  }

  Future<void> close() async {
    plugins.dispose();
    await source.dispose();
    await service.close();
    await repo.close();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-plugins-');
    keys = _Keys();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Map<String, Object?> package(String version, {bool extra = false}) => {
    'id': 'local.synthetic',
    'name': '合成插件',
    'version': version,
    'hostApi': 1,
    'author': '合成测试',
    'description': '',
    'templates': [
      {
        'id': 'record',
        'name': '合成资料',
        'icon': 'file',
        'instructions': '',
        'fields': [
          {'key': 'body', 'label': '内容', 'type': 'text', 'required': false},
          if (extra)
            {
              'key': 'extra',
              'label': '新增字段',
              'type': 'text',
              'required': false,
            },
        ],
        'sections': [
          {
            'kind': 'fields',
            'title': '资料',
            'keys': ['body', if (extra) 'extra'],
          },
        ],
        'relations': [],
      },
    ],
  };
  Future<WorkspacePluginReceipt> install(
    String version, {
    bool extra = false,
  }) async {
    final file = File('${root.path}/package.json');
    await file.writeAsString(jsonEncode(package(version, extra: extra)));
    picker.path = file.path;
    final selected = await plugins.pick();
    expect(selected!.selectionId, isNot(contains(root.path)));
    final preview = await plugins.previewInstall(selected.selectionId);
    return plugins.change(
      WorkspacePluginChange(
        operationId: workspaceOperationId(),
        action: WorkspacePluginAction.install,
        packageId: preview.package.id,
        expectedVersion: preview.catalogVersion,
        selectionId: selected.selectionId,
        expectedDigest: preview.package.digest,
      ),
    );
  }

  Future<void> toggle(WorkspacePluginAction action) async {
    final catalog = await plugins.load();
    await plugins.change(
      WorkspacePluginChange(
        operationId: workspaceOperationId(),
        action: action,
        packageId: 'local.synthetic',
        expectedVersion: catalog.version,
      ),
    );
  }

  Future<WorkspaceRecordRef> create(
    String type, {
    String value = '合成正文',
  }) async {
    final definition = await source.loadTemplate(type);
    final result = await source.createRecord(
      WorkspaceCreate(
        operationId: workspaceOperationId(),
        typeId: type,
        name: '合成实例',
        expectedTemplateVersion: definition['templateVersion'] as String?,
        expectedTemplateDigest: definition['packageDigest'] as String?,
        values: {
          for (final f in definition['fields'] as List)
            f['key'] as String: value,
        },
      ),
    );
    expect(result, isA<WorkspaceSaved>());
    return (result as WorkspaceSaved).detail.record.ref;
  }

  test(
    'normal package selection/install and real creation, disable/update/remove preserve frozen instances',
    () async {
      final installed = await install('1.0.0');
      expect(
        (await source.loadCatalog()).creatableTypes.any(
          (t) => t.id == 'local.synthetic/record',
        ),
        isTrue,
      );
      final ref = await create('local.synthetic/record'),
          before = await source.readDetail(
            await create('local.synthetic/record', value: '另一合成值'),
          );
      await toggle(WorkspacePluginAction.disable);
      expect(
        (await source.loadCatalog()).creatableTypes.any(
          (t) => t.id == 'local.synthetic/record',
        ),
        isFalse,
      );
      final disabled = await source.readDetail(ref);
      expect(disabled.templateState, WorkspaceTemplateState.disabled);
      expect(disabled.values['body'], '合成正文');
      final edited = await source.saveRecord(
        WorkspaceEdit(
          operationId: workspaceOperationId(),
          expectedVersion: disabled.version,
          record: disabled.record,
          values: {'body': '主人编辑'},
        ),
      );
      expect(edited, isA<WorkspaceSaved>());
      await install('2.0.0', extra: true);
      await toggle(WorkspacePluginAction.enable);
      final frozen = await source.readDetail(before.record.ref);
      expect(frozen.definition, before.definition);
      expect(frozen.values, before.values);
      final newRef = await create('local.synthetic/record');
      expect(
        (await source.readDetail(newRef)).values.containsKey('extra'),
        isTrue,
      );
      await toggle(WorkspacePluginAction.remove);
      expect(
        (await source.readDetail(ref)).templateState,
        WorkspaceTemplateState.missing,
      );
      await close();
      await open();
      expect((await source.readDetail(ref)).values['body'], '主人编辑');
      expect(
        (await plugins.receipt(installed.operationId))!.digest,
        installed.digest,
      );
    },
  );
  test(
    'legacy entry and adoption preserve identities and original receipts across reopen',
    () async {
      final old = await service.owner.createTemplate('合成旧模板', '', [
        const core.TemplateFieldInput('原字段', ''),
        const core.TemplateFieldInput('保留字段', ''),
      ]);
      final legacyDefinition = await legacy.read(old.id);
      final op = workspaceOperationId();
      final created = await source.createRecord(
        WorkspaceCreate(
          operationId: op,
          typeId: 'generic',
          name: '旧版录入',
          legacyTemplateId: old.id,
          expectedLegacyVersion: old.version,
          values: {
            for (final f in legacyDefinition.definition['fields'] as List)
              f['key'] as String: '合成原文',
          },
        ),
      );
      expect(created, isA<WorkspaceSaved>());
      final detail = (created as WorkspaceSaved).detail;
      expect(
        (await source.recordOperationReceipt(op))!.intent.legacyTemplateId,
        old.id,
      );
      await install('1.0.0');
      final type = (await plugins.load()).packages
          .singleWhere((p) => p.id == 'local.synthetic')
          .templates
          .single
          .type
          .id;
      final oldKey = detail.fieldIds.keys.first,
          oldId = detail.fieldIds.values.first;
      final preview = await source.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: detail.record.ref,
          typeId: type,
          fields: {
            'body': WorkspaceFieldMapping(sourceKey: oldKey, sameMeaning: true),
          },
        ),
      );
      expect(preview.errors, isEmpty);
      expect((await source.readDetail(detail.record.ref)).version, 1);
      final adoptOp = workspaceOperationId();
      final receipt = await source.applyAdoption(adoptOp, preview.planId);
      expect(receipt.version, 2);
      final adopted = await source.readDetail(detail.record.ref);
      expect(adopted.fieldIds['body'], oldId);
      expect(adopted.retainedFields.length, 1);
      expect(adopted.values.values, everyElement('合成原文'));
      expect(service.owner.information.single.fields.length, 2);
      await close();
      await open();
      expect((await source.applyAdoption(adoptOp, preview.planId)).version, 2);
      expect(
        (await source.recordOperationReceipt(adoptOp))!.intent.planId,
        preview.planId,
      );
      final copy = await source.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: detail.record.ref,
          typeId: type,
          fields: {'body': const WorkspaceFieldMapping(sourceKey: 'body')},
        ),
      );
      expect(copy.errors, isEmpty);
      await source.applyAdoption(workspaceOperationId(), copy.planId);
      final copied = await source.readDetail(detail.record.ref);
      expect(copied.fieldIds['body'], isNot(oldId));
      expect(copied.fieldIds.values, contains(oldId));
      final cancelled = await source.previewAdoption(
        WorkspaceAdoptionDraft(ref: detail.record.ref, typeId: type),
      );
      await source.releaseAdoption(cancelled.planId);
      await expectLater(
        source.applyAdoption(workspaceOperationId(), cancelled.planId),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect((await source.readDetail(detail.record.ref)).version, 3);
      final stale = await source.previewAdoption(
        WorkspaceAdoptionDraft(ref: detail.record.ref, typeId: type),
      );
      await toggle(WorkspacePluginAction.disable);
      await expectLater(
        source.applyAdoption(workspaceOperationId(), stale.planId),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect((await source.readDetail(detail.record.ref)).version, 3);
    },
  );
  test(
    'adoption retains real attachment identity, bytes and original classification',
    () async {
      final old = await service.owner.createTemplate('合成附件模板', '', [
        const core.TemplateFieldInput('标题', ''),
        const core.TemplateFieldInput('附件', '', kind: core.FieldKind.file),
      ]);
      final definition = (await legacy.read(old.id)).definition,
          fields = definition['fields'] as List;
      final file = File('${root.path}/合成附件.txt');
      await file.writeAsString('SYNTHETIC-ORIGINAL');
      picker.path = file.path;
      final selected = (await source.selections.pick())!;
      final directory = await service.owner.createDirectory('合成目录');
      final saved = await source.createRecord(
        WorkspaceCreate(
          operationId: workspaceOperationId(),
          typeId: 'generic',
          name: '合成附件资料',
          directoryId: directory.id,
          legacyTemplateId: old.id,
          expectedLegacyVersion: old.version,
          values: {fields[0]['key'] as String: '合成标题'},
          fileSelections: {fields[1]['key'] as String: selected.selectionId},
        ),
      );
      final current = (saved as WorkspaceSaved).detail;
      final original = service.owner.information.single.fields.singleWhere(
        (f) => f.kind == core.FieldKind.file,
      );
      await install('1.0.0');
      final type = (await plugins.load()).packages
          .singleWhere((p) => p.id == 'local.synthetic')
          .templates
          .single
          .type
          .id;
      final preview = await source.previewAdoption(
        WorkspaceAdoptionDraft(
          ref: current.record.ref,
          typeId: type,
          fields: {
            'body': WorkspaceFieldMapping(
              sourceKey: fields[0]['key'] as String,
              sameMeaning: true,
            ),
          },
        ),
      );
      expect(preview.errors, isEmpty);
      await source.applyAdoption(workspaceOperationId(), preview.planId);
      final item = service.owner.information.single;
      final retained = item.fields.singleWhere(
        (f) => f.kind == core.FieldKind.file,
      );
      expect(retained.id, original.id);
      expect(retained.attachment, original.attachment);
      expect(
        utf8.decode(
          (await service.owner.readInformationAttachment(
            retained.attachment!,
          )).bytes,
        ),
        'SYNTHETIC-ORIGINAL',
      );
      expect(item.directoryId, directory.id);
      await close();
      await open();
      expect(
        (await source.readDetail(current.record.ref)).fieldIds.values,
        contains(original.id),
      );
    },
  );
}
