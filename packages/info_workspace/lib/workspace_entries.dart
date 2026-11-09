import 'dart:math';
import 'workspace_records.dart';

/// Owner detail only. IDs identify an entry and three independent leaf fields;
/// order and visible labels never serve as identity or authorization.
class WorkspaceRepeatedEntry {
  WorkspaceRepeatedEntry.fromJson(Map value)
    : _value = workspaceImmutableMap(Map<String, Object?>.from(value)),
      fieldIds = Map<String, String>.unmodifiable(
        Map<String, String>.from(value['fieldIds'] as Map),
      ) {
    if (value['entryId'] is! String ||
        parts.any((key) => value[key] is! String) ||
        fieldIds.isEmpty ||
        fieldIds.keys.any((key) => !parts.contains(key)) ||
        parts.any((key) => !fieldIds.containsKey(key) && value[key] != '')) {
      throw const FormatException('Invalid repeated entry.');
    }
    final definitions = value['definitions'];
    if (definitions != null &&
        (definitions is! Map ||
            definitions.entries.any(
              (e) =>
                  !parts.contains(e.key) ||
                  e.value is! Map ||
                  (e.value as Map)['label'] is! String,
            ))) {
      throw const FormatException('Invalid leaf definitions.');
    }
  }

  factory WorkspaceRepeatedEntry.empty() => WorkspaceRepeatedEntry.fromJson({
    'entryId': _newId('entry'),
    'fieldIds': {for (final key in parts) key: _newId('field')},
    for (final key in parts) key: '',
  });

  static const parts = ['title', 'period', 'detail'];
  static const maxEntriesPerField = 100;
  // Owner create/update and backup both currently cap an item at 200 fields.
  // S1's proposed 500 must not silently expand that existing limit.
  static const maxLeavesPerRecord = 200;
  static final _random = Random.secure();
  static String _newId(String prefix) =>
      '$prefix-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  final Map<String, Object?> _value;
  final Map<String, String> fieldIds;
  Iterable<String> get activeParts => parts.where(fieldIds.containsKey);
  String label(String part) => (_value['definitions'] as Map?)?[part] is Map
      ? (((_value['definitions'] as Map)[part] as Map)['label'] as String? ??
            labels[part]!)
      : labels[part]!;
  static const labels = {'title': '经历名称', 'period': '经历时间', 'detail': '经历说明'};
  String get id => _value['entryId'] as String;
  String get title => _value['title'] as String;
  String get period => _value['period'] as String;
  String get detail => _value['detail'] as String;

  WorkspaceRepeatedEntry withText(String key, String text) {
    if (!fieldIds.containsKey(key)) throw ArgumentError.value(key);
    return WorkspaceRepeatedEntry.fromJson({...toJson(), key: text});
  }

  Map<String, Object?> toJson() => {..._value, 'fieldIds': fieldIds};

  static List<WorkspaceRepeatedEntry> read(Object? value) {
    if (value == null) return const [];
    if (value is! List) throw const FormatException('Entries must be a list.');
    try {
      return List.unmodifiable([
        for (final row in value) WorkspaceRepeatedEntry.fromJson(row as Map),
      ]);
    } on TypeError {
      throw const FormatException('Invalid repeated entry shape.');
    }
  }
}
