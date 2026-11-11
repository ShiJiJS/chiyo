part of 'info_core.dart';

Map<String, Object?> _submissionDescription(String title) => {
  'title': title,
  'agentName': 'Example Agent',
  'externalChatId': 'example-chat-id',
  'purpose': '示例用途；提交时替换为当前任务的实际说明。',
};

/// The running application's current declarative forms. The CLI never loads
/// packages, opens the database, or maintains another template registry.
class InformationTemplateCatalog {
  InformationTemplateCatalog({
    required this.version,
    required Iterable<InformationPluginDescription> plugins,
    required Iterable<InformationTemplateDescription> templates,
  }) : plugins = List.unmodifiable(plugins),
       templates = List.unmodifiable(templates) {
    if (version < 1 ||
        this.plugins.length > 100 ||
        this.templates.length > 1010 ||
        this.plugins.map((p) => p.id).toSet().length != this.plugins.length ||
        this.templates.map((t) => t.id).toSet().length !=
            this.templates.length) {
      throw const AccessFailure('invalid_template_catalog');
    }
  }
  final int version;
  final List<InformationPluginDescription> plugins;
  final List<InformationTemplateDescription> templates;
}

class InformationPluginDescription {
  const InformationPluginDescription({
    required this.id,
    required this.name,
    required this.version,
    required this.enabled,
    required this.builtin,
    required this.description,
    required this.templateIds,
  });
  final String id, name, version, description;
  final bool enabled, builtin;
  final List<String> templateIds;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'enabled': enabled,
    'builtin': builtin,
    'description': description,
    'templateIds': templateIds,
  };
}

class InformationTemplateDescription {
  InformationTemplateDescription({
    required this.id,
    required this.name,
    required this.version,
    required this.digest,
    required this.enabled,
    required Map<String, Object?> definition,
    this.packageId,
  }) : definition = _immutableTemplateValue(definition) as Map<String, Object?>;
  final String id, name, version, digest;
  final String? packageId;
  final bool enabled;
  final Map<String, Object?> definition;
  String get recordKind => definition['recordKind'] as String? ?? 'information';
  bool get hasGuidance =>
      definition['instructions'] is String &&
      (definition['instructions'] as String).trim().isNotEmpty &&
      definition['example'] is Map;
  Map<String, Object?> summary() => {
    'id': id,
    'name': name,
    'version': version,
    'digest': digest,
    'packageId': packageId,
    'enabled': enabled,
    'hasGuidance': hasGuidance,
    'recordKind': recordKind,
  };
  Map<String, Object?> toJson() => {
    ...summary(),
    'definition': definition,
    'inputLimits': {
      'itemsPerProposal': 20,
      'fieldsPerItem': 50,
      'fieldsPerProposal': 200,
      'submissionUtf8Bytes': 240000,
      'textCharacters': 64000,
      'entryFieldCount': 3,
      if (recordKind == 'information') ...{
        'ordinaryFileBytes': informationFileByteLimit,
        'attachmentsPerItem': 50,
        'proposedVersionsPerAttachment': 20,
      },
      if (recordKind == 'credential') ...{
        'credentialNameCharacters': 60,
        'credentialStringUtf8Bytes': 65536,
        'credentialFileBytes': 1048576,
        'credentialTransportUtf8Bytes': 6000000,
      },
    },
    'candidateIdentity': {
      'field': 'items[].key',
      'description':
          'Give each item a stable key unique within this proposal. The candidate property is key; a pending relation uses itemKey to reference that key. Do not put itemKey on the candidate itself.',
      'pendingReference': {'kind': 'information', 'itemKey': 'example-item'},
    },
    'classificationInput': {
      'directoryId': 'Use an existing directory id when known.',
      'suggestedDirectory':
          'A directory name or path, for example Personal/Career. Separate levels with /, at most 8 levels. Empty levels, backslashes, . and .. are invalid. Approval reuses existing parents and creates missing levels together with the records.',
      'suggestedTags': 'Tag names proposed for owner approval.',
    },
    'relationInput': {
      'shape': 'Map<declared relation key, List<target>>',
      'target': {
        'kind': 'information or credential',
        'id': 'existing catalog target id',
      },
      'pendingTarget': {
        'kind': 'information',
        'itemKey': 'stable candidate key',
        'proposalId':
            'omit for same proposal, otherwise own related proposal id',
      },
      'pendingApproval':
          'A proposal saves as one whole: every remaining item must be complete and reviewed. No subset may be admitted. References within the proposal resolve together; unresolved external references block the whole proposal. Rejected references require repair and new review.',
      'approval':
          'References are saved only after owner approval; this grants no access to their content.',
      'update':
          'Omit relations to retain existing links; pass a complete map to replace links.',
      'updatePendingTarget':
          'An update may reference a pending information candidate only with its explicit proposalId and itemKey. The old record stays unchanged until admission.',
    },
    'updateInput': {
      'command': 'update-submit',
      'identity': ['itemId', 'baseVersion'],
      'templateIdentity': ['templateId', 'templateVersion', 'templateDigest'],
      'values':
          'Provide every declared field from authorized source values; omission never means clear. Independent owner-added fields remain unchanged.',
      'revision':
          'update-revise supplies proposalId, current proposal version, and a revised update; a new owner approval is required.',
      'retainFileValue': {'retain': true},
      'fileValues':
          'For a complete template update explicitly retain every existing ordinary file with {"retain":true}. New originals use the separate attachments plan. Omission or empty text never silently deletes an existing file.',
    },
    if (hasGuidance && recordKind == 'information')
      'submissionExample': {
        'command': 'import-submit',
        ..._submissionDescription('新增示例资料'),
        'operationId': 'replace-with-unique-intake-id',
        'items': [
          {
            'key': 'example-item',
            'name': (definition['example'] as Map)['name'],
            'description': (definition['example'] as Map)['summary'] ?? '',
            'templateId': id,
            'templateVersion': version,
            'templateDigest': digest,
            'values': (definition['example'] as Map)['values'],
            if (_exampleAttachments.isNotEmpty)
              'attachments': _exampleAttachments,
            'relations': <String, Object?>{},
          },
        ],
      },
    if (recordKind == 'information')
      'fileInput': {
        'channel':
            'attachments contain CLI filePath values; paths and file bytes are never ordinary text values.',
        'binding':
            'New files must bind to a file field declared by the selected template using templateField. Extract useful facts first. When the original has independent value, create a separate file information item and relate it; do not append an unbound source copy.',
        'versions':
            'Group only revisions of the same material. Different purposes or directions are separate information items. Provide label and sourceNote explaining the source evidence; do not infer chronology just from submission order.',
        'currentVersion':
            'One-based index among proposed originals. Choose from source evidence, not the largest software version number. New attachments require an explicit choice. On an existing fieldId, null only adds historical originals and retains the existing current selection.',
        'retry':
            'Use a stable operationId. If submission is uncertain query import-status by operationId before retrying; import-file-status queries a reported upload operationId. Never report pending or approved-waiting as saved.',
        'credentials':
            'Private keys and login-session files use credential templates, never ordinary attachments.',
        'update':
            'Requires information-file-update.v1. Use update-submit with exact itemId, current baseVersion and attachments. New files require templateField naming a declared file field. Supply the exact existing file fieldId to add versions, including legacy attachments. File-only updates omit templateId/values and preserve all other contents. Never select a target only by similarity.',
      },
    if (recordKind == 'information')
      'fileUpdateExamples': _fileUpdateExamples(),
    if (hasGuidance && recordKind == 'credential') ..._credentialExamples(),
  };

  List<Map<String, Object?>> _fileUpdateExamples() => [
    for (final mode in [
      if ((definition['fields'] as List? ?? []).any(
        (f) => (f as Map)['type'] == 'file',
      ))
        'newAttachment',
      'newCurrentVersion',
      'addHistory',
    ])
      {
        'command': 'update-submit',
        ..._submissionDescription('更新示例资料文件'),
        'operationId': 'replace-with-unique-update-id',
        'update': {
          'itemId': 'exact-existing-catalog-item-id',
          'baseVersion': 1,
          'attachments': [
            {
              'key': 'original',
              'name': '材料原文',
              if (mode == 'newAttachment')
                'templateField': (definition['fields'] as List)
                    .where((f) => (f as Map)['type'] == 'file')
                    .map((f) => (f as Map)['key'])
                    .firstOrNull,
              if (mode != 'newAttachment')
                'fieldId': 'exact-existing-file-field-id',
              'currentVersion': mode == 'addHistory' ? null : 1,
              'versions': [
                {
                  'filePath': '/path/to/user-provided-original',
                  'label': '源文件标明的版本',
                  'sourceNote': '材料给出的用途或修订依据。',
                },
              ],
            },
          ],
        },
      },
  ];

  List<Map<String, Object?>> get _exampleAttachments {
    if (!hasGuidance) return const [];
    final values = (definition['example'] as Map)['values'] as Map;
    return [
      for (final raw in definition['fields'] as List? ?? [])
        if ((raw as Map)['type'] == 'file' &&
            values[raw['key']] is String &&
            (values[raw['key']] as String).isNotEmpty)
          {
            'key': values[raw['key']],
            'name': raw['label'],
            'templateField': raw['key'],
            'currentVersion': 1,
            'versions': [
              {
                'filePath': '/path/to/user-provided-original',
                'label': '源文件标明的版本',
                'sourceNote': '填写从文件或用户说明中判断材料用途和版本的依据。',
              },
            ],
          },
    ];
  }

  Map<String, Object?> _credentialExamples() {
    final config = definition['credential'] as Map;
    final materials = <Map<String, Object?>>[
      if (config['secretKind'] == 'accountPassword')
        {'source': 'owner', 'contextExposed': false},
      if (config['form'] == 'string')
        {
          'source': 'agentString',
          'contextExposed': true,
          'secret': 'FAKE-EXAMPLE-ONLY',
        },
      if (config['form'] == 'file')
        {
          'source': 'agentFile',
          'contextExposed': false,
          'filePath': '/path/to/user-provided-credential-file',
        },
    ];
    Map<String, Object?> example(Map<String, Object?> material) => {
      'command': 'import-submit',
      ..._submissionDescription('新增示例登录凭据'),
      'operationId': 'replace-with-unique-intake-id',
      'items': [
        {
          'key': 'example-item',
          'name': (definition['example'] as Map)['name'],
          'description': (definition['example'] as Map)['summary'] ?? '',
          'templateId': id,
          'templateVersion': version,
          'templateDigest': digest,
          'values': <String, Object?>{},
          'credential': {
            ...material,
            if (config['secretKind'] == 'accountPassword')
              'account': 'sample-user',
          },
          'relations': <String, Object?>{},
        },
      ],
    };
    return {
      'submissionExample': example(materials.first),
      'submissionExamples': [for (final m in materials) example(m)],
      'credentialInput': {
        'account':
            '用户名或登录邮箱填写在 credential.account，不把账号藏在用途描述里；不知道时不要猜。密码或Token不得填入这个位置。',
        'channel':
            'dedicated credential material, never ordinary values or attachments',
        'owner':
            'An unseen account password is entered privately in the App; password-manager generated account passwords also use this path.',
        'agentString':
            'Already seen passwords or other tokens are entered by the Agent; explain that they may be exposed in the AI context. Never read a password just to select this branch.',
        'agentFile':
            'Pass the whole user-provided file path to the CLI without reading its bytes into the AI context. The CLI uploads it to the private proposal.',
        'selection':
            'Choose by the authentication material needed, not the source extension. Passwords and tokens inside JSON or Markdown remain strings; use a file form when the authentication client needs the whole file. Preserving a source file alone does not finish credential organization.',
        'missingPassword':
            'For an identified account with no current password, submit the owner-input branch and explain the account and service. An old password or password hash is not a verified current login password.',
        'association':
            'Link directly to the server, service or account that uses the credential. Source documents may be linked additionally. Separate website passwords, API tokens and SSH identities by their actual use.',
        'approval':
            'Material must be complete and approved before admission. Status responses never return material; admission grants no use permission.',
      },
    };
  }
}

Object? _immutableTemplateValue(Object? value) => switch (value) {
  Map map => Map<String, Object?>.unmodifiable({
    for (final e in map.entries)
      e.key as String: _immutableTemplateValue(e.value),
  }),
  List list => List<Object?>.unmodifiable(list.map(_immutableTemplateValue)),
  _ => value,
};

extension OwnerInformationTemplateCatalog on OwnerAccess {
  /// Trusted composition only. It is not an Agent operation and cannot be set
  /// through the transport. Resolve from this library on every call.
  void configureInformationTemplates(
    InformationTemplateCatalog Function() read,
  ) {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    final scope = captureLibraryScope();
    _service._informationTemplates = () {
      if (!scope.isCurrent || !serviceAvailable) {
        throw const AccessFailure('service_unavailable');
      }
      return read();
    };
  }
}

extension AgentInformationTemplateCatalog on AgentAccess {
  bool get credentialImportAvailable =>
      informationTemplatesAvailable &&
      _service._repository is CredentialRepository;
  bool get informationTemplatesAvailable =>
      !_service._closed && _service._informationTemplates != null;

  InformationTemplateCatalog _currentInformationTemplates() {
    if (_service._closed || _service._backupBusy) {
      throw const AccessFailure('service_unavailable');
    }
    final reader = _service._informationTemplates;
    if (reader == null) throw const AccessFailure('unsupported_capability');
    return reader();
  }

  Map<String, Object?> pluginCatalog() {
    final current = _currentInformationTemplates();
    return {
      'status': 'ok',
      'catalogVersion': current.version,
      'plugins': [for (final p in current.plugins) p.toJson()],
    };
  }

  Map<String, Object?> informationTemplateCatalog({
    String? packageId,
    int offset = 0,
    int limit = 50,
  }) {
    if (offset < 0 ||
        limit < 1 ||
        limit > 100 ||
        packageId != null && (packageId.isEmpty || packageId.length > 128)) {
      throw const AccessFailure('invalid_request');
    }
    final current = _currentInformationTemplates();
    final matches =
        current.templates
            .where((t) => packageId == null || t.packageId == packageId)
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final end = min(offset + limit, matches.length);
    return {
      'status': 'ok',
      'catalogVersion': current.version,
      'templates': [
        for (final t in matches.skip(offset).take(limit)) t.summary(),
      ],
      'total': matches.length,
      'offset': offset,
      'nextOffset': end < matches.length ? end : null,
    };
  }

  Map<String, Object?> readInformationTemplate(String id) {
    if (id.isEmpty || id.length > 512) {
      throw const AccessFailure('invalid_request');
    }
    final current = _currentInformationTemplates();
    final template = current.templates.where((t) => t.id == id).firstOrNull;
    if (template == null) throw const AccessFailure('template_missing');
    if (!template.enabled) throw const AccessFailure('template_unavailable');
    return {
      'status': 'ok',
      'catalogVersion': current.version,
      'template': template.toJson(),
    };
  }
}
