part of 'info_core.dart';

class InformationTemplateInputFailure extends AccessFailure {
  InformationTemplateInputFailure(Map<String, String> errors)
    : fieldErrors = Map.unmodifiable(errors),
      super('validation_failed');
  final Map<String, String> fieldErrors;
}

extension OwnerTemplateImports on OwnerAccess {
  UpdateInput _compileTemplateUpdate(UpdateInput input) {
    if (input.templateId == null) return input;
    final previous = information.where((i) => i.id == input.itemId).firstOrNull;
    final retainedFiles = <String>{};
    for (final raw
        in (previous?.layout?.snapshot['definition'] as Map?)?['fields']
                as List? ??
            []) {
      final key = (raw as Map)['key'] as String;
      if (raw['type'] == 'file' &&
          previous!.fields.any(
            (f) =>
                f.id == previous.layout!.fieldIds[jsonEncode(['field', key])] &&
                f.kind == FieldKind.file,
          )) {
        retainedFiles.add(key);
      }
    }
    final compiled = _compileTemplateImport(
      ImportItemInput(
        input.name ?? '模板修改',
        input.description ?? '',
        const [],
        templateId: input.templateId,
        templateVersion: input.templateVersion,
        templateDigest: input.templateDigest,
        values: input.values,
        relations: input.relations ?? const {},
        pendingRelations: input.pendingRelations,
        layout: input.compiledTemplate?.layout,
        attachments: [
          for (final a in input.attachments.where(
            (a) => a.templateField != null,
          ))
            ImportAttachmentInput(
              key: a.key,
              name: a.name,
              description: a.description,
              templateField: a.templateField,
              currentVersion: a.currentVersion ?? 1,
              versions: a.versions,
            ),
        ],
      ),
      _service.agent._currentInformationTemplates(),
      retainedFileKeys: retainedFiles,
    );
    final missing = <String, String>{
      for (final field
          in (compiled.layout!.snapshot['definition'] as Map)['fields'] as List)
        if (!input.values.containsKey((field as Map)['key']))
          field['key'] as String: '按模板修改需提供完整字段；不要用省略字段来清空原内容。',
    };
    if (missing.isNotEmpty) throw InformationTemplateInputFailure(missing);
    _validateImport([compiled]);
    return UpdateInput(
      input.itemId,
      input.baseVersion,
      const [],
      name: input.name,
      description: input.description,
      templateId: input.templateId,
      templateVersion: input.templateVersion,
      templateDigest: input.templateDigest,
      values: input.values,
      relations: input.relations,
      pendingRelations: input.pendingRelations,
      compiledTemplate: compiled,
      attachments: input.attachments,
      filePlan: input.filePlan,
    );
  }

  InformationItem _applyTemplateUpdate(
    InformationItem previous,
    UpdateInput raw,
  ) {
    // Preview the retained reviewed snapshot even when a plugin changes. The
    // final decision revalidates availability and values before committing.
    final input = raw.compiledTemplate == null
        ? _compileTemplateUpdate(raw)
        : raw;
    if (previous.layout?.typeId != input.templateId) {
      throw const AccessFailure('proposal_conflict');
    }
    final compiled = input.compiledTemplate!;
    final templateKeys = {
      for (final field
          in (compiled.layout!.snapshot['definition'] as Map)['fields'] as List)
        (field as Map)['key'] as String,
    };
    final managed = <String>{};
    for (final e in previous.layout!.fieldIds.entries) {
      try {
        final slot = jsonDecode(e.key);
        if (slot is List &&
            slot.length >= 2 &&
            templateKeys.contains(slot[1])) {
          managed.add(e.value);
        }
      } on FormatException {
        /* Unrecognized bindings remain independently retained fields. */
      }
    }
    final fields = <InformationField>[];
    for (final (n, value) in compiled.fields.indexed) {
      final oldId = previous.layout!.fieldIds[compiled.fieldKeys[n]];
      final old = previous.fields.where((f) => f.id == oldId).firstOrNull;
      fields.add(
        old == null
            ? InformationField(
                _service._secret(),
                value.name,
                value.description,
                value.value,
                1,
                kind: value.kind,
              )
            : old.value == value.value
            ? old
            : old.correctValue(value.value),
      );
    }
    final bound = compiled.bindLayout(fields)!;
    final fileKeys = {
      for (final f
          in (compiled.layout!.snapshot['definition'] as Map)['fields'] as List)
        if ((f as Map)['type'] == 'file') f['key'] as String,
    };
    for (final key in fileKeys) {
      final file = previous.fields
          .where(
            (f) =>
                f.id == previous.layout!.fieldIds[jsonEncode(['field', key])] &&
                f.kind == FieldKind.file,
          )
          .firstOrNull;
      if (file != null) fields.add(file);
    }
    fields.addAll(previous.fields.where((f) => !managed.contains(f.id)));
    if (fields.length > 200) throw const AccessFailure('invalid_proposal');
    final relationKeys = {
      for (final rule
          in (compiled.layout!.snapshot['definition'] as Map)['relations']
                  as List? ??
              [])
        (rule as Map)['key'] as String,
    };
    return InformationItem(
      previous.id,
      input.name?.trim() ?? previous.name,
      input.description ?? previous.description,
      previous.version + 1,
      fields,
      directoryId: previous.directoryId,
      tagIds: previous.tagIds,
      layout: InformationLayout(
        typeId: compiled.layout!.typeId,
        snapshot: {
          ...compiled.layout!.snapshot,
          'retainedFields':
              previous.layout!.snapshot['retainedFields'] ?? <Object?>[],
          'retainedRelations':
              previous.layout!.snapshot['retainedRelations'] ?? <Object?>[],
        },
        fieldIds: {...previous.layout!.fieldIds, ...bound.fieldIds},
        relations: input.relations == null
            ? previous.layout!.relations
            : {
                for (final e in previous.layout!.relations.entries)
                  if (!relationKeys.contains(e.key)) e.key: e.value,
                ...compiled.relations,
              },
      ),
      createdAt: previous.createdAt,
      modifiedAt: _service._clock(),
    );
  }

  List<ImportItemInput> _compileTemplateImports(List<ImportItemInput> inputs) {
    if (!inputs.any((i) => i.templateId != null)) return inputs;
    final catalog = _service.agent._currentInformationTemplates();
    return [for (final input in inputs) _compileTemplateImport(input, catalog)];
  }

  ImportItemInput _compileTemplateImport(
    ImportItemInput input,
    InformationTemplateCatalog catalog, {
    Set<String> retainedFileKeys = const {},
  }) {
    if (input.templateId == null) return input;
    final template = catalog.templates
        .where((t) => t.id == input.templateId)
        .firstOrNull;
    if (template == null) throw const AccessFailure('template_missing');
    if (!template.enabled) throw const AccessFailure('template_unavailable');
    if (template.version != input.templateVersion ||
        template.digest != input.templateDigest) {
      throw const AccessFailure('template_changed');
    }
    if (!template.hasGuidance) {
      throw const AccessFailure('template_guidance_missing');
    }
    final definition = template.definition;
    if (template.recordKind == 'credential') {
      return _compileCredentialImport(input, template);
    }
    if (input.credential != null) {
      throw const AccessFailure('invalid_credential_template');
    }
    final descriptors = (definition['fields'] as List).cast<Map>();
    final keys = {for (final f in descriptors) f['key'] as String};
    final errors = <String, String>{};
    final relationKeys = {
      for (final r in definition['relations'] as List? ?? [])
        (r as Map)['key'] as String,
    };
    if ({
      ...input.relations.keys,
      ...input.pendingRelations.keys,
    }.any((key) => !relationKeys.contains(key))) {
      errors['_relations'] = '包含模板未定义的关联。';
    }
    for (final key in input.values.keys) {
      if (!keys.contains(key)) errors['_form'] = '包含模板未定义的字段。';
    }
    final fields = <FieldInput>[], slots = <String>[];
    final entries = <String, Object?>{};
    void add(
      String slot,
      String name,
      String description,
      String text, {
      bool multiline = false,
    }) {
      fields.add(
        FieldInput(
          name,
          description,
          text,
          kind: multiline ? FieldKind.textNote : FieldKind.structured,
        ),
      );
      slots.add(slot);
    }

    for (final field in descriptors) {
      final key = field['key'] as String,
          label = field['label'] as String,
          kind = field['type'] as String;
      final value = input.values[key];
      if (kind == 'file') {
        if (value is Map &&
            value.length == 1 &&
            value['retain'] == true &&
            retainedFileKeys.contains(key)) {
          continue;
        }
        final files = input.attachments
            .where((a) => a.templateField == key)
            .toList();
        if (files.length > 1 ||
            files.isEmpty && retainedFileKeys.contains(key) ||
            files.isEmpty && field['required'] == true ||
            files.isNotEmpty && value != files.single.key ||
            files.isEmpty && value != null && value != '') {
          errors[key] = '请提供这份文件的attachments条目，并在模板值中填写它的key。';
        }
        continue;
      }
      if (kind == 'entries') {
        if (value != null && value is! List ||
            value is List && value.length > 100 ||
            field['required'] == true &&
                (value == null || (value as List).isEmpty)) {
          errors[key] = '请提供有效的经历列表，每组最多100项。';
          continue;
        }
        final rows = <Map<String, Object?>>[];
        for (final (n, row) in (value as List? ?? []).indexed) {
          if (row is! Map ||
              row.keys.any((k) => !{'title', 'period', 'detail'}.contains(k))) {
            errors['$key:$n'] = '经历仅包含title、period、detail文本。';
            continue;
          }
          final previousRows =
              (input.layout?.snapshot['entries'] as Map?)?[key] as List?;
          final previousId = previousRows != null && n < previousRows.length
              ? (previousRows[n] as Map)['entryId'] as String?
              : null;
          final entryId =
              previousId ?? 'entry-${_service._secret().replaceAll('=', '')}';
          rows.add({'entryId': entryId});
          for (final part in ['title', 'period', 'detail']) {
            final text = row[part] ?? '';
            final max = part == 'detail' ? 2000 : 160;
            if (text is! String ||
                text.length > max ||
                part == 'title' && text.trim().isEmpty) {
              errors['$key:$n:$part'] = '请填写有效的经历文本。';
              continue;
            }
            add(
              jsonEncode(['entry', key, entryId, part]),
              switch (part) {
                'title' => '经历名称',
                'period' => '经历时间',
                _ => '经历说明',
              },
              '',
              text,
              multiline: part == 'detail',
            );
          }
        }
        entries[key] = rows;
        continue;
      }
      if (!{'text', 'url', 'number', 'date', 'multiline'}.contains(kind)) {
        errors[key] = '当前宿主不支持此字段格式。';
        continue;
      }
      if (value != null && value is! String) {
        errors[key] = '此字段需要文本值。';
        continue;
      }
      final text = value as String? ?? '';
      if (text.length > 64000 ||
          field['required'] == true && text.trim().isEmpty) {
        errors[key] = '请填写有效文本，不能超过64000字符。';
      }
      if (text.isNotEmpty &&
          kind == 'number' &&
          (!RegExp(r'^-?(?:0|[1-9]\d*)(?:\.\d+)?$').hasMatch(text.trim()) ||
              num.tryParse(text)?.isFinite != true)) {
        errors[key] = '请输入有限的十进制数字。';
      }
      if (text.isNotEmpty && kind == 'date') {
        final date = DateTime.tryParse(text);
        if (date == null ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) ||
            date.toIso8601String().substring(0, 10) != text) {
          errors[key] = '请输入有效日期（YYYY-MM-DD）。';
        }
      }
      add(
        jsonEncode(['field', key]),
        label,
        field['description'] as String? ?? '',
        text,
        multiline: kind == 'multiline',
      );
    }
    for (final section in definition['sections'] as List? ?? []) {
      final format = (section as Map)['formatKey'];
      if (format is String &&
          !{'plain', 'markdown'}.contains(input.values[format])) {
        errors[format] = '请选择plain或markdown正文格式。';
      }
    }
    final declaredFiles = {
      for (final f in descriptors.where((f) => f['type'] == 'file')) f['key'],
    };
    if (input.attachments.any(
      (a) =>
          a.templateField != null && !declaredFiles.contains(a.templateField),
    )) {
      errors['_files'] = '文件绑定必须指向模板声明的文件字段；独立补充附件省略templateField。';
    }
    if (input.attachments.any(
      (a) => a.versions.any((v) => v.upload == null || v.upload!.consumed),
    )) {
      errors['_files'] = '原文件尚未接收，请通过CLI提交后重新审批。';
    }
    if (fields.isEmpty &&
        input.attachments.isEmpty &&
        retainedFileKeys.isEmpty &&
        errors.isEmpty) {
      errors['_form'] = '模板至少需要一个可保存的字段。';
    }
    if (errors.isNotEmpty) throw InformationTemplateInputFailure(errors);
    final layout = InformationLayout(
      typeId: template.id,
      snapshot: {
        'codec': 'workspace-information-v1',
        'type': {'name': template.name, 'icon': definition['icon'] ?? 'file'},
        'definition': definition,
        'fieldOverrides': <String, Object?>{},
        'retainedFields': <Object?>[],
        'retainedRelations': <Object?>[],
        'entries': entries,
      },
      fieldIds: const {},
      relations: input.relations,
    );
    return ImportItemInput(
      input.name,
      input.description,
      fields,
      key: input.key,
      directoryId: input.directoryId,
      tagIds: input.tagIds,
      suggestedDirectory: input.suggestedDirectory,
      suggestedTags: input.suggestedTags,
      suggestedTemplate: input.suggestedTemplate,
      templateId: template.id,
      templateVersion: template.version,
      templateDigest: template.digest,
      values: input.values,
      relations: input.relations,
      pendingRelations: input.pendingRelations,
      layout: layout,
      fieldKeys: slots,
      attachments: input.attachments,
    );
  }

  void _validateImportedRelations(ImportItemInput input) {
    if (input.relations.isEmpty) return;
    final definition = input.layout!.snapshot['definition'] as Map;
    for (final e in input.relations.entries) {
      final descriptor = (definition['relations'] as List)
          .cast<Map>()
          .singleWhere((r) => r['key'] == e.key);
      final allowed = (descriptor['targetTemplates'] as List? ?? [])
          .cast<String>();
      for (final ref in e.value) {
        final targetType = ref.kind == 'credential'
            ? credentials
                      .where((c) => c.id == ref.id)
                      .firstOrNull
                      ?.template
                      ?.typeId ??
                  (credentials.any((c) => c.id == ref.id) ? 'credential' : null)
            : information
                  .where((i) => i.id == ref.id)
                  .firstOrNull
                  ?.layout
                  ?.typeId;
        final exists = ref.kind == 'credential'
            ? targetType != null
            : information.any((i) => i.id == ref.id);
        if (!exists ||
            allowed.isNotEmpty &&
                !allowed.contains(targetType ?? 'generic') &&
                !(ref.kind == 'credential' && allowed.contains('credential'))) {
          throw const AccessFailure('proposal_reference_unavailable');
        }
      }
    }
  }

  ImportItemInput _compileCredentialImport(
    ImportItemInput input,
    InformationTemplateDescription template,
  ) {
    if (_service._repository is! CredentialRepository) {
      throw const AccessFailure('unsupported_capability');
    }
    final material = input.credential;
    final config = template.definition['credential'] as Map?;
    if (material == null ||
        input.attachments.isNotEmpty ||
        config == null ||
        input.values.isNotEmpty ||
        input.fields.isNotEmpty ||
        material.isFile != (config['form'] == 'file') ||
        config['secretKind'] == 'token' && material.source != 'agentString') {
      throw const AccessFailure('invalid_credential_template');
    }
    _validateCredentialMetadata(
      input.name,
      input.description,
      '',
      config['suggestedBinding'] as String,
    );
    final keys = {
      for (final rule in template.definition['relations'] as List? ?? [])
        (rule as Map)['key'],
    };
    if ({
      ...input.relations.keys,
      ...input.pendingRelations.keys,
    }.any((k) => !keys.contains(k))) {
      throw const AccessFailure('invalid_reference');
    }
    return ImportItemInput(
      input.name,
      input.description,
      const [],
      key: input.key,
      directoryId: input.directoryId,
      tagIds: input.tagIds,
      suggestedDirectory: input.suggestedDirectory,
      suggestedTags: input.suggestedTags,
      templateId: template.id,
      templateVersion: template.version,
      templateDigest: template.digest,
      credential: material,
      relations: input.relations,
      pendingRelations: input.pendingRelations,
      layout: InformationLayout(
        typeId: template.id,
        snapshot: {
          'type': {'id': template.id, 'name': template.name, 'icon': 'key'},
          'definition': template.definition,
          'templateVersion': template.version,
          'templateDigest': template.digest,
        },
        fieldIds: const {},
        relations: input.relations,
      ),
    );
  }
}
