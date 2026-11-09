import 'dart:convert';
import 'protocol_json.dart';
import 'import_proposals.dart';

/// Private online-host state. Never expose through catalogs, ordinary owner
/// settings, Agent responses, or portable information backups.
final class ServerStateSnapshot {
  ServerStateSnapshot({
    required this.generation,
    required this.revision,
    required Map<String, Object?> payload,
  }) : payload = _copy(payload) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(generation) || revision < 0) {
      throw const FormatException('Invalid server state');
    }
  }
  static const maxBytes = 16 * 1024 * 1024;
  final String generation;
  final int revision;
  final Map<String, Object?> payload;

  static Map<String, Object?> _copy(Map<String, Object?> value) {
    final json = jsonEncode(value);
    final decoded = decodeProtocolObject(json, maxBytes: maxBytes);
    Object? freeze(Object? v) {
      if (v is Map) {
        return Map<String, Object?>.unmodifiable(
          v.map((k, v) => MapEntry(k as String, freeze(v))),
        );
      }
      if (v is List) return List<Object?>.unmodifiable(v.map(freeze));
      return v;
    }

    return freeze(decoded) as Map<String, Object?>;
  }
}

/// Trusted host capability only, not part of AgentAccess. The generation
/// prevents a writer from before a restore replaying state into the new library.
abstract interface class ServerStateRepository {
  Future<ServerStateSnapshot> openServerState();
  Future<ServerStateSnapshot> commitServerState(
    ServerStateSnapshot expected,
    Map<String, Object?> payload,
  );
}

/// Save a private owner input revision and its retry receipt in the same
/// transaction. The receipt lives only in server state, never portable history.
abstract interface class ServerProposalPasswordRepository
    implements ServerStateRepository {
  Future<void> commitServerProposalPasswords(
    ServerStateSnapshot expected,
    Map<String, Object?> payload,
    ImportProposal revised,
    int expectedProposalVersion,
  );
}
