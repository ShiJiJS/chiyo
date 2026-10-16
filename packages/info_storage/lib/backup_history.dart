part of 'info_storage.dart';

Never _backupInvalid() => throw const StorageFailure('invalid_backup');

DateTime _backupDate(Object? value) {
  if (value is! String || value.length > 32) _backupInvalid();
  final parsed = DateTime.tryParse(value);
  if (parsed == null ||
      !parsed.isUtc ||
      parsed.year < 1970 ||
      parsed.year > 9999 ||
      parsed.toIso8601String() != value)
    _backupInvalid();
  return parsed;
}

String _backupText(
  Map<String, dynamic> row,
  String key,
  int limit, {
  bool required = false,
}) {
  final value = row[key];
  if (value is! String ||
      value.length > limit ||
      (required && value.trim().isEmpty))
    _backupInvalid();
  return value;
}

String _backupId(Map<String, dynamic> row, String key) =>
    _backupText(row, key, 200, required: true);
int _backupVersion(Map<String, dynamic> row, [String key = 'version']) {
  final value = row[key];
  if (value is! int || value < 1 || value > 2147483647) _backupInvalid();
  return value;
}

Map<String, dynamic> _backupObject(
  Object? value,
  Set<String> required, [
  Set<String> optional = const {},
]) {
  if (value is! Map<String, dynamic> ||
      !value.keys.toSet().containsAll(required) ||
      value.keys.any((k) => !required.contains(k) && !optional.contains(k)))
    _backupInvalid();
  return value;
}

List<dynamic> _backupList(Object? value, int limit) {
  if (value is! List || value.length > limit) _backupInvalid();
  return value;
}

Map<String, dynamic> _backupJson(Map<String, Object?> row) {
  final payload = row['payload'];
  if (payload is! String || payload.length > InformationBackups.maxPayloadBytes)
    _backupInvalid();
  final decoded = jsonDecode(payload);
  if (decoded is! Map<String, dynamic>) _backupInvalid();
  return decoded;
}

void _validateBackupHistory(
  Map<String, List<Map<String, Object?>>> tables,
  DateTime createdAt,
) {
  final directories = tables['information_directories']!
      .map((r) => r['id'])
      .toSet();
  final tags = tables['information_tags']!.map((r) => r['id']).toSet();
  final fieldOwners = <String, String>{};
  var nestedCount = 0;
  void count(int n) {
    nestedCount += n;
    if (nestedCount > 500000) _backupInvalid();
  }

  void fieldOwner(String field, String item) {
    final previous = fieldOwners[field];
    if (previous != null && previous != item) _backupInvalid();
    fieldOwners[field] = item;
  }

  for (final field in tables['information_fields']!) {
    fieldOwner(field['id'] as String, field['item_id'] as String);
  }
  DateTime past(Object? value) {
    final date = _backupDate(value);
    if (date.isAfter(createdAt)) _backupInvalid();
    return date;
  }

  InformationItem snapshot(Object? raw) {
    final item = _backupObject(raw, {
      'id',
      'name',
      'description',
      'version',
      'directoryId',
      'tagIds',
      'fields',
    });
    final itemId = _backupId(item, 'id');
    _backupText(item, 'name', 200, required: true);
    _backupText(item, 'description', 2000);
    _backupVersion(item);
    if (item['directoryId'] != null &&
        !directories.contains(item['directoryId']))
      _backupInvalid();
    final itemTags = _backupList(item['tagIds'], 100);
    if (itemTags.toSet().length != itemTags.length ||
        itemTags.any((t) => t is! String || !tags.contains(t)))
      _backupInvalid();
    final fields = _backupList(item['fields'], 200);
    count(fields.length + itemTags.length);
    final seen = <String>{};
    for (final rawField in fields) {
      final field = _backupObject(rawField, {
        'id',
        'name',
        'description',
        'value',
        'version',
        'kind',
      });
      final fieldId = _backupId(field, 'id');
      if (!seen.add(fieldId)) _backupInvalid();
      fieldOwner(fieldId, itemId);
      _backupText(field, 'name', 200, required: true);
      _backupText(field, 'description', 2000);
      _backupText(field, 'value', 1000000);
      _backupVersion(field);
      if (!FieldKind.values.any((v) => v.name == field['kind']))
        _backupInvalid();
    }
    return informationFromJson(item);
  }

  final revisionPairs = <String>{};
  for (final row in tables['information_revisions']!) {
    final item = snapshot(_backupJson(row));
    if (item.id != row['item_id'] ||
        item.version != row['version'] ||
        !revisionPairs.add(jsonEncode([item.id, item.version])))
      _backupInvalid();
    past(row['replaced_at']);
  }
  final entryIds = <String>{};
  for (final row in tables['recycle_entries']!) {
    final j = _backupObject(
      _backupJson(row),
      {
        'id',
        'itemId',
        'wholeItem',
        'deletedAt',
        'expiresAt',
        'version',
        'state',
      },
      {'snapshot'},
    );
    final entryId = _backupId(j, 'id');
    final itemId = _backupId(j, 'itemId');
    if (entryId != row['id'] ||
        !entryIds.add(entryId) ||
        j['wholeItem'] is! bool)
      _backupInvalid();
    final version = _backupVersion(j);
    final deletedAt = past(j['deletedAt']);
    final expiresAt = _backupDate(j['expiresAt']);
    if (expiresAt.difference(deletedAt) != const Duration(days: 30) ||
        !RecycleState.values.any((v) => v.name == j['state']))
      _backupInvalid();
    if (j['state'] == 'available') {
      final item = snapshot(j['snapshot']);
      if (item.id != itemId ||
          item.version >= version ||
          (j['wholeItem'] == false && item.fields.isEmpty))
        _backupInvalid();
    } else if (j.containsKey('snapshot')) {
      _backupInvalid();
    }
  }
  final facts = <String>{};
  for (final row in tables['recycle_facts']!) {
    final j = _backupObject(_backupJson(row), {
      'entryId',
      'itemId',
      'fieldIds',
      'version',
      'kind',
      'at',
    });
    _backupId(j, 'entryId');
    final item = _backupId(j, 'itemId');
    _backupVersion(j);
    past(j['at']);
    if (!RecycleFactKind.values.any((v) => v.name == j['kind']) ||
        !facts.add(jsonEncode(j)))
      _backupInvalid();
    final fields = _backupList(j['fieldIds'], 200);
    count(fields.length);
    if (fields.toSet().length != fields.length) _backupInvalid();
    for (final field in fields) {
      if (field is! String || field.isEmpty || field.length > 200)
        _backupInvalid();
      fieldOwner(field, item);
    }
  }
  final purgePairs = <String>{};
  for (final row in tables['revision_purge_facts']!) {
    final j = Map<String, dynamic>.from(row);
    _backupId(j, 'item_id');
    _backupVersion(j);
    past(j['purged_at']);
    if (!purgePairs.add(jsonEncode([j['item_id'], j['version']])))
      _backupInvalid();
  }
  final grantIds = <String>{};
  for (final row in tables['grant_history']!) {
    final j = _backupObject(
      _backupJson(row),
      {
        'id',
        'requestId',
        'sessionId',
        'chatLabel',
        'approvedAt',
        'expiresAt',
        'fields',
        'events',
      },
      {'restoredAt'},
    );
    final id = _backupId(j, 'id');
    _backupId(j, 'requestId');
    _backupId(j, 'sessionId');
    _backupText(j, 'chatLabel', 200, required: true);
    final approvedAt = past(j['approvedAt']);
    final expiresAt = _backupDate(j['expiresAt']);
    if (id != row['id'] ||
        row['approved_at'] != approvedAt.millisecondsSinceEpoch ||
        !grantIds.add(id) ||
        expiresAt.difference(approvedAt) < const Duration(minutes: 1) ||
        expiresAt.difference(approvedAt) > const Duration(days: 7))
      _backupInvalid();
    if (j.containsKey('restoredAt')) past(j['restoredAt']);
    final fields = _backupList(j['fields'], 200);
    final seen = <String>{};
    if (fields.isEmpty) _backupInvalid();
    count(fields.length);
    for (final raw in fields) {
      final f = _backupObject(raw, {
        'itemId',
        'fieldId',
        'itemName',
        'fieldName',
      });
      final itemId = _backupId(f, 'itemId');
      final fieldId = _backupId(f, 'fieldId');
      if (!seen.add(jsonEncode([itemId, fieldId]))) _backupInvalid();
      fieldOwner(fieldId, itemId);
      _backupText(f, 'itemName', 200, required: true);
      _backupText(f, 'fieldName', 200, required: true);
    }
    final events = _backupList(j['events'], 2);
    if (events.isEmpty) _backupInvalid();
    for (var index = 0; index < events.length; index++) {
      final e = _backupObject(events[index], {'kind', 'at'});
      final at = past(e['at']);
      if (!GrantEventKind.values.any((v) => v.name == e['kind']) ||
          (index == 0 && (e['kind'] != 'approved' || at != approvedAt)) ||
          (index > 0 && (e['kind'] == 'approved' || at.isBefore(approvedAt))))
        _backupInvalid();
    }
  }
  final accessIds = <String>{};
  for (final row in tables['access_records']!) {
    final j = _backupObject(_backupJson(row), {
      'id',
      'at',
      'operation',
      'outcome',
      'sessionId',
      'grantId',
      'itemId',
      'fieldId',
    });
    final id = _backupId(j, 'id');
    final at = past(j['at']);
    if (id != row['id'] ||
        row['recorded_at'] != at.millisecondsSinceEpoch ||
        !accessIds.add(id) ||
        j['operation'] != 'read' ||
        !AccessOutcome.values.any((v) => v.name == j['outcome']))
      _backupInvalid();
    for (final key in ['sessionId', 'grantId', 'itemId', 'fieldId']) {
      if (j[key] != null) _backupId(j, key);
    }
    if ((j['itemId'] == null) != (j['fieldId'] == null)) _backupInvalid();
    if (j['itemId'] != null)
      fieldOwner(j['fieldId'] as String, j['itemId'] as String);
  }
}

extension _CompleteBackups on InformationBackups {
  BackupContents _retain(
    BackupContents contents,
    DateTime now, {
    bool restored = false,
  }) {
    if (contents.createdAt.isAfter(now.add(const Duration(minutes: 5))))
      _backupInvalid();
    final tables = {
      for (final table in contents._tables.entries)
        table.key: table.value.toList(),
    };
    final cutoff = now.subtract(const Duration(days: 30));
    final purges = {
      for (final row in tables['revision_purge_facts']!)
        jsonEncode([row['item_id'], row['version']]),
    };
    tables['information_revisions']!.removeWhere((row) {
      if (_backupDate(row['replaced_at']).isAfter(cutoff)) return false;
      if (purges.add(jsonEncode([row['item_id'], row['version']])))
        tables['revision_purge_facts']!.add({
          'item_id': row['item_id'],
          'version': row['version'],
          'purged_at': now.toIso8601String(),
        });
      return true;
    });
    tables['recycle_entries'] = tables['recycle_entries']!.map((row) {
      final entry = RecycleEntry.fromJson(_backupJson(row));
      if (entry.state != RecycleState.available ||
          now.isBefore(entry.expiresAt))
        return row;
      tables['recycle_facts']!.add({
        'payload': jsonEncode(
          RecycleFact(
            entry.id,
            entry.itemId,
            entry.snapshot!.fields.map((f) => f.id),
            entry.version,
            RecycleFactKind.purged,
            now,
          ).toJson(),
        ),
      });
      return {
        'id': entry.id,
        'payload': jsonEncode(entry.finish(RecycleState.purged).toJson()),
      };
    }).toList();
    var days = 90;
    for (final setting in tables['settings']!) {
      if (setting['name'] == 'auditRetentionDays')
        days = setting['value'] as int;
    }
    final auditCutoff = now.subtract(Duration(days: days));
    tables['grant_history']!.removeWhere(
      (row) => DateTime.fromMillisecondsSinceEpoch(
        row['approved_at'] as int,
        isUtc: true,
      ).isBefore(auditCutoff),
    );
    tables['access_records']!.removeWhere(
      (row) => DateTime.fromMillisecondsSinceEpoch(
        row['recorded_at'] as int,
        isUtc: true,
      ).isBefore(auditCutoff),
    );
    if (restored)
      tables['grant_history'] = tables['grant_history']!
          .map(
            (row) => {
              ...row,
              'payload': jsonEncode(
                GrantHistory.fromJson(
                  _backupJson(row),
                ).asRestored(now).toJson(),
              ),
            },
          )
          .toList();
    return BackupContents._(
      Map.unmodifiable({
        for (final t in tables.entries)
          t.key: List<Map<String, Object?>>.unmodifiable(
            t.value.map(Map<String, Object?>.unmodifiable),
          ),
      }),
      contents.createdAt,
      contents.formatVersion,
    );
  }

  void Function() _prepareInstall(BackupContents contents) {
    final tables = contents._tables;
    final fields = tables['information_fields']!;
    final links = tables['information_item_tags']!;
    final items = [
      for (final row in tables['information_items']!)
        _informationFromRows(row, fields, links),
    ];
    final directories = [
      for (final r in tables['information_directories']!)
        InformationDirectory(
          r['id'] as String,
          r['name'] as String,
          r['parent_id'] as String?,
          r['version'] as int,
        ),
    ];
    final tags = [
      for (final r in tables['information_tags']!)
        InformationTag(
          r['id'] as String,
          r['name'] as String,
          r['version'] as int,
        ),
    ];
    final templates = [
      for (final r in tables['field_templates']!)
        InformationTemplate(
          r['id'] as String,
          r['name'] as String,
          r['description'] as String,
          r['version'] as int,
          (jsonDecode(r['fields_json'] as String) as List).map(
            (dynamic f) => TemplateFieldDefinition(
              f['id'] as String,
              f['name'] as String,
              f['description'] as String,
              FieldKind.values.byName(f['kind'] as String),
            ),
          ),
        ),
    ];
    final history = tables['grant_history']!
        .map((r) => GrantHistory.fromJson(_backupJson(r)))
        .toList();
    final accesses = tables['access_records']!
        .map((r) => AccessRecord.fromJson(_backupJson(r)))
        .toList();
    final revisions = tables['information_revisions']!
        .map(
          (r) => InformationRevision(
            informationFromJson(_backupJson(r)),
            _backupDate(r['replaced_at']),
          ),
        )
        .toList();
    final recycle = tables['recycle_entries']!
        .map((r) => RecycleEntry.fromJson(_backupJson(r)))
        .toList();
    final facts = tables['recycle_facts']!
        .map((r) => RecycleFact.fromJson(_backupJson(r)))
        .toList();
    final revisionPurges = tables['revision_purge_facts']!
        .map(
          (r) => RevisionPurgeFact(
            r['item_id'] as String,
            r['version'] as int,
            _backupDate(r['purged_at']),
          ),
        )
        .toList();
    final settings = {
      for (final row in tables['settings']!)
        row['name'] as String: row['value'] as int,
    };
    return () {
      _repository._items
        ..clear()
        ..addEntries(items.map((v) => MapEntry(v.id, v)));
      _repository._directories
        ..clear()
        ..addEntries(directories.map((v) => MapEntry(v.id, v)));
      _repository._tags
        ..clear()
        ..addEntries(tags.map((v) => MapEntry(v.id, v)));
      _repository._templates
        ..clear()
        ..addEntries(templates.map((v) => MapEntry(v.id, v)));
      _repository._history
        ..clear()
        ..addEntries(history.map((v) => MapEntry(v.id, v)));
      _repository._accesses
        ..clear()
        ..addEntries(accesses.map((v) => MapEntry(v.id, v)));
      _repository._revisions
        ..clear()
        ..addAll(revisions);
      _repository._recycle
        ..clear()
        ..addEntries(recycle.map((v) => MapEntry(v.id, v)));
      _repository._recycleFacts
        ..clear()
        ..addAll(facts);
      _repository._revisionPurges
        ..clear()
        ..addAll(revisionPurges);
      _repository._settings
        ..clear()
        ..addAll(settings);
      _repository._proposals.clear();
      _repository._updates.clear();
      _repository._deletes.clear();
    };
  }
}
