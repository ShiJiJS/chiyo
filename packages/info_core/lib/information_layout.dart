import 'dart:convert';

/// Owner presentation, never an authorization scope or an agent response.
/// Field bodies remain in InformationField. Snapshot data describes the frozen
/// template, overlays and entry order; bindings reference independent fields.
final class InformationLayout {
  InformationLayout({
    required this.typeId,
    required Map<String, Object?> snapshot,
    required Map<String, String> fieldIds,
    Map<String, List<InformationRelationRef>> relations = const {},
  }) : snapshot = _freeze(snapshot, 0) as Map<String, Object?>,
       fieldIds = Map.unmodifiable(fieldIds),
       relations = Map.unmodifiable({
         for (final e in relations.entries)
           e.key: List<InformationRelationRef>.unmodifiable(e.value),
       }) {
    if (!_key(typeId) ||
        fieldIds.length > 2000 ||
        fieldIds.keys.any((key) => !_key(key)) ||
        fieldIds.values.any((id) => !_identity(id)) ||
        fieldIds.values.toSet().length != fieldIds.length ||
        relations.length > 200 ||
        relations.entries.any((e) => !_key(e.key) || e.value.length > 200) ||
        relations.values.any((refs) => refs.toSet().length != refs.length) ||
        utf8.encode(jsonEncode(toJson())).length > maxBytes) {
      throw const FormatException('Invalid information layout');
    }
  }

  static const maxBytes = 512 * 1024;
  final String typeId;
  final Map<String, Object?> snapshot;
  // Deleted slots may retain identities as historical layout references. Only
  // fields actually present in the item are readable or eligible for grants.
  final Map<String, String> fieldIds;
  final Map<String, List<InformationRelationRef>> relations;

  InformationLayout withFieldIds(Map<String, String> bindings) =>
      InformationLayout(
        typeId: typeId,
        snapshot: snapshot,
        fieldIds: bindings,
        relations: relations,
      );

  InformationLayout remapFields(Map<String, String> replacements) =>
      withFieldIds({
        for (final e in fieldIds.entries)
          e.key: replacements[e.value] ?? e.value,
      });

  /// Recovered leaves get fresh identities. Keep current slot choices when a
  /// slot has since been repurposed; unmatched leaves remain ordinary fields.
  InformationLayout restoreBindings(
    InformationLayout? archived,
    Map<String, String> replacements,
  ) {
    final bindings = {
      for (final e in fieldIds.entries) e.key: replacements[e.value] ?? e.value,
    };
    if (archived != null && archived.typeId == typeId) {
      for (final e in archived.fieldIds.entries) {
        final replacement = replacements[e.value];
        if (replacement != null &&
            !bindings.containsKey(e.key) &&
            !bindings.containsValue(replacement)) {
          bindings[e.key] = replacement;
        }
      }
    }
    return withFieldIds(bindings);
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'typeId': typeId,
    'snapshot': snapshot,
    'fieldIds': fieldIds,
    'relations': {
      for (final e in relations.entries)
        e.key: [for (final ref in e.value) ref.toJson()],
    },
  };

  factory InformationLayout.fromJson(Map<String, dynamic> json) {
    if (json.length != 5 ||
        json['version'] is! int ||
        json['version'] != 1 ||
        json['typeId'] is! String ||
        json['snapshot'] is! Map<String, dynamic> ||
        json['fieldIds'] is! Map<String, dynamic> ||
        json['relations'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid information layout');
    }
    try {
      return InformationLayout(
        typeId: json['typeId'] as String,
        snapshot: json['snapshot'] as Map<String, dynamic>,
        fieldIds: Map<String, String>.from(json['fieldIds'] as Map),
        relations: {
          for (final e in (json['relations'] as Map).entries)
            e.key as String: [
              for (final raw in e.value as List)
                InformationRelationRef.fromJson(raw as Map<String, dynamic>),
            ],
        },
      );
    } on TypeError {
      throw const FormatException('Invalid information layout');
    }
  }
}

/// Typed owner-only links. A dangling target remains a reference, not a grant.
final class InformationRelationRef {
  InformationRelationRef(this.kind, this.id) {
    if (!{'information', 'credential'}.contains(kind) || !_identity(id)) {
      throw const FormatException('Invalid information relation');
    }
  }
  final String kind, id;
  Map<String, Object?> toJson() => {'kind': kind, 'id': id};
  factory InformationRelationRef.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 || json['kind'] is! String || json['id'] is! String) {
      throw const FormatException('Invalid information relation');
    }
    return InformationRelationRef(json['kind'] as String, json['id'] as String);
  }
  @override
  bool operator ==(Object other) =>
      other is InformationRelationRef && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
}

bool _identity(String id) =>
    id.isNotEmpty &&
    id.length <= 200 &&
    id.codeUnits.every((c) => c >= 33 && c <= 126);
bool _key(String key) => key.trim().isNotEmpty && key.length <= 512;

Object? _freeze(Object? value, int depth) {
  if (depth > 32) throw const FormatException('Layout is too deep');
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List && value.length <= 2000) {
    return List<Object?>.unmodifiable(value.map((e) => _freeze(e, depth + 1)));
  }
  if (value is Map<String, Object?> &&
      value.length <= 2000 &&
      value.keys.every(_key)) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, value) => MapEntry(key, _freeze(value, depth + 1))),
    );
  }
  throw const FormatException('Invalid layout data');
}
