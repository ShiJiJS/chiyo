import 'dart:math';

/// Owner detail only. IDs identify an entry and three independent leaf fields;
/// order and visible labels never serve as identity or authorization.
class WorkspaceRepeatedEntry {
  WorkspaceRepeatedEntry.fromJson(Map value)
    : _value = Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(value),
      ),
      fieldIds = Map<String, String>.unmodifiable(
        Map<String, String>.from(value['fieldIds'] as Map),
      ) {
    if (value['entryId'] is! String ||
        parts.any((key) => value[key] is! String) ||
        fieldIds.length != parts.length ||
        parts.any((key) => !fieldIds.containsKey(key))) {
      throw const FormatException('Invalid repeated entry.');
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
  String get id => _value['entryId'] as String;
  String get title => _value['title'] as String;
  String get period => _value['period'] as String;
  String get detail => _value['detail'] as String;

  WorkspaceRepeatedEntry withText(String key, String text) {
    if (!parts.contains(key)) throw ArgumentError.value(key);
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
