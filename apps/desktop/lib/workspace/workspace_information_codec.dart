import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'workspace_records.dart';
import 'workspace_entries.dart';
import 'workspace_files.dart';

/// Owner-only translation. No sample source, database or agent transport lives
/// here. Bodies remain in core fields; snapshots carry descriptors and order.
class WorkspaceInformationCodec {
  core.InformationRecordCommand createCommand(WorkspaceCreate draft) =>
      _command(draft.typeId, {
        'kind': 'create',
        'typeId': draft.typeId,
        'name': draft.name,
        'description': draft.description,
        'directoryId': draft.directoryId,
        'tagIds': draft.tagIds.toList()..sort(),
        'values': draft.values,
        'relations': _commandRelations(draft.relations),
        'fileSelections': draft.fileSelections,
        'expectedTemplateVersion': draft.expectedTemplateVersion,
        'expectedTemplateDigest': draft.expectedTemplateDigest,
        'legacyTemplateId': draft.legacyTemplateId,
        'expectedLegacyVersion': draft.expectedLegacyVersion,
      });

  core.InformationRecordCommand editCommand(WorkspaceEdit edit) =>
      _command(edit.record.type.id, {
        'kind': 'edit',
        'record': edit.record.ref.key,
        'expectedVersion': edit.expectedVersion,
        'typeId': edit.record.type.id,
        'name': edit.record.name,
        'description': edit.record.description,
        'directoryId': edit.record.directoryId,
        'tagIds': edit.record.tags.map((t) => t.id).toList()..sort(),
        'values': edit.values,
        'relations': _commandRelations(edit.relations),
      });

  Map<String, Object?> _commandRelations(
    Map<String, List<WorkspaceRecordRef>> relations,
  ) => {
    for (final e in relations.entries) e.key: [for (final r in e.value) r.key],
  };

  core.InformationRecordCommand _command(
    String type,
    Map<String, Object?> value,
  ) {
    Object? canonical(Object? value) => switch (value) {
      Map<String, Object?> map => {
        for (final key in map.keys.toList()..sort()) key: canonical(map[key]),
      },
      List list => list.map(canonical).toList(),
      _ => value,
    };
    return core.InformationRecordCommand(
      typeId: type,
      digest: sha256
          .convert(utf8.encode(jsonEncode(canonical(value))))
          .toString(),
    );
  }

  static String _fieldSlot(String key) => jsonEncode(['field', key]);
  static String _entrySlot(String key, String id, String part) =>
      jsonEncode(['entry', key, id, part]);
  static String _legacyKey(String id) => 'retained:$id';
  static const _textTypes = {'text', 'url', 'number', 'date', 'multiline'};

  WorkspaceDetail decode(
    core.InformationItem item, {
    Map<String, String> tagNames = const {},
  }) {
    final layout = item.layout;
    final snapshot = layout?.snapshot;
    final supported = snapshot?['codec'] == 'workspace-information-v1';
    if (layout == null || !supported) {
      final descriptors = [
        for (final f in item.fields) _descriptor(f, _legacyKey(f.id)),
      ];
      return WorkspaceDetail(
        record: summary(item, tagNames: tagNames),
        version: item.version,
        templateState: layout == null
            ? WorkspaceTemplateState.available
            : WorkspaceTemplateState.missing,
        definition: {
          'id': layout?.typeId ?? 'generic',
          'name': '通用资料',
          'fields': descriptors,
          'sections': [
            {
              'kind': 'fields',
              'title': '资料',
              'keys': [for (final f in descriptors) f['key']],
            },
          ],
          'relations': <Object?>[],
        },
        values: {for (final f in item.fields) _legacyKey(f.id): _value(f)},
        fieldIds: {for (final f in item.fields) _legacyKey(f.id): f.id},
        relations: _relations(layout),
      );
    }
    try {
      final definition = Map<String, Object?>.from(
        snapshot!['definition'] as Map,
      );
      final overrides = <String, Map<String, Object?>?>{
        for (final e in (snapshot['fieldOverrides'] as Map? ?? {}).entries)
          e.key as String: e.value == null
              ? null
              : Map<String, Object?>.from(e.value as Map),
      };
      final retained = [
        for (final f in snapshot['retainedFields'] as List? ?? [])
          Map<String, Object?>.from(f as Map),
      ];
      final retainedRelations = [
        for (final f in snapshot['retainedRelations'] as List? ?? [])
          Map<String, Object?>.from(f as Map),
      ];
      final base = WorkspaceDetail(
        record: summary(item, tagNames: tagNames),
        version: item.version,
        definition: definition,
        fieldOverrides: overrides,
        retainedFields: retained,
      );
      final values = <String, Object?>{}, ids = <String, String>{};
      final actual = {for (final f in item.fields) f.id: f};
      final used = <String>{};
      for (final descriptor in workspaceFields(base)) {
        final key = descriptor['key'] as String;
        if (descriptor['type'] == 'entries') {
          final entries = <Map<String, Object?>>[];
          for (final raw
              in (snapshot['entries'] as Map?)?[key] as List? ?? []) {
            final id = (raw as Map)['entryId'] as String;
            final leaves = <String, String>{}, bodies = <String, String>{};
            final definitions = <String, Object?>{};
            for (final part in WorkspaceRepeatedEntry.parts) {
              final field = actual[layout.fieldIds[_entrySlot(key, id, part)]];
              if (field == null) {
                bodies[part] = '';
                continue;
              }
              if (field.kind == core.FieldKind.file || !used.add(field.id)) {
                throw const FormatException();
              }
              leaves[part] = field.id;
              bodies[part] = field.value;
              definitions[part] = {
                'label': field.name,
                'description': field.description,
              };
            }
            if (leaves.isNotEmpty) {
              entries.add({
                'entryId': id,
                'fieldIds': leaves,
                ...bodies,
                'definitions': definitions,
              });
            }
          }
          values[key] = entries;
        } else {
          final field = actual[layout.fieldIds[_fieldSlot(key)]];
          if (field == null) {
            overrides[key] = null;
            continue;
          }
          if (!used.add(field.id)) throw const FormatException();
          ids[key] = field.id;
          values[key] = _value(field);
          // The actual field description wins over a stale frozen label after
          // a reviewed replacement/metadata change from another owner surface.
          overrides[key] = {
            ...descriptor,
            'label': field.name,
            'description': field.description,
            if (field.kind == core.FieldKind.file) 'type': 'file',
          };
        }
      }
      for (final field in item.fields.where((f) => !used.contains(f.id))) {
        var key = _legacyKey(field.id);
        while (values.containsKey(key)) {
          key = 'retained:$key';
        }
        retained.add(_descriptor(field, key));
        values[key] = _value(field);
        ids[key] = field.id;
      }
      return WorkspaceDetail(
        record: summary(item, tagNames: tagNames),
        version: item.version,
        definition: definition,
        values: values,
        relations: _relations(layout),
        fieldIds: ids,
        fieldOverrides: overrides,
        retainedFields: retained,
        retainedRelations: retainedRelations,
      );
    } on Object catch (error) {
      if (error is! FormatException && error is! TypeError) rethrow;
      throw const WorkspaceFailure('invalid_layout', '资料布局无法读取，请保留原资料并检查版本。');
    }
  }

  WorkspaceRecordSummary summary(
    core.InformationItem item, {
    Map<String, String> tagNames = const {},
  }) {
    final rawType = item.layout?.snapshot['type'];
    final type = rawType is Map ? rawType : null;
    return WorkspaceRecordSummary(
      ref: WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
      name: item.name,
      description: item.description,
      type: WorkspaceType(
        item.layout?.typeId ?? 'generic',
        type?['name'] is String ? type!['name'] as String : '通用资料',
        type?['icon'] is String ? type!['icon'] as String : 'file',
      ),
      updatedAt:
          item.modifiedAt ??
          item.createdAt ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      directoryId: item.directoryId,
      tags: [
        for (final id in item.tagIds) WorkspaceTag(id, tagNames[id] ?? id),
      ],
    );
  }

  Map<String, List<WorkspaceRecordRef>> _relations(
    core.InformationLayout? layout,
  ) => {
    for (final e
        in layout?.relations.entries ??
            <MapEntry<String, List<core.InformationRelationRef>>>[])
      e.key: [
        for (final ref in e.value)
          WorkspaceRecordRef(
            WorkspaceRecordKind.values.byName(ref.kind),
            ref.id,
          ),
      ],
  };
  Map<String, Object?> _descriptor(core.InformationField f, String key) => {
    'key': key,
    'label': f.name,
    'description': f.description,
    'type': switch (f.kind) {
      core.FieldKind.file => 'file',
      core.FieldKind.textNote => 'multiline',
      _ => 'text',
    },
  };
  Object _value(core.InformationField f) => f.kind == core.FieldKind.file
      ? WorkspaceFileRef(
          f.attachment!.attachmentId,
          f.attachment!.attachmentVersion,
        ).toJson()
      : f.value;

  core.InformationDraftInput create(
    WorkspaceCreate draft,
    Map<String, Object?> definition,
  ) {
    if (draft.fileSelections.isNotEmpty ||
        workspaceFileTypeIds.contains(draft.typeId)) {
      throw const WorkspaceFailure('unsupported', '普通附件请使用文件导入入口。');
    }
    if (definition['id'] != draft.typeId) {
      throw const WorkspaceFailure('conflict', '资料模板已变化。');
    }
    final record = WorkspaceRecordSummary(
      ref: const WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'uncommitted',
      ),
      name: draft.name,
      description: draft.description,
      type: WorkspaceType(
        draft.typeId,
        definition['name'] as String? ?? draft.typeId,
        definition['icon'] as String? ?? 'file',
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      directoryId: draft.directoryId,
      tags: [for (final id in draft.tagIds) WorkspaceTag(id, id)],
    );
    return _encode(
      WorkspaceDetail(
        record: record,
        version: 0,
        definition: definition,
        values: draft.values,
        relations: draft.relations,
      ),
      command: createCommand(draft),
    );
  }

  core.InformationDraftInput edit(
    WorkspaceEdit edit,
    core.InformationItem current,
  ) {
    if (edit.record.ref.kind != WorkspaceRecordKind.information ||
        edit.record.ref.id != current.id ||
        edit.expectedVersion != current.version) {
      throw const WorkspaceFailure('conflict', '资料已更新，请重新读取并核对修改。');
    }
    final previous = decode(current);
    if (previous.templateState != WorkspaceTemplateState.available) {
      throw const WorkspaceFailure('unsupported', '此版本的布局只能保留和查看。');
    }
    if (edit.record.type.id != previous.record.type.id) {
      throw const WorkspaceFailure('conflict', '此入口不能更换资料模板。');
    }
    final detail = WorkspaceDetail(
      record: edit.record,
      version: current.version,
      definition: previous.definition,
      fieldIds: previous.fieldIds,
      fieldOverrides: previous.fieldOverrides,
      retainedFields: previous.retainedFields,
      retainedRelations: previous.retainedRelations,
      values: {...previous.values, ...edit.values},
      relations: {...previous.relations, ...edit.relations},
    );
    return _encode(
      detail,
      current: current,
      previous: previous,
      command: editCommand(edit),
    );
  }

  core.InformationDraftInput _encode(
    WorkspaceDetail detail, {
    core.InformationItem? current,
    WorkspaceDetail? previous,
    required core.InformationRecordCommand command,
  }) {
    final errors = <String, String>{}, metadataErrors = <String, String>{};
    final record = detail.record;
    if (record.name.trim().isEmpty || record.name.length > 160) {
      metadataErrors['name'] = '请输入1–160字的名称。';
    }
    if (record.description.length > 2000) {
      metadataErrors['description'] = '说明不能超过2000字。';
    }
    final descriptors = workspaceFields(detail);
    final keys = <String>{};
    for (final f in descriptors) {
      if (f['key'] is! String ||
          (f['key'] as String).isEmpty ||
          !keys.add(f['key'] as String) ||
          f['label'] is! String) {
        throw const WorkspaceFailure('invalid_layout', '资料字段定义无效。');
      }
    }
    if (detail.values.keys.any((key) => !keys.contains(key))) {
      throw const WorkspaceFailure('validation', '表单包含未定义的字段，不能静默丢弃。');
    }
    final actual = {
      for (final f in current?.fields ?? <core.InformationField>[]) f.id: f,
    };
    final fields = <core.InformationDraftField>[], slots = <String>[];
    final entries = <String, Object?>{};
    final submittedIds = <String>{};
    void add(
      String slot,
      String name,
      String description,
      String value,
      core.InformationField? old, {
      bool multiline = false,
    }) {
      slots.add(slot);
      fields.add(
        core.InformationDraftField.text(
          old?.name ?? name,
          old?.description ?? description,
          value,
          fieldId: old?.id,
          kind:
              old?.kind ??
              (multiline ? core.FieldKind.textNote : core.FieldKind.structured),
        ),
      );
    }

    for (final descriptor in descriptors) {
      final key = descriptor['key'] as String, type = descriptor['type'];
      final value = detail.values[key];
      if (type == 'entries') {
        List<WorkspaceRepeatedEntry> desired;
        try {
          desired = WorkspaceRepeatedEntry.read(value);
        } on Object {
          errors[key] = '经历结构无法编辑，请保留原资料。';
          continue;
        }
        final active = {
          for (final e in WorkspaceRepeatedEntry.read(previous?.values[key]))
            e.id: e,
        };
        if (desired.length > 100) errors[key] = '每组最多100段经历。';
        entries[key] = [
          for (final e in desired) {'entryId': e.id},
        ];
        for (final entry in desired) {
          if (!_entryId(entry.id) || !submittedIds.add(entry.id)) {
            errors[key] = '经历身份不能重复或为空。';
          }
          final old = active[entry.id];
          final historical =
              current?.layout?.fieldIds.keys.any(
                (slot) => WorkspaceRepeatedEntry.parts.any(
                  (part) => slot == _entrySlot(key, entry.id, part),
                ),
              ) ??
              false;
          if (old == null && historical) {
            errors[key] = '不能复用已删除经历的身份，请新建经历或从回收站恢复。';
          }
          for (final part in entry.activeParts) {
            final supplied = entry.fieldIds[part]!;
            // Persisted IDs are opaque core identities (currently padded
            // base64url); only newly supplied UI IDs use the frontend grammar.
            if ((old == null && !_entryId(supplied)) ||
                !submittedIds.add(supplied)) {
              errors[key] = '经历字段身份必须有效且不能重复。';
            }
            if (old != null && old.fieldIds[part] != supplied) {
              errors[key] = '修改经历需要保留原字段身份。';
            }
            if (old == null &&
                (actual.containsKey(supplied) ||
                    (current?.layout?.fieldIds.containsValue(supplied) ??
                        false))) {
              errors[key] = '不能借用已有字段身份。';
            }
            final text = entry.toJson()[part] as String;
            final max = part == 'detail' ? 2000 : 160;
            if (text.length > max || (part == 'title' && text.trim().isEmpty)) {
              errors['$key:${entry.id}:$part'] = '请填写有效内容（最多$max字）。';
            }
            add(
              _entrySlot(key, entry.id, part),
              entry.label(part),
              '',
              text,
              old == null ? null : actual[old.fieldIds[part]],
              multiline: part == 'detail',
            );
          }
        }
      } else {
        final old = actual[previous?.fieldIds[key]];
        final slot = _fieldSlot(key);
        if (type == 'file') {
          if (old == null ||
              old.kind != core.FieldKind.file ||
              jsonEncode(value) != jsonEncode(_value(old))) {
            errors[key] = '文件原文请通过文件入口修改。';
            continue;
          }
          slots.add(slot);
          fields.add(
            core.InformationDraftField.retainedFile(
              old.name,
              old.description,
              old.attachment,
              fieldId: old.id,
            ),
          );
        } else if (!_textTypes.contains(type)) {
          if (old == null ||
              jsonEncode(value) != jsonEncode(previous?.values[key])) {
            errors[key] = '未知字段只能保留，不能转换或改写。';
            continue;
          }
          slots.add(slot);
          fields.add(
            old.kind == core.FieldKind.file
                ? core.InformationDraftField.retainedFile(
                    old.name,
                    old.description,
                    old.attachment,
                    fieldId: old.id,
                  )
                : core.InformationDraftField.text(
                    old.name,
                    old.description,
                    old.value,
                    fieldId: old.id,
                    kind: old.kind,
                  ),
          );
        } else if (value != null && value is! String) {
          errors[key] = '此字段需要文本值，不能用复合内容覆盖。';
        } else {
          final text = value as String? ?? '';
          if (text.length > 1000000 ||
              descriptor['required'] == true && text.trim().isEmpty) {
            errors[key] = '请填写有效文本。';
          }
          if (text.isNotEmpty &&
              type == 'number' &&
              (!RegExp(r'^-?(?:0|[1-9]\d*)(?:\.\d+)?$').hasMatch(text.trim()) ||
                  num.tryParse(text)?.isFinite != true)) {
            errors[key] = '请输入有限的十进制数字。';
          }
          if (text.isNotEmpty && type == 'date') {
            final date = DateTime.tryParse(text);
            if (date == null ||
                !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) ||
                date.toIso8601String().substring(0, 10) != text) {
              errors[key] = '请输入有效日期（YYYY-MM-DD）。';
            }
          }
          if (old?.kind == core.FieldKind.file) {
            errors[key] = '不能把原附件改写为文本。';
            continue;
          }
          add(
            slot,
            descriptor['label'] as String,
            descriptor['description'] as String? ?? '',
            text,
            old,
            multiline: type == 'multiline',
          );
        }
      }
    }
    for (final section in detail.definition['sections'] as List? ?? []) {
      if (section['kind'] == 'text' &&
          section['formatKey'] is String &&
          keys.contains(section['formatKey']) &&
          !workspaceDocumentFormats.containsKey(
            detail.values[section['formatKey']],
          )) {
        errors[section['formatKey'] as String] = '请选择纯文本或Markdown。';
      }
    }
    if ((current == null && fields.isEmpty) || fields.length > 200) {
      errors['fields'] = '每项资料需要1–200个独立字段。';
    }
    final rules = [
      ...detail.definition['relations'] as List? ?? [],
      ...detail.retainedRelations,
    ];
    final relationKeys = {for (final r in rules) r['key']};
    for (final e in detail.relations.entries) {
      if (!relationKeys.contains(e.key) &&
              previous?.relations.containsKey(e.key) != true ||
          e.value.length > 200 ||
          e.value.toSet().length != e.value.length) {
        errors['relation:${e.key}'] = '关联范围无效。';
      }
    }
    if (errors.isNotEmpty || metadataErrors.isNotEmpty) {
      throw WorkspaceFailure(
        'validation',
        '请检查标记的字段。',
        fieldErrors: {
          for (final e in errors.entries)
            workspaceValueErrorKey(e.key): e.value,
          ...metadataErrors,
        },
      );
    }
    final bindings = {...?current?.layout?.fieldIds};
    for (var i = 0; i < fields.length; i++) {
      final id = fields[i].fieldId;
      if (id != null) {
        bindings.removeWhere((key, value) => value == id && key != slots[i]);
      }
    }
    return core.InformationDraftInput(
      name: record.name,
      description: record.description,
      itemId: current?.id,
      baseVersion: current?.version,
      directoryId: record.directoryId,
      tagIds: record.tags.map((t) => t.id),
      fields: fields,
      command: command,
      layout: core.InformationDraftLayout(
        core.InformationLayout(
          typeId: record.type.id,
          fieldIds: bindings,
          snapshot: {
            'codec': 'workspace-information-v1',
            'type': {'name': record.type.name, 'icon': record.type.icon},
            'definition': detail.definition,
            'fieldOverrides': detail.fieldOverrides,
            'retainedFields': detail.retainedFields,
            'retainedRelations': detail.retainedRelations,
            'entries': entries,
          },
          relations: {
            for (final e in detail.relations.entries)
              e.key: [
                for (final ref in e.value)
                  core.InformationRelationRef(ref.kind.name, ref.id),
              ],
          },
        ),
        slots,
      ),
    );
  }

  bool _entryId(String value) =>
      RegExp(r'^[a-zA-Z0-9:_.-]{1,160}$').hasMatch(value);
}
