import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_entries.dart';
import 'workspace_records.dart';

Iterable<String> _entryKeys(Map<String, Object?> definition) sync* {
  for (final field in definition['fields'] as List? ?? []) {
    if (field['type'] == 'entries') yield field['key'] as String;
  }
}

String _identity(String seed) => sha256.convert(utf8.encode(seed)).toString();

/// Identity-only tombstones contain no field values. A purge cannot make old
/// identities available to a different new record in the same sample session.
Map<String, String> sampleEntryOwners(WorkspaceDetail detail) {
  final owners = <String, String>{};
  for (final key in _entryKeys(detail.definition)) {
    try {
      for (final entry in WorkspaceRepeatedEntry.read(detail.values[key])) {
        owners[entry.id] = '${detail.record.ref.key}/$key/${entry.id}/entry';
        for (final part in WorkspaceRepeatedEntry.parts) {
          owners[entry.fieldIds[part]!] =
              '${detail.record.ref.key}/$key/${entry.id}/$part';
        }
      }
    } on FormatException {
      // Unknown historical shapes remain read-only.
    }
  }
  return owners;
}

/// Only the fictional adapter upgrades the old frozen fixture shape. Real
/// adapters must supply their actual entry/field identities, not these seeds.
Map<String, Object?> sampleInitialEntries(
  WorkspaceRecordRef ref,
  Map<String, Object?> definition,
  Map<String, Object?> values,
) => {
  ...values,
  for (final key in _entryKeys(definition))
    if (values[key] is List)
      key: [
        for (final (index, raw) in (values[key] as List).indexed)
          if (raw is Map)
            {
              ...raw,
              'entryId':
                  raw['entryId'] ??
                  'sample-entry-${_identity('${ref.key}/$key/$index')}',
              'fieldIds':
                  raw['fieldIds'] ??
                  {
                    for (final part in WorkspaceRepeatedEntry.parts)
                      part:
                          'sample-field-${_identity('${ref.key}/$key/$index/$part')}',
                  },
              for (final part in WorkspaceRepeatedEntry.parts)
                part: raw[part] ?? '',
            }
          else
            raw,
      ],
};

Map<String, String> sampleEntryErrors(
  Map<String, Object?> definition,
  Map<String, Object?> values, {
  WorkspaceDetail? current,
  required Iterable<WorkspaceDetail> known,
  Map<String, String> identityOwners = const {},
}) {
  final errors = <String, String>{};
  final owners = {...identityOwners};
  String owner(WorkspaceRecordRef ref, String key, String id, String part) =>
      '${ref.key}/$key/$id/$part';
  for (final detail in known) {
    for (final key in _entryKeys(detail.definition)) {
      try {
        for (final entry in WorkspaceRepeatedEntry.read(detail.values[key])) {
          owners[entry.id] = owner(detail.record.ref, key, entry.id, 'entry');
          for (final part in WorkspaceRepeatedEntry.parts) {
            owners[entry.fieldIds[part]!] = owner(
              detail.record.ref,
              key,
              entry.id,
              part,
            );
          }
        }
      } on FormatException {
        // Malformed historical values remain readable; never stringify them.
      }
    }
  }
  final seen = <String>{};
  var leaves = (definition['fields'] as List? ?? [])
      .where((f) => f['type'] != 'entries')
      .length;
  final identityPattern = RegExp(r'^[a-zA-Z0-9:_.-]{1,160}$');
  for (final key in _entryKeys(definition)) {
    List<WorkspaceRepeatedEntry> entries;
    try {
      entries = WorkspaceRepeatedEntry.read(values[key]);
    } on FormatException {
      errors[key] = '经历结构无法编辑，请保留原文并核对来源。';
      continue;
    }
    leaves += entries.length * 3;
    if (entries.length > WorkspaceRepeatedEntry.maxEntriesPerField ||
        leaves > WorkspaceRepeatedEntry.maxLeavesPerRecord) {
      errors[key] = '每组最多100段经历，每项资料最多200个字段。';
    }
    final active = <String, WorkspaceRepeatedEntry>{};
    try {
      for (final e in WorkspaceRepeatedEntry.read(current?.values[key])) {
        active[e.id] = e;
      }
    } on FormatException {
      // A malformed legacy collection cannot confer an existing identity.
    }
    for (final entry in entries) {
      final path = '$key:${entry.id}';
      for (final (part, value, maximum) in [
        ('title', entry.title, 160),
        ('period', entry.period, 160),
        ('detail', entry.detail, 2000),
      ]) {
        if ((part == 'title' && value.trim().isEmpty) ||
            value.length > maximum) {
          errors['$path:$part'] = part == 'title'
              ? '请填写1–160字的经历名称。'
              : '不能超过$maximum字。';
        }
      }
      final retained = active[entry.id];
      for (final (part, id) in [
        ('entry', entry.id),
        for (final part in WorkspaceRepeatedEntry.parts)
          (part, entry.fieldIds[part]!),
      ]) {
        if (!identityPattern.hasMatch(id) || !seen.add(id)) {
          errors[key] = '经历与字段身份必须有效且不能重复。';
        }
        final previous = owners[id];
        if (previous != null &&
            (retained == null ||
                current == null ||
                previous != owner(current.record.ref, key, entry.id, part))) {
          errors[key] = '不能重复使用已移除或其他资料的经历/字段身份。';
        }
        if (part != 'entry' &&
            retained != null &&
            retained.fieldIds[part] != id) {
          errors[key] = '修改和排序必须保留原字段身份。';
        }
      }
    }
  }
  return errors;
}

/// Restoration is explicit. Retained leaves keep their current identities;
/// removed entries get fresh deterministic identities for the new version.
Map<String, Object?> sampleRestoredEntries(
  WorkspaceDetail old,
  WorkspaceDetail? current,
  int version,
) {
  final values = {...old.values};
  for (final key in _entryKeys(old.definition)) {
    try {
      final active = {
        for (final e in WorkspaceRepeatedEntry.read(current?.values[key]))
          e.id: e,
      };
      values[key] = [
        for (final entry in WorkspaceRepeatedEntry.read(old.values[key]))
          if (active[entry.id] case final retained?)
            {...entry.toJson(), 'fieldIds': retained.fieldIds}
          else
            {
              ...entry.toJson(),
              'entryId':
                  'restored-entry-${_identity('${old.record.ref.key}/$version/$key/${entry.id}')}',
              'fieldIds': {
                for (final part in WorkspaceRepeatedEntry.parts)
                  part:
                      'restored-field-${_identity('${old.record.ref.key}/$version/$key/${entry.id}/$part')}',
              },
            },
      ];
    } on FormatException {
      // Unknown historical shapes are preserved exactly as read-only values.
    }
  }
  return values;
}
