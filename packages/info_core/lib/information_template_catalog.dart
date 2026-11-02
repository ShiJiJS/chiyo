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
    },
    'relationInput': {
      'shape': 'Map<declared relation key, List<target>>',
      'target': {
        'kind': 'information or credential',
        'id': 'existing catalog target id',
      },
      'approval':
          'References are saved only after owner approval; this grants no access to their content.',
      'update':
          'Omit relations to retain existing links; pass a complete map to replace links.',
    },
    if (hasGuidance)
      'submissionExample': {
        'command': 'import-submit',
        'items': [
          {
            'name': (definition['example'] as Map)['name'],
            'description': (definition['example'] as Map)['summary'] ?? '',
            'templateId': id,
            'templateVersion': version,
            'templateDigest': digest,
            'values': (definition['example'] as Map)['values'],
            'relations': <String, Object?>{},
          },
        ],
      },
  };
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
