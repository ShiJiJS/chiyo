import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'library_replication.dart';
import 'protocol_json.dart';

/// Units that can be compared without merging individual fields. Information
/// includes its fields, relations and retained versions; credentials include
/// their protected material versions. A storage adapter validates each payload.
enum LibrarySyncKind {
  information,
  credential,
  directory,
  tag,
  template,
  plugin,
  order,
  recycle,
  history,
  attachment,
  sshTrust,
}

final class LibrarySyncKey {
  LibrarySyncKey(this.kind, this.id) {
    if (id.isEmpty || id.length > 256 || id.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException('Invalid synchronization entity');
    }
  }
  final LibrarySyncKind kind;
  final String id;
  Map<String, Object?> toJson() => {'kind': kind.name, 'id': id};
  factory LibrarySyncKey.fromJson(Map<String, dynamic> value) {
    _fields(value, {'kind', 'id'});
    if (value['kind'] is! String || value['id'] is! String) {
      throw const FormatException('Invalid synchronization entity');
    }
    if (!LibrarySyncKind.values.any((kind) => kind.name == value['kind'])) {
      throw const FormatException('Unsupported synchronization entity');
    }
    return LibrarySyncKey(
      LibrarySyncKind.values.byName(value['kind'] as String),
      value['id'] as String,
    );
  }
  @override
  bool operator ==(Object other) =>
      other is LibrarySyncKey && kind == other.kind && id == other.id;
  @override
  int get hashCode => Object.hash(kind, id);
  @override
  String toString() => '${kind.name}:$id';
}

/// A whole unit at the source's common base. Null content is a deletion, with
/// its own new version retained as a tombstone. Null base means never observed,
/// which differs from having observed a deleted unit's version.
final class LibrarySyncEdit {
  LibrarySyncEdit({
    required this.key,
    required this.baseVersion,
    required Map<String, Object?>? content,
  }) : content = content == null ? null : _object(content) {
    if (baseVersion != null) replicaDigest(baseVersion);
  }
  final LibrarySyncKey key;
  final String? baseVersion;
  final Map<String, Object?>? content;
}

final class LibrarySyncChange {
  LibrarySyncChange._(this.edit, this.version);
  final LibrarySyncEdit edit;
  LibrarySyncKey get key => edit.key;
  String? get baseVersion => edit.baseVersion;
  Map<String, Object?>? get content => edit.content;
  final String version;
  bool get deleted => content == null;
  Map<String, Object?> toJson() => {..._body(edit), 'version': version};
  static Map<String, Object?> _body(LibrarySyncEdit edit) => {
    'key': edit.key.toJson(),
    'baseVersion': edit.baseVersion,
    'content': edit.content,
  };
  @override
  String toString() => 'LibrarySyncChange($key, deleted: $deleted)';
}

/// One durable business transaction, never a selection of a proposal's rows.
/// The same operation is replayed with the same digest after a lost response.
/// Payloads are private owner data: never log or expose them on Agent routes.
/// Attachment bodies travel separately by immutable reference, not as JSON.
final class LibrarySyncBatch {
  LibrarySyncBatch({
    required this.libraryId,
    required this.sourceReplicaId,
    required this.operationId,
    required this.sequence,
    required Iterable<LibrarySyncEdit> edits,
  }) {
    libraryReplicaId(libraryId);
    libraryReplicaId(sourceReplicaId);
    replicaOperationId(operationId);
    if (sequence < 1 || sequence > 9007199254740991) {
      throw const FormatException('Invalid synchronization sequence');
    }
    final input = edits.toList();
    if (input.isEmpty || input.length > maxChanges) {
      throw const FormatException('Invalid synchronization batch size');
    }
    if (input.map((e) => e.key).toSet().length != input.length) {
      throw const FormatException('Duplicate synchronization entity');
    }
    input.sort((a, b) {
      final kind = a.key.kind.index.compareTo(b.key.kind.index);
      return kind != 0 ? kind : a.key.id.compareTo(b.key.id);
    });
    changes = List.unmodifiable([
      for (final edit in input)
        LibrarySyncChange._(
          edit,
          _digest({..._identity, ...LibrarySyncChange._body(edit)}),
        ),
    ]);
    digest = _digest(_body);
    if (utf8.encode(jsonEncode(toJson())).length > maxBytes) {
      throw const FormatException('Synchronization batch exceeds budget');
    }
  }

  // Match the portable repository row ceiling; a valid large proposal must
  // remain one transaction. The independent byte budget still bounds input.
  static const maxChanges = 500000;
  static const maxBytes = 64 * 1024 * 1024;
  final String libraryId, sourceReplicaId, operationId;
  final int sequence;
  late final List<LibrarySyncChange> changes;
  late final String digest;
  Map<String, Object?> get _identity => {
    'wireVersion': 2,
    'libraryId': libraryId,
    'sourceReplicaId': sourceReplicaId,
    'operationId': operationId,
    'sequence': sequence,
  };
  Map<String, Object?> get _body => {
    ..._identity,
    'changes': [for (final change in changes) change.toJson()],
  };
  Map<String, Object?> toJson() => {..._body, 'digest': digest};

  factory LibrarySyncBatch.decode(String source) => LibrarySyncBatch.fromJson(
    decodeProtocolObject(source, maxBytes: maxBytes),
  );

  factory LibrarySyncBatch.fromJson(Map<String, dynamic> value) {
    _fields(value, {
      'wireVersion',
      'libraryId',
      'sourceReplicaId',
      'operationId',
      'sequence',
      'changes',
      'digest',
    });
    if (value['wireVersion'] != 2 ||
        value['sequence'] is! int ||
        value['changes'] is! List) {
      throw const FormatException('Unsupported synchronization batch');
    }
    final raw = value['changes'] as List;
    if (raw.isEmpty || raw.length > maxChanges) {
      throw const FormatException('Invalid synchronization batch size');
    }
    final versions = <LibrarySyncKey, String>{};
    final edits = <LibrarySyncEdit>[];
    for (final entry in raw) {
      final change = _object(entry);
      _fields(change, {'key', 'baseVersion', 'version', 'content'});
      final key = LibrarySyncKey.fromJson(_object(change['key']));
      if (change['baseVersion'] != null && change['baseVersion'] is! String) {
        throw const FormatException('Invalid synchronization base');
      }
      edits.add(
        LibrarySyncEdit(
          key: key,
          baseVersion: change['baseVersion'] as String?,
          content: change['content'] == null
              ? null
              : _object(change['content']),
        ),
      );
      versions[key] = replicaDigest(change['version']);
    }
    final batch = LibrarySyncBatch(
      libraryId: libraryReplicaId(value['libraryId']),
      sourceReplicaId: libraryReplicaId(value['sourceReplicaId']),
      operationId: replicaOperationId(value['operationId']),
      sequence: value['sequence'] as int,
      edits: edits,
    );
    if (batch.digest != replicaDigest(value['digest']) ||
        batch.changes.any((e) => versions[e.key] != e.version)) {
      throw const FormatException('Synchronization integrity check failed');
    }
    return batch;
  }

  /// No wall clock or current device preference participates in this decision.
  /// One conflict holds the entire transaction, preserving proposal atomicity.
  LibrarySyncDecision compare({
    required String targetLibraryId,
    required Map<LibrarySyncKey, String> currentVersions,
    String? previousReceiptDigest,
  }) {
    if (targetLibraryId != libraryId) {
      throw const FormatException('Different synchronization library');
    }
    if (previousReceiptDigest != null) {
      if (previousReceiptDigest != digest) {
        throw const FormatException('Synchronization operation changed');
      }
      return const LibrarySyncDecision._(LibrarySyncAction.alreadyApplied, []);
    }
    final conflicts = [
      for (final change in changes)
        if (currentVersions[change.key] != change.baseVersion) change.key,
    ];
    return LibrarySyncDecision._(
      conflicts.isEmpty ? LibrarySyncAction.apply : LibrarySyncAction.conflict,
      List.unmodifiable(conflicts),
    );
  }

  @override
  String toString() =>
      'LibrarySyncBatch($operationId, sequence: $sequence, changes: ${changes.length})';
}

enum LibrarySyncAction { apply, alreadyApplied, conflict }

final class LibrarySyncDecision {
  const LibrarySyncDecision._(this.action, this.conflictingKeys);
  final LibrarySyncAction action;
  final List<LibrarySyncKey> conflictingKeys;
}

/// Durable owner-only receipt; it acknowledges a saved result, not a usable
/// authorization. A conflict receipt means both candidates are retained.
final class LibrarySyncReceipt {
  LibrarySyncReceipt({
    required this.libraryId,
    required this.receiverReplicaId,
    required this.sourceReplicaId,
    required this.operationId,
    required this.digest,
    required this.cursor,
    required this.conflict,
  }) {
    libraryReplicaId(libraryId);
    libraryReplicaId(receiverReplicaId);
    libraryReplicaId(sourceReplicaId);
    replicaOperationId(operationId);
    replicaDigest(digest);
    if (cursor < 1)
      throw const FormatException('Invalid synchronization receipt');
  }
  final String libraryId,
      receiverReplicaId,
      sourceReplicaId,
      operationId,
      digest;
  final int cursor;
  final bool conflict;
  Map<String, Object?> toJson() => {
    'wireVersion': 2,
    'libraryId': libraryId,
    'receiverReplicaId': receiverReplicaId,
    'sourceReplicaId': sourceReplicaId,
    'operationId': operationId,
    'digest': digest,
    'cursor': cursor,
    'outcome': conflict ? 'conflict' : 'applied',
  };
  factory LibrarySyncReceipt.fromJson(Map<String, dynamic> value) {
    _fields(value, {
      'wireVersion',
      'libraryId',
      'receiverReplicaId',
      'sourceReplicaId',
      'operationId',
      'digest',
      'cursor',
      'outcome',
    });
    if (value['wireVersion'] != 2 ||
        value['cursor'] is! int ||
        !{'applied', 'conflict'}.contains(value['outcome'])) {
      throw const FormatException('Invalid synchronization receipt');
    }
    return LibrarySyncReceipt(
      libraryId: libraryReplicaId(value['libraryId']),
      receiverReplicaId: libraryReplicaId(value['receiverReplicaId']),
      sourceReplicaId: libraryReplicaId(value['sourceReplicaId']),
      operationId: replicaOperationId(value['operationId']),
      digest: replicaDigest(value['digest']),
      cursor: value['cursor'] as int,
      conflict: value['outcome'] == 'conflict',
    );
  }
}

void _fields(Map<String, Object?> value, Set<String> fields) {
  if (value.length != fields.length || !fields.every(value.containsKey)) {
    throw const FormatException('Unsupported synchronization fields');
  }
}

String _digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value, 0)))).toString();

Map<String, dynamic> _object(Object? value) {
  final result = _canonical(value, 0);
  if (result is! Map<String, dynamic>) {
    throw const FormatException('Invalid synchronization object');
  }
  return result;
}

Object? _canonical(Object? value, int depth) {
  if (depth > 64) throw const FormatException('Synchronization nesting limit');
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid synchronization member');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return Map<String, dynamic>.unmodifiable({
      for (final key in keys) key: _canonical(value[key], depth + 1),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable([
      for (final member in value) _canonical(member, depth + 1),
    ]);
  }
  if (value == null || value is String || value is bool || value is num) {
    if (value is num && !value.isFinite) {
      throw const FormatException('Invalid synchronization number');
    }
    return value;
  }
  throw const FormatException('Invalid synchronization value');
}
