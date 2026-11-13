part of 'info_core.dart';

/// Dry-run input uses file metadata, never an uploaded original or a private
/// compiled layout. Virtual uploads exist only in this call and cannot be
/// submitted, consumed or recovered as a stored file.
List<ImportAttachmentInput> _precheckFiles(Object? raw, String binding) {
  if (raw == null) return const [];
  if (raw is! List || raw.length > 50) {
    throw const AccessFailure('invalid_proposal');
  }
  var count = 0;
  return [
    for (final attachment in raw)
      (() {
        final json = Map<String, dynamic>.from(attachment as Map);
        final versions = json['versions'];
        if (versions is! List || versions.length > 20) {
          throw const AccessFailure('invalid_proposal');
        }
        final uploads = <String, InformationImportUpload>{};
        json['versions'] = [
          for (final version in versions)
            (() {
              if (++count > 200 || version is! Map) {
                throw const AccessFailure('invalid_proposal');
              }
              final v = Map<String, dynamic>.from(version);
              if (v.keys.any(
                (k) => !{
                  'originalName',
                  'mediaType',
                  'byteLength',
                  'sha256',
                  'label',
                  'sourceNote',
                }.contains(k),
              )) {
                throw const AccessFailure('invalid_proposal');
              }
              final id = 'precheck-file-$count';
              uploads[id] = InformationImportUpload(
                id: id,
                sessionBinding: binding,
                operationId: id,
                originalName: v['originalName'] as String,
                mediaType: v['mediaType'] as String,
                byteLength: v['byteLength'] as int,
                sha256: v['sha256'] as String,
                createdAt: DateTime.utc(2026),
              );
              return {
                'uploadId': id,
                'label': v['label'] ?? '',
                'sourceNote': v['sourceNote'] ?? '',
              };
            })(),
        ];
        final parsed = ImportAttachmentInput.fromJson(json);
        return parsed.resolved([
          for (final v in parsed.versions) v.resolved(uploads[v.uploadId]!),
        ]);
      })(),
  ];
}

extension AgentProposalPrecheck on AgentAccess {
  /// Reuses admission's template compiler and proposal validators without
  /// saving proposals, uploading files or reading existing private values into
  /// the response. Approval still revalidates live targets and dependencies.
  Map<String, Object?> checkProposal(
    String session,
    String kind,
    Map<String, dynamic> input,
  ) {
    _service._requireSession(session);
    final binding = _service._sessionBindings[session]!;
    final bodyKeys = {
      'title',
      'agentName',
      'purpose',
      'externalChatId',
      if (kind == 'import') 'items',
      if (kind == 'update') 'update',
      if (kind == 'delete') ...['itemId', 'baseVersion', 'fieldId'],
    };
    if (!{'import', 'update', 'delete'}.contains(kind) ||
        input.keys.any((k) => !bodyKeys.contains(k))) {
      throw const AccessFailure('invalid_proposal');
    }
    if (['title', 'agentName', 'purpose', 'externalChatId'].any(
          (k) => input[k] is! String || (input[k] as String).trim().isEmpty,
        ) ||
        !validSubmissionMetadata(
          title: input['title'] as String,
          agentName: input['agentName'] as String,
          purpose: input['purpose'] as String,
          externalChatId: input['externalChatId'] as String,
        )) {
      throw const AccessFailure('invalid_submission_metadata');
    }
    final owner = _service.owner;
    switch (kind) {
      case 'import':
        final raw = input['items'];
        if (raw is! List || raw.isEmpty || raw.length > 20) {
          throw const AccessFailure('invalid_proposal');
        }
        final items = <ImportItemInput>[];
        for (final row in raw) {
          final json = Map<String, dynamic>.from(row as Map);
          final files = _precheckFiles(json['attachments'], binding);
          if (json['templateId'] is! String) {
            throw const AccessFailure('template_required');
          }
          final parsed = ImportItemInput.fromJson({
            ...json,
            if (json.containsKey('attachments'))
              'attachments': [for (final f in files) f.submissionJson],
          });
          items.add(
            ImportItemInput.fromPrivateJson({
              ...parsed.toJson(),
              if (files.isNotEmpty)
                'attachments': [for (final f in files) f.toPrivateJson()],
            }),
          );
        }
        _validateImport(items);
        final compiled = owner._compileTemplateImports(items);
        _validateImport(compiled);
        if (compiled.any((i) => i.key.isEmpty) ||
            compiled.map((i) => i.key).toSet().length != compiled.length) {
          throw const AccessFailure('invalid_proposal');
        }
        owner._validatePendingImportTargets(
          ImportProposal(
            id: 'proposal-precheck',
            sessionBinding: binding,
            chatLabel: _service._sessions[session]!,
            createdAt: _service._clock(),
            items: compiled,
          ),
          compiled,
        );
        return {
          'status': 'ok',
          'checked': true,
          'kind': kind,
          'items': [
            for (final item in compiled)
              {
                'key': item.key,
                'templateId': item.templateId,
                'fieldCount': item.fields.length,
                'fileCount': item.attachments.fold<int>(
                  0,
                  (n, a) => n + a.versions.length,
                ),
                'requiresUserPassword': item.credential?.source == 'owner',
              },
          ],
        };
      case 'update':
        final json = Map<String, dynamic>.from(input['update'] as Map);
        final files = _precheckFiles(json['attachments'], binding);
        final parsed = UpdateInput.fromJson({
          ...json,
          if (json.containsKey('attachments'))
            'attachments': [for (final f in files) f.submissionJson],
        });
        final withFiles = UpdateInput.fromPrivateJson({
          ...parsed.toJson(),
          if (files.isNotEmpty)
            'attachments': [for (final f in files) f.toPrivateJson()],
        });
        _validateUpdate(withFiles);
        final compiled = owner._compileTemplateUpdate(withFiles);
        owner._validatePendingUpdateTargets(
          UpdateProposal(
            id: 'proposal-precheck',
            sessionBinding: binding,
            chatLabel: _service._sessions[session]!,
            createdAt: _service._clock(),
            input: compiled,
          ),
        );
        return {'status': 'ok', 'checked': true, 'kind': kind};
      default:
        final id = input['itemId'],
            version = input['baseVersion'],
            field = input['fieldId'];
        if (id is! String ||
            id.isEmpty ||
            id.length > 200 ||
            version is! int ||
            version < 1 ||
            field != null &&
                (field is! String || field.isEmpty || field.length > 200)) {
          throw const AccessFailure('invalid_proposal');
        }
        // Match submitDelete: existence, current version and field membership
        // remain owner-side checks, rather than an unauthorised content oracle.
        return {'status': 'ok', 'checked': true, 'kind': kind};
    }
  }
}
