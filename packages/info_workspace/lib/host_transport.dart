import 'workspace_hosts.dart';
import 'workspace_transport.dart';

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  final j = workspaceObject(value);
  if (j.length != keys.length || !j.keys.toSet().containsAll(keys)) {
    throw const FormatException();
  }
  return j;
}

String _text(Object? value, {int max = 4096}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.contains('\u0000')) {
    throw const FormatException();
  }
  return value;
}

int _int(Object? value, {int max = 0x1fffffffffffff}) {
  if (value is! int || value < 1 || value > max) throw const FormatException();
  return value;
}

String _digest(Object? value) {
  final text = _text(value);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(text)) throw const FormatException();
  return text;
}

Map<String, Object?> hostFileToJson(WorkspaceHostFile f) => {
  'selectionId': f.selectionId,
  'name': f.name,
  'byteLength': f.byteLength,
};
WorkspaceHostFile hostFileFromJson(Object? raw) => decodeWorkspace(() {
  final j = _object(raw, {'selectionId', 'name', 'byteLength'});
  return WorkspaceHostFile(
    _text(j['selectionId'], max: 128),
    _text(j['name'], max: 255),
    _int(j['byteLength'], max: 1048576),
  );
});
Map<String, Object?> hostImportStatusToJson(WorkspaceHostImportStatus s) => {
  'name': s.name,
  'digest': s.digest,
  'entryCount': s.entryCount,
  'version': s.version,
};
WorkspaceHostImportStatus hostImportStatusFromJson(Object? raw) =>
    decodeWorkspace(() {
      final j = _object(raw, {'name', 'digest', 'entryCount', 'version'});
      return WorkspaceHostImportStatus(
        name: _text(j['name'], max: 255),
        digest: _digest(j['digest']),
        entryCount: _int(j['entryCount'], max: 131072),
        version: _int(j['version']),
      );
    });
Map<String, Object?> hostImportPreviewToJson(WorkspaceHostImportPreview p) => {
  'file': hostFileToJson(p.file),
  'digest': p.digest,
  'version': p.version,
  'pluginVersion': p.pluginVersion,
  'previous': p.previous == null ? null : hostImportStatusToJson(p.previous!),
  'entries': [
    for (final e in p.entries)
      {
        'pattern': e.pattern,
        'keyType': e.keyType,
        'fingerprint': e.fingerprint,
        'marker': e.marker,
      },
  ],
};
WorkspaceHostImportPreview hostImportPreviewFromJson(Object? raw) =>
    decodeWorkspace(() {
      final j = _object(raw, {
        'file',
        'digest',
        'version',
        'pluginVersion',
        'previous',
        'entries',
      });
      final entries = j['entries'];
      if (entries is! List || entries.isEmpty || entries.length > 131072) {
        throw const FormatException();
      }
      return WorkspaceHostImportPreview(
        file: hostFileFromJson(j['file']),
        digest: _digest(j['digest']),
        version: _int(j['version']),
        pluginVersion: _int(j['pluginVersion']),
        previous: j['previous'] == null
            ? null
            : hostImportStatusFromJson(j['previous']),
        entries: entries.map((value) {
          final e = _object(value, {
            'pattern',
            'keyType',
            'fingerprint',
            'marker',
          });
          if (e['marker'] != null &&
              !const {'@revoked', '@cert-authority'}.contains(e['marker'])) {
            throw const FormatException();
          }
          return WorkspaceHostFileEntry(
            _text(e['pattern'], max: 1048576),
            _text(e['keyType'], max: 128),
            _text(e['fingerprint'], max: 128),
            e['marker'] as String?,
          );
        }),
      );
    });
Map<String, Object?> hostImportChangeToJson(WorkspaceHostImportChange c) => {
  'version': 1,
  'operationId': c.operationId,
  'preview': hostImportPreviewToJson(c.preview),
};
WorkspaceHostImportChange hostImportChangeFromJson(Object? raw) =>
    decodeWorkspace(() {
      final j = _object(raw, {'version', 'operationId', 'preview'});
      if (j['version'] != 1) throw const FormatException();
      return WorkspaceHostImportChange(
        _text(j['operationId'], max: 128),
        hostImportPreviewFromJson(j['preview']),
      );
    });
Map<String, Object?> hostImportReceiptToJson(WorkspaceHostImportReceipt r) => {
  'version': 1,
  'operationId': r.operationId,
  'selectionId': r.selectionId,
  'expectedVersion': r.expectedVersion,
  'expectedPluginVersion': r.expectedPluginVersion,
  'result': hostImportStatusToJson(r.result),
};
WorkspaceHostImportReceipt hostImportReceiptFromJson(Object? raw) =>
    decodeWorkspace(() {
      final j = _object(raw, {
        'version',
        'operationId',
        'selectionId',
        'expectedVersion',
        'expectedPluginVersion',
        'result',
      });
      if (j['version'] != 1) throw const FormatException();
      return WorkspaceHostImportReceipt(
        operationId: _text(j['operationId'], max: 128),
        selectionId: _text(j['selectionId'], max: 128),
        expectedVersion: _int(j['expectedVersion']),
        expectedPluginVersion: _int(j['expectedPluginVersion']),
        result: hostImportStatusFromJson(j['result']),
      );
    });
Map<String, Object?> hostTargetToJson(WorkspaceHostTarget t) => {
  'record': t.record == null ? null : recordRefToJson(t.record!),
  'identityId': t.identityId,
};
WorkspaceHostTarget hostTargetFromJson(Object? raw) => decodeWorkspace(() {
  final j = _object(raw, {'record', 'identityId'});
  if ((j['record'] == null) == (j['identityId'] == null)) {
    throw const FormatException();
  }
  return j['record'] != null
      ? WorkspaceHostTarget.record(recordRefFromJson(j['record']))
      : WorkspaceHostTarget.identity(_text(j['identityId'], max: 128));
});
Map<String, Object?> hostIdentityToJson(WorkspaceHostIdentity h) => {
  'target': hostTargetToJson(h.target),
  'name': h.name,
  'identityId': h.identityId,
  'endpoint': h.endpoint == null
      ? null
      : {'host': h.endpoint!.host, 'port': h.endpoint!.port},
  'state': h.state.name,
  'version': h.version,
  'pluginVersion': h.pluginVersion,
  'pluginEnabled': h.pluginEnabled,
  'recordVersion': h.recordVersion,
  'fingerprint': h.fingerprint,
  'trustedFingerprint': h.trustedFingerprint,
};
WorkspaceHostIdentity hostIdentityFromJson(Object? raw) => decodeWorkspace(() {
  final j = _object(raw, {
    'target',
    'name',
    'identityId',
    'endpoint',
    'state',
    'version',
    'pluginVersion',
    'pluginEnabled',
    'recordVersion',
    'fingerprint',
    'trustedFingerprint',
  });
  WorkspaceHostEndpoint? endpoint;
  if (j['endpoint'] != null) {
    final e = _object(j['endpoint'], {'host', 'port'});
    endpoint = WorkspaceHostEndpoint.parse(
      _text(e['host']),
      _int(e['port'], max: 65535),
    );
    if (endpoint == null) throw const FormatException();
  }
  if (j['pluginEnabled'] is! bool) throw const FormatException();
  return WorkspaceHostIdentity(
    target: hostTargetFromJson(j['target']),
    name: _text(j['name']),
    identityId: _text(j['identityId']),
    endpoint: endpoint,
    state: WorkspaceHostState.values.byName(_text(j['state'])),
    version: _int(j['version']),
    pluginVersion: _int(j['pluginVersion']),
    pluginEnabled: j['pluginEnabled'] as bool,
    recordVersion: j['recordVersion'] == null ? null : _int(j['recordVersion']),
    fingerprint: j['fingerprint'] == null
        ? null
        : _text(j['fingerprint'], max: 1048576),
    trustedFingerprint: j['trustedFingerprint'] == null
        ? null
        : _text(j['trustedFingerprint'], max: 1048576),
  );
});
Map<String, Object?> hostChangeToJson(WorkspaceHostChange c) => {
  'version': 1,
  'operationId': c.operationId,
  'action': c.action.name,
  'reviewed': hostIdentityToJson(c.reviewed),
  'acknowledgeChanged': c.acknowledgeChanged,
};
WorkspaceHostChange hostChangeFromJson(Object? raw) => decodeWorkspace(() {
  final j = _object(raw, {
    'version',
    'operationId',
    'action',
    'reviewed',
    'acknowledgeChanged',
  });
  if (j['version'] != 1 || j['acknowledgeChanged'] is! bool) {
    throw const FormatException();
  }
  return WorkspaceHostChange(
    operationId: _text(j['operationId'], max: 128),
    action: WorkspaceHostAction.values.byName(_text(j['action'])),
    reviewed: hostIdentityFromJson(j['reviewed']),
    acknowledgeChanged: j['acknowledgeChanged'] as bool,
  );
});
Map<String, Object?> hostReceiptToJson(WorkspaceHostReceipt r) => {
  'version': 1,
  'operationId': r.operationId,
  'action': r.action.name,
  'identityId': r.identityId,
  'expectedVersion': r.expectedVersion,
  'resultVersion': r.version,
  'targetKey': r.targetKey,
  'expectedPluginVersion': r.expectedPluginVersion,
  'expectedRecordVersion': r.expectedRecordVersion,
};
WorkspaceHostReceipt hostReceiptFromJson(Object? raw) => decodeWorkspace(() {
  final j = _object(raw, {
    'version',
    'operationId',
    'action',
    'identityId',
    'expectedVersion',
    'resultVersion',
    'targetKey',
    'expectedPluginVersion',
    'expectedRecordVersion',
  });
  if (j['version'] != 1) throw const FormatException();
  return WorkspaceHostReceipt(
    operationId: _text(j['operationId'], max: 128),
    action: WorkspaceHostAction.values.byName(_text(j['action'])),
    identityId: _text(j['identityId']),
    expectedVersion: _int(j['expectedVersion']),
    version: _int(j['resultVersion']),
    targetKey: _text(j['targetKey']),
    expectedPluginVersion: _int(j['expectedPluginVersion']),
    expectedRecordVersion: j['expectedRecordVersion'] == null
        ? null
        : _int(j['expectedRecordVersion']),
  );
});
