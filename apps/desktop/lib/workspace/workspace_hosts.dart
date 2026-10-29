import 'workspace_records.dart';
import 'workspace_host_imports.dart';
export 'workspace_host_imports.dart';

/// Owner-only, host-provided SSH identity projection. No network or key bytes.
class WorkspaceHostEndpoint {
  const WorkspaceHostEndpoint._(this.host, this.port);
  final String host;
  final int port;
  String get key => '$host|$port';
  String get label => '${host.contains(':') ? '[$host]' : host}:$port';

  static WorkspaceHostEndpoint? parse(Object? host, Object? port) {
    if (host is! String) return null;
    var h = host.trim().toLowerCase();
    final p = port == null || '$port'.trim().isEmpty
        ? 22
        : int.tryParse('$port'.trim());
    if (p == null || p < 1 || p > 65535 || h.isEmpty) return null;
    if (h.startsWith('[') && h.endsWith(']')) {
      h = h.substring(1, h.length - 1);
    }
    if (h.contains(':')) {
      try {
        final bytes = Uri.parseIPv6Address(h);
        h = [
          for (var i = 0; i < 16; i += 2)
            ((bytes[i] << 8) | bytes[i + 1]).toRadixString(16),
        ].join(':');
      } on FormatException {
        return null;
      }
    } else {
      if (h.endsWith('.')) h = h.substring(0, h.length - 1);
      if (h.length > 253 ||
          !h
              .split('.')
              .every(
                (v) => RegExp(
                  r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
                ).hasMatch(v),
              )) {
        return null;
      }
      if (RegExp(r'^[0-9.]+$').hasMatch(h)) {
        final pieces = h.split('.').map(int.tryParse).toList();
        if (pieces.length != 4 || pieces.any((v) => v == null || v > 255)) {
          return null;
        }
        h = pieces.join('.');
      }
    }
    return WorkspaceHostEndpoint._(h, p);
  }
}

enum WorkspaceHostState {
  invalid('地址或端口不完整'),
  missingFingerprint('尚未取得指纹'),
  unconfirmed('待核对'),
  trusted('已确认'),
  changed('指纹已变化'),
  revoked('已撤销');

  const WorkspaceHostState(this.label);
  final String label;
}

class WorkspaceHostTarget {
  const WorkspaceHostTarget.record(this.record) : identityId = null;
  const WorkspaceHostTarget.identity(this.identityId) : record = null;
  final WorkspaceRecordRef? record;
  final String? identityId;
  String get key => record == null ? 'identity:$identityId' : record!.key;
}

class WorkspaceHostIdentity {
  const WorkspaceHostIdentity({
    required this.target,
    required this.name,
    required this.identityId,
    required this.endpoint,
    required this.state,
    required this.version,
    required this.pluginVersion,
    required this.pluginEnabled,
    this.recordVersion,
    this.fingerprint,
    this.trustedFingerprint,
  });
  final WorkspaceHostTarget target;
  final String name, identityId;
  final WorkspaceHostEndpoint? endpoint;
  final WorkspaceHostState state;
  final int version, pluginVersion;
  final int? recordVersion;
  final bool pluginEnabled;
  final String? fingerprint, trustedFingerprint;
  bool get canConfirm =>
      pluginEnabled &&
      fingerprint != null &&
      endpoint != null &&
      state != WorkspaceHostState.trusted;
  bool get canRevoke => trustedFingerprint != null;
}

enum WorkspaceHostAction { confirm, revoke }

class WorkspaceHostChange {
  const WorkspaceHostChange({
    required this.operationId,
    required this.action,
    required this.reviewed,
    this.acknowledgeChanged = false,
  });
  final String operationId;
  final WorkspaceHostAction action;
  final WorkspaceHostIdentity reviewed;
  final bool acknowledgeChanged;
}

/// The original intent is represented by opaque identities/revisions only.
class WorkspaceHostReceipt {
  const WorkspaceHostReceipt({
    required this.operationId,
    required this.action,
    required this.identityId,
    required this.expectedVersion,
    required this.version,
    required this.targetKey,
    required this.expectedPluginVersion,
    this.expectedRecordVersion,
  });
  final String operationId, identityId, targetKey;
  final WorkspaceHostAction action;
  final int expectedVersion, version, expectedPluginVersion;
  final int? expectedRecordVersion;
}

abstract interface class WorkspaceHostSource {
  Future<WorkspaceHostImportStatus?> importedFile();
  Future<WorkspaceHostImportPreview> previewImport(String selectionId);
  Future<WorkspaceHostImportReceipt> importFile(
    WorkspaceHostImportChange change,
  );
  Future<WorkspaceHostImportReceipt?> importReceipt(String operationId);
  Future<void> releaseImport(String selectionId);
  Future<List<WorkspaceHostIdentity>> load();
  Future<WorkspaceHostIdentity> read(WorkspaceHostTarget target);
  Future<WorkspaceHostReceipt> change(WorkspaceHostChange change);

  /// null means confirmed absence, never a failed query.
  Future<WorkspaceHostReceipt?> receipt(String operationId);
}
