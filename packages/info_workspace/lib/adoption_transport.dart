import 'workspace_source.dart';
import 'workspace_transport.dart';
import 'history_transport.dart' show historyEnvelope, historyText, historyInt;

Map<String, Object?> adoptionDraftToJson(WorkspaceAdoptionDraft d) => {
  'wireVersion': 1,
  'record': recordRefToJson(d.ref),
  'typeId': d.typeId,
  'fields': {
    for (final e in d.fields.entries)
      e.key: {
        'sourceKey': e.value.sourceKey,
        'sameMeaning': e.value.sameMeaning,
        'value': e.value.value,
      },
  },
};

WorkspaceAdoptionDraft adoptionDraftFromJson(Object? raw) {
  final b = historyEnvelope(raw, ['record', 'typeId', 'fields']);
  final fields = _object(b['fields']);
  if (fields.length > 200) throw const FormatException('Invalid mappings');
  return WorkspaceAdoptionDraft(
    ref: recordRefFromJson(b['record']),
    typeId: historyText(b['typeId'], max: 512),
    fields: {
      for (final e in fields.entries)
        historyText(e.key): (() {
          final mapping = _object(e.value, [
            'sourceKey',
            'sameMeaning',
            'value',
          ]);
          if (mapping['sameMeaning'] is! bool) {
            throw const FormatException('Invalid mapping');
          }
          return WorkspaceFieldMapping(
            sourceKey: mapping['sourceKey'] == null
                ? null
                : historyText(mapping['sourceKey']),
            sameMeaning: mapping['sameMeaning'] as bool,
            value: historyText(
              mapping['value'],
              max: workspaceDocumentMaxLength,
              empty: true,
            ),
          );
        })(),
    },
  );
}

Map<String, Object?> adoptionPreviewToJson(WorkspaceAdoptionPreview p) => {
  'wireVersion': 1,
  'planId': p.planId,
  'current': workspaceDetailToJson(p.current),
  'target': {
    'id': p.target.id,
    'type': {
      'id': p.target.type.id,
      'name': p.target.type.name,
      'icon': p.target.type.icon,
    },
    'definition': p.target.definition,
  },
  'pluginVersion': p.pluginVersion,
  'result': workspaceDetailToJson(p.result),
  'rows': [
    for (final r in p.rows)
      {
        'key': r.key,
        'label': r.label,
        'sourceKey': r.sourceKey,
        'sourceLabel': r.sourceLabel,
        'result': r.result,
        'problem': r.problem,
      },
  ],
  'retained': p.retained,
  'errors': p.errors,
};

WorkspaceAdoptionPreview adoptionPreviewFromJson(Object? raw) {
  final b = historyEnvelope(raw, [
    'planId',
    'current',
    'target',
    'pluginVersion',
    'result',
    'rows',
    'retained',
    'errors',
  ]);
  final target = _object(b['target'], ['id', 'type', 'definition']);
  final type = _object(target['type'], ['id', 'name', 'icon']);
  final current = workspaceDetailFromJson(b['current']);
  final result = workspaceDetailFromJson(b['result']);
  final rows = b['rows'];
  final retained = b['retained'];
  if (rows is! List ||
      rows.length > 200 ||
      retained is! List ||
      retained.length > 200 ||
      current.record.ref != result.record.ref ||
      result.version != current.version + 1 ||
      result.record.type.id != type['id']) {
    throw const FormatException('Invalid adoption preview');
  }
  String? optional(Object? v) =>
      v == null ? null : historyText(v, max: 2000, empty: true);
  return WorkspaceAdoptionPreview(
    planId: historyText(b['planId']),
    current: current,
    result: result,
    target: WorkspacePluginTemplate(
      id: historyText(target['id'], max: 512),
      type: WorkspaceType(
        historyText(type['id'], max: 512),
        historyText(type['name']),
        historyText(type['icon']),
      ),
      definition: _object(target['definition']).cast<String, Object?>(),
    ),
    pluginVersion: historyInt(b['pluginVersion'], min: 1),
    rows: [
      for (final raw in rows)
        (() {
          final r = _object(raw, [
            'key',
            'label',
            'sourceKey',
            'sourceLabel',
            'result',
            'problem',
          ]);
          return WorkspaceAdoptionRow(
            key: historyText(r['key']),
            label: historyText(r['label']),
            sourceKey: optional(r['sourceKey']),
            sourceLabel: optional(r['sourceLabel']),
            result: historyText(r['result']),
            problem: optional(r['problem']),
          );
        })(),
    ],
    retained: retained.map((r) => historyText(r)),
    errors: _object(
      b['errors'],
    ).map((k, v) => MapEntry(historyText(k), historyText(v, max: 2000))),
  );
}

Map<String, dynamic> _object(Object? raw, [List<String>? keys]) {
  if (raw is! Map ||
      raw.keys.any((k) => k is! String) ||
      keys != null &&
          (raw.length != keys.length || keys.any((k) => !raw.containsKey(k)))) {
    throw const FormatException('Invalid adoption fields');
  }
  return Map<String, dynamic>.from(raw);
}

Map<String, Object?> adoptionReceiptToJson(WorkspaceRecordReceipt r) => {
  'wireVersion': 1,
  'record': recordRefToJson(r.ref),
  'version': r.version,
};
WorkspaceRecordReceipt adoptionReceiptFromJson(Object? raw) {
  final b = historyEnvelope(raw, ['record', 'version']);
  return WorkspaceRecordReceipt(
    ref: recordRefFromJson(b['record']),
    version: historyInt(b['version'], min: 1),
  );
}
