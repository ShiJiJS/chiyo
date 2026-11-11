import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'owner_runtime_materials.dart';
import 'owner_agent_sessions.dart';
import 'agent_sessions.dart';
import 'server_runtime_observation.dart';
import 'workspace_source.dart';

class OwnerRuntimeObservation {
  OwnerRuntimeObservation(this.owner)
    : _scope = owner.captureLibraryScope(),
      _materials = OwnerRuntimeMaterials(owner),
      _sessions = OwnerAgentSessions(owner);
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;
  final OwnerRuntimeMaterials _materials;
  final OwnerAgentSessions _sessions;
  Future<WorkspaceServerRuntimeObservation> read() async {
    try {
      return await owner.inLibraryScope(_scope, () async {
        final sessions = await _sessions.read();
        final materials = _materials.materials(), copies = _materials.copies();
        final active = sessions.sessions.where(
          (s) => s.state == WorkspaceAgentSessionState.linked,
        );
        final unconfirmed = owner.credentialExecutions
            .where(
              (e) =>
                  e.restoredAt == null &&
                  const {'preparing', 'running', 'unknown'}.contains(e.state),
            )
            .length;
        final revision = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  sessions.revision,
                  unconfirmed,
                  materials.map((m) => m.observationDigest).toList(),
                  copies
                      .map(
                        (c) => [
                          c.id,
                          c.requestId,
                          c.record.key,
                          c.name,
                          c.fileVersion,
                          c.expiresAt.toUtc().toIso8601String(),
                          c.state.name,
                          c.reason,
                        ],
                      )
                      .toList(),
                ]),
              ),
            )
            .toString();
        return WorkspaceServerRuntimeObservation(
          revision: revision,
          materials: List.unmodifiable(materials),
          copies: List.unmodifiable(copies),
          sessions: active.length,
          grants: active.fold(0, (n, s) => n + s.activeGrants),
          pendingRequests: active.fold(0, (n, s) => n + s.pendingRequests),
          unconfirmedProcesses: unconfirmed,
        );
      });
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(e.status, '无法读取服务器执行状态，请重新连接。');
    }
  }
}
