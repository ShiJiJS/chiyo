part of 'info_core.dart';

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
          'Approved candidates wait for their references; all approved members of a cycle save together. Rejected references require repair and new approval.',
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
    },
    if (hasGuidance && recordKind == 'information')
      'submissionExample': {
        'command': 'import-submit',
        if (_exampleAttachments.isNotEmpty)
          'operationId': 'replace-with-unique-intake-id',
        'items': [
          {
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
            'A declared file value is the matching attachment key, with templateField set to the declared field key. Omit templateField for an independent extra attachment.',
        'versions':
            'Group only revisions of the same material. Different purposes or directions are separate information items. Provide label and sourceNote explaining the source evidence; do not infer chronology just from submission order.',
        'currentVersion':
            'One-based index among proposed originals. Choose from source evidence, not the largest software version number. New attachments require an explicit choice.',
        'retry':
            'Use a stable operationId. If submission is uncertain query import-status by operationId before retrying; import-file-status queries a reported upload operationId. Never report pending or approved-waiting as saved.',
        'credentials':
            'Private keys and login-session files use credential templates, never ordinary attachments.',
      },
    if (hasGuidance && recordKind == 'credential') ..._credentialExamples(),
  };

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
      'operationId': 'replace-with-unique-intake-id',
      'items': [
        {
          'name': (definition['example'] as Map)['name'],
          'description': (definition['example'] as Map)['summary'] ?? '',
          'templateId': id,
          'templateVersion': version,
          'templateDigest': digest,
          'values': <String, Object?>{},
          'credential': material,
          'relations': <String, Object?>{},
        },
      ],
    };
    return {
      'submissionExample': example(materials.first),
      'submissionExamples': [for (final m in materials) example(m)],
      'credentialInput': {
        'channel':
            'dedicated credential material, never ordinary values or attachments',
        'owner':
            'An unseen account password is entered privately in the App; password-manager generated account passwords also use this path.',
        'agentString':
            'Already seen passwords or other tokens are entered by the Agent; explain that they may be exposed in the AI context. Never read a password just to select this branch.',
        'agentFile':
            'Pass the whole user-provided file path to the CLI without reading its bytes into the AI context. The CLI uploads it to the private proposal.',
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
