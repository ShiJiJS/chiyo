import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_records.dart';

String sampleFieldId(WorkspaceRecordRef ref, String seed) =>
    'sample-field-${sha256.convert(utf8.encode('${ref.key}/$seed'))}';

WorkspaceDetail sampleWithFieldIds(
  WorkspaceDetail d, {
  WorkspaceDetail? previous,
}) {
  if (d.record.ref.kind == WorkspaceRecordKind.credential) return d;
  final entries = {
    for (final f in workspaceFields(d))
      if (f['type'] == 'entries') f['key'],
  };
  return WorkspaceDetail(
    record: d.record,
    version: d.version,
    templateState: d.templateState,
    definition: d.definition,
    values: d.values,
    relations: d.relations,
    retainedFields: d.retainedFields,
    retainedRelations: d.retainedRelations,
    fieldIds: {
      for (final key in {
        ...d.values.keys,
        ...workspaceFields(d).map((f) => f['key'] as String),
      }.where((k) => !entries.contains(k)))
        key:
            d.fieldIds[key] ??
            previous?.fieldIds[key] ??
            sampleFieldId(d.record.ref, '${d.version}/$key'),
    },
  );
}

Map<String, String> sampleRestoredFieldIds(
  WorkspaceDetail old,
  WorkspaceDetail? current,
  int version,
) {
  final active = current?.fieldIds.values.toSet() ?? <String>{};
  return {
    for (final e in old.fieldIds.entries)
      e.key: active.contains(e.value)
          ? e.value
          : sampleFieldId(old.record.ref, 'restore/$version/${e.key}'),
  };
}
