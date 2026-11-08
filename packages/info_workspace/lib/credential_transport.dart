import 'workspace_source.dart';
import 'workspace_transport.dart';

WorkspaceDetail credentialWorkspaceDetail(WorkspaceCredentialDetail c) =>
    WorkspaceDetail(
      record: c.record,
      version: c.recordVersion,
      definition: const {
        'fields': <Object?>[],
        'sections': <Object?>[],
        'relations': [
          {'key': 'related', 'label': '关联资料', 'targetTemplates': <String>[]},
        ],
      },
      relations: {'related': c.linkedInformation},
      incomingRelations: {'related': c.referencingInformation},
    );

/// Owner management metadata. Plaintext is confined to the dedicated private
/// input request, never these candidates, records, material history or receipts.
Map<String, Object?> credentialCandidateToJson(
  WorkspaceCredentialCandidate c,
) => {
  'id': c.id,
  'label': c.label,
  'form': c.form.name,
  'format': c.format,
  'delivery': c.delivery.name,
  'filename': c.filename,
  'binding': c.binding,
};
WorkspaceCredentialCandidate credentialCandidateFromJson(Object? value) =>
    decodeWorkspace(() {
      final c = workspaceObject(value);
      return WorkspaceCredentialCandidate(
        id: c['id'] as String,
        label: c['label'] as String,
        form: WorkspaceCredentialForm.values.byName(c['form'] as String),
        format: c['format'] as String,
        delivery: WorkspaceCredentialDelivery.values.byName(
          c['delivery'] as String,
        ),
        filename: c['filename'] as String?,
        binding: c['binding'] as String,
      );
    });
Map<String, Object?> credentialDetailToJson(WorkspaceCredentialDetail c) => {
  'record': recordSummaryToJson(c.record),
  'recordVersion': c.recordVersion,
  'materialVersion': c.materialVersion,
  'useGeneration': c.useGeneration,
  'enabled': c.enabled,
  'discoverable': c.discoverable,
  'useSupported': c.useSupported,
  'useUnavailableReason': c.useUnavailableReason,
  'form': c.form.name,
  'format': c.format,
  'delivery': c.delivery.name,
  'binding': c.binding,
  'privateNote': c.privateNote,
  'account': c.account,
  'filename': c.filename,
  'linkedInformation': c.linkedInformation.map(recordRefToJson).toList(),
  'linkedCredentials': c.linkedCredentials.map(recordRefToJson).toList(),
  'referencingInformation': c.referencingInformation
      .map(recordRefToJson)
      .toList(),
};
WorkspaceCredentialDetail credentialDetailFromJson(
  Object? value,
) => decodeWorkspace(() {
  final c = workspaceObject(value);
  return WorkspaceCredentialDetail(
    record: recordSummaryFromJson(c['record']),
    recordVersion: c['recordVersion'] as int,
    materialVersion: c['materialVersion'] as int,
    useGeneration: c['useGeneration'] as int,
    enabled: c['enabled'] as bool,
    discoverable: c['discoverable'] as bool,
    useSupported: c['useSupported'] as bool,
    useUnavailableReason: c['useUnavailableReason'] as String?,
    form: WorkspaceCredentialForm.values.byName(c['form'] as String),
    format: c['format'] as String,
    delivery: WorkspaceCredentialDelivery.values.byName(
      c['delivery'] as String,
    ),
    binding: c['binding'] as String,
    privateNote: c['privateNote'] as String,
    account: c['account'] as String,
    filename: c['filename'] as String?,
    linkedInformation: (c['linkedInformation'] as List).map(recordRefFromJson),
    linkedCredentials: (c['linkedCredentials'] as List).map(recordRefFromJson),
    referencingInformation: (c['referencingInformation'] as List).map(
      recordRefFromJson,
    ),
  );
});
Map<String, Object?> credentialWriteToJson(WorkspaceCredentialWrite c) => {
  'operationId': c.operationId,
  'name': c.name,
  'purpose': c.purpose,
  'privateNote': c.privateNote,
  'binding': c.binding,
  'directoryId': c.directoryId,
  'ref': c.ref == null ? null : recordRefToJson(c.ref!),
  'expectedRecordVersion': c.expectedRecordVersion,
  'expectedMaterialVersion': c.expectedMaterialVersion,
  'candidateId': c.candidateId,
  'discoverable': c.discoverable,
  'tagIds': c.tagIds,
  'linkedInformation': c.linkedInformation?.map(recordRefToJson).toList(),
};
WorkspaceCredentialWrite credentialWriteFromJson(Object? value) =>
    decodeWorkspace(() {
      final c = workspaceObject(value);
      if (c.length != 13 ||
          c.keys.any(
            (k) => !const {
              'operationId',
              'name',
              'purpose',
              'privateNote',
              'binding',
              'directoryId',
              'ref',
              'expectedRecordVersion',
              'expectedMaterialVersion',
              'candidateId',
              'discoverable',
              'tagIds',
              'linkedInformation',
            }.contains(k),
          )) {
        throw const FormatException();
      }
      return WorkspaceCredentialWrite(
        operationId: c['operationId'] as String,
        name: c['name'] as String,
        purpose: c['purpose'] as String,
        privateNote: c['privateNote'] as String,
        binding: c['binding'] as String,
        directoryId: c['directoryId'] as String?,
        ref: c['ref'] == null ? null : recordRefFromJson(c['ref']),
        expectedRecordVersion: c['expectedRecordVersion'] as int?,
        expectedMaterialVersion: c['expectedMaterialVersion'] as int?,
        candidateId: c['candidateId'] as String?,
        discoverable: c['discoverable'] as bool?,
        tagIds: (c['tagIds'] as List).cast<String>(),
        linkedInformation: (c['linkedInformation'] as List?)?.map(
          recordRefFromJson,
        ),
      );
    });
Map<String, Object?> credentialToggleToJson(WorkspaceCredentialToggle c) => {
  'operationId': c.operationId,
  'ref': recordRefToJson(c.ref),
  'expectedRecordVersion': c.expectedRecordVersion,
  'expectedMaterialVersion': c.expectedMaterialVersion,
  'enabled': c.enabled,
};
WorkspaceCredentialToggle credentialToggleFromJson(Object? value) =>
    decodeWorkspace(() {
      final c = workspaceObject(value);
      if (c.length != 5 ||
          c.keys.any(
            (k) => !const {
              'operationId',
              'ref',
              'expectedRecordVersion',
              'expectedMaterialVersion',
              'enabled',
            }.contains(k),
          )) {
        throw const FormatException();
      }
      return WorkspaceCredentialToggle(
        operationId: c['operationId'] as String,
        ref: recordRefFromJson(c['ref']),
        expectedRecordVersion: c['expectedRecordVersion'] as int,
        expectedMaterialVersion: c['expectedMaterialVersion'] as int,
        enabled: c['enabled'] as bool,
      );
    });
Map<String, Object?> credentialReceiptToJson(WorkspaceCredentialReceipt c) => {
  'ref': recordRefToJson(c.ref),
  'recordVersion': c.recordVersion,
  'materialVersion': c.materialVersion,
  'requestId': c.requestId,
  'entryId': c.entryId,
  'commandDigest': c.commandDigest,
  'notices': c.notices,
};
WorkspaceCredentialReceipt credentialReceiptFromJson(Object? value) =>
    decodeWorkspace(() {
      final c = workspaceObject(value);
      return WorkspaceCredentialReceipt(
        recordRefFromJson(c['ref']),
        c['recordVersion'] as int,
        c['materialVersion'] as int,
        requestId: c['requestId'] as String?,
        entryId: c['entryId'] as String?,
        commandDigest: c['commandDigest'] as String?,
        notices: (c['notices'] as List).cast<String>(),
      );
    });
Map<String, Object?> credentialMaterialsToJson(
  WorkspaceCredentialMaterialHistory h,
) => {
  'current': credentialDetailToJson(h.current),
  'materials': [
    for (final m in h.materials)
      {
        'version': m.version,
        'form': m.form.name,
        'format': m.format,
        'filename': m.filename,
        'createdAt': m.createdAt.toUtc().toIso8601String(),
        'retiredAt': m.retiredAt?.toUtc().toIso8601String(),
      },
  ],
};
WorkspaceCredentialMaterialHistory credentialMaterialsFromJson(Object? value) =>
    decodeWorkspace(() {
      final h = workspaceObject(value);
      return WorkspaceCredentialMaterialHistory(
        credentialDetailFromJson(h['current']),
        (h['materials'] as List).map((value) {
          final m = workspaceObject(value);
          return WorkspaceCredentialMaterial(
            version: m['version'] as int,
            form: WorkspaceCredentialForm.values.byName(m['form'] as String),
            format: m['format'] as String,
            filename: m['filename'] as String?,
            createdAt: DateTime.parse(m['createdAt'] as String),
            retiredAt: m['retiredAt'] == null
                ? null
                : DateTime.parse(m['retiredAt'] as String),
          );
        }),
      );
    });
