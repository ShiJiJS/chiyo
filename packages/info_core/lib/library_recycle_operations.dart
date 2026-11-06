part of 'info_core.dart';

enum LibraryRecycleAction { recycle, restore }

/// A group points to the normal content recycle entries and retired credential
/// versions. It stores directory and public record metadata, never a second
/// copy of field values or password material.
class LibraryRecycleBatch {
  LibraryRecycleBatch({
    required this.id,
    required this.deletedAt,
    required this.expiresAt,
    required Iterable<InformationDirectory> directories,
    required Iterable<LibraryRecycleRecord> records,
    required Map<String, List<String>> directoryPaths,
    required Map<String, String> informationEntries,
    required Map<String, int> credentialRevisions,
    this.state = RecycleState.available,
    this.version = 1,
  }) : directories = List.unmodifiable(directories),
       records = List.unmodifiable(records),
       directoryPaths = Map.unmodifiable({
         for (final e in directoryPaths.entries)
           e.key: List<String>.unmodifiable(e.value),
       }),
       informationEntries = Map.unmodifiable(informationEntries),
       credentialRevisions = Map.unmodifiable(credentialRevisions);
  final String id;
  final DateTime deletedAt, expiresAt;
  final List<InformationDirectory> directories;
  final List<LibraryRecycleRecord> records;
  final Map<String, List<String>> directoryPaths;
  final Map<String, String> informationEntries;
  final Map<String, int> credentialRevisions;
  final RecycleState state;
  final int version;
  LibraryRecycleBatch finish(RecycleState next) => LibraryRecycleBatch(
    id: id,
    deletedAt: deletedAt,
    expiresAt: expiresAt,
    directories: directories,
    records: records,
    directoryPaths: directoryPaths,
    informationEntries: informationEntries,
    credentialRevisions: credentialRevisions,
    state: next,
    version: version + 1,
  );
  Map<String, Object?> toJson() => {
    'format': 1,
    'id': id,
    'deletedAt': deletedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'state': state.name,
    'version': version,
    'directories': [
      for (final d in directories) [d.id, d.name, d.parentId, d.version],
    ],
    'directoryPaths': directoryPaths,
    'records': records.map((r) => r.toJson()).toList(),
    'informationEntries': informationEntries,
    'credentialRevisions': credentialRevisions,
  };
  factory LibraryRecycleBatch.fromJson(Map<String, dynamic> json) {
    try {
      if (json['format'] != 1 || json.length != 11) {
        throw const FormatException();
      }
      final batch = LibraryRecycleBatch(
        id: json['id'] as String,
        deletedAt: DateTime.parse(json['deletedAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        state: RecycleState.values.byName(json['state'] as String),
        version: json['version'] as int,
        directories: [
          for (final raw in json['directories'] as List)
            (() {
              final d = raw as List;
              if (d.length != 4) throw const FormatException();
              return InformationDirectory(
                d[0] as String,
                d[1] as String,
                d[2] as String?,
                d[3] as int,
              );
            })(),
        ],
        records: [
          for (final raw in json['records'] as List)
            LibraryRecycleRecord.fromJson(
              Map<String, dynamic>.from(raw as Map),
            ),
        ],
        directoryPaths: {
          for (final e in (json['directoryPaths'] as Map).entries)
            e.key as String: (e.value as List).cast<String>(),
        },
        informationEntries: Map<String, String>.from(
          json['informationEntries'] as Map,
        ),
        credentialRevisions: Map<String, int>.from(
          json['credentialRevisions'] as Map,
        ),
      );
      bool id(String v) => v.isNotEmpty && v.length <= 200;
      final dirs = {for (final d in batch.directories) d.id: d};
      final info = batch.records
          .where((r) => r.kind == 'information')
          .map((r) => r.id)
          .toSet();
      final creds = batch.records
          .where((r) => r.kind == 'credential')
          .map((r) => r.id)
          .toSet();
      if (!id(batch.id) ||
          batch.version < 1 ||
          !batch.expiresAt.isAfter(batch.deletedAt) ||
          dirs.length != batch.directories.length ||
          batch.records.map((r) => '${r.kind}:${r.id}').toSet().length !=
              batch.records.length ||
          info.length != batch.informationEntries.length ||
          creds.length != batch.credentialRevisions.length ||
          !info.every(batch.informationEntries.containsKey) ||
          !creds.every(batch.credentialRevisions.containsKey) ||
          batch.informationEntries.values.any((v) => !id(v)) ||
          batch.informationEntries.values.toSet().length != info.length ||
          batch.credentialRevisions.values.any((v) => v < 1) ||
          batch.directoryPaths.length != dirs.length ||
          !dirs.keys.every(batch.directoryPaths.containsKey)) {
        throw const FormatException();
      }
      for (final d in dirs.values) {
        if (!id(d.id) ||
            d.name.trim().isEmpty ||
            d.name.length > 200 ||
            d.version < 1 ||
            d.parentId != null && !id(d.parentId!)) {
          throw const FormatException();
        }
        final seen = <String>{};
        InformationDirectory? c = d;
        while (c != null) {
          if (!seen.add(c.id)) throw const FormatException();
          c = dirs[c.parentId];
        }
        if (batch.directoryPaths[d.id]!.isEmpty ||
            batch.directoryPaths[d.id]!.any(
              (p) => p.isEmpty || p.length > 200,
            ) ||
            batch.directoryPaths[d.id]!.last != d.name ||
            dirs.containsKey(d.parentId) &&
                jsonEncode(
                      batch.directoryPaths[d.id]!
                          .take(batch.directoryPaths[d.id]!.length - 1)
                          .toList(),
                    ) !=
                    jsonEncode(batch.directoryPaths[d.parentId])) {
          throw const FormatException();
        }
      }
      return batch;
    } on Object {
      throw const FormatException('Invalid directory recycle batch');
    }
  }
}

class LibraryRecycleReceipt {
  const LibraryRecycleReceipt({
    required this.operationId,
    required this.inputHash,
    required this.batchId,
    required this.action,
    required this.batchVersion,
  });
  final String operationId, inputHash, batchId;
  final LibraryRecycleAction action;
  final int batchVersion;
  Map<String, Object?> toJson() => {
    'kind': 'library-recycle-v1',
    'operationId': operationId,
    'inputHash': inputHash,
    'batchId': batchId,
    'action': action.name,
    'batchVersion': batchVersion,
  };
  factory LibraryRecycleReceipt.fromJson(Map<String, dynamic> json) {
    if (json.length != 6 || json['kind'] != 'library-recycle-v1') {
      throw const FormatException('Invalid library recycle receipt');
    }
    final r = LibraryRecycleReceipt(
      operationId: json['operationId'] as String,
      inputHash: json['inputHash'] as String,
      batchId: json['batchId'] as String,
      action: LibraryRecycleAction.values.byName(json['action'] as String),
      batchVersion: json['batchVersion'] as int,
    );
    _validateRecordOperationId(r.operationId);
    if (r.batchId.isEmpty ||
        r.batchId.length > 200 ||
        r.batchVersion < 1 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(r.inputHash)) {
      throw const FormatException('Invalid library recycle receipt');
    }
    return r;
  }
}

class LibraryRecycleRestoreOptions {
  LibraryRecycleRestoreOptions({
    Map<String, String> directoryNames = const {},
    Map<String, String?> parentOverrides = const {},
  }) : directoryNames = Map.unmodifiable(directoryNames),
       parentOverrides = Map.unmodifiable(parentOverrides);
  final Map<String, String> directoryNames;
  final Map<String, String?> parentOverrides;
  Map<String, Object?> toJson() => {
    'names': {
      for (final key in directoryNames.keys.toList()..sort())
        key: directoryNames[key],
    },
    'parents': {
      for (final key in parentOverrides.keys.toList()..sort())
        key: parentOverrides[key],
    },
  };
}

class LibraryRecycleRestorePreview {
  LibraryRecycleRestorePreview({
    required this.batchId,
    required this.stateToken,
    required this.options,
    required Iterable<InformationDirectory> directories,
    required Iterable<LibraryRecycleRecord> records,
    required Map<String, List<String>> directoryPaths,
    required Iterable<String> warnings,
    required Iterable<String> conflicts,
  }) : directories = List.unmodifiable(directories),
       records = List.unmodifiable(records),
       directoryPaths = Map.unmodifiable({
         for (final e in directoryPaths.entries)
           e.key: List<String>.unmodifiable(e.value),
       }),
       warnings = List.unmodifiable(warnings),
       conflicts = List.unmodifiable(conflicts);
  final String batchId, stateToken;
  final LibraryRecycleRestoreOptions options;
  final List<InformationDirectory> directories;
  final List<LibraryRecycleRecord> records;
  final Map<String, List<String>> directoryPaths;
  final List<String> warnings, conflicts;
  bool get canRestore => conflicts.isEmpty;
  late final String token = sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'batchId': batchId,
            'state': stateToken,
            'options': options.toJson(),
          }),
        ),
      )
      .toString();
}

/// All changed collections and the original operation result share one commit.
class LibraryRecycleChange {
  LibraryRecycleChange({
    required this.beforeToken,
    required this.batch,
    required this.receipt,
    required Iterable<InformationDirectory> directories,
    required Iterable<String> removedInformationIds,
    required Iterable<InformationItem> items,
    required Iterable<InformationRevision> previous,
    required Iterable<RecycleEntry> entries,
    required Iterable<RecycleFact> facts,
    required Iterable<ManagedCredential> credentials,
    required Iterable<CredentialMaterial> materials,
    required this.validate,
    this.order,
  }) : directories = List.unmodifiable(directories),
       removedInformationIds = List.unmodifiable(removedInformationIds),
       items = List.unmodifiable(items),
       previous = List.unmodifiable(previous),
       entries = List.unmodifiable(entries),
       facts = List.unmodifiable(facts),
       credentials = List.unmodifiable(credentials),
       materials = List.unmodifiable(materials);
  final String beforeToken;
  final LibraryRecycleBatch batch;
  final LibraryRecycleReceipt receipt;
  final List<InformationDirectory> directories;
  final List<String> removedInformationIds;
  final List<InformationItem> items;
  final List<InformationRevision> previous;
  final List<RecycleEntry> entries;
  final List<RecycleFact> facts;
  final List<ManagedCredential> credentials;
  final List<CredentialMaterial> materials;
  final void Function() validate;
  final LibraryOrderSnapshot? order;
}

abstract interface class LibraryRecycleRepository {
  List<LibraryRecycleBatch> get libraryRecycleBatches;
  Future<LibraryRecycleReceipt?> libraryRecycleReceipt(String operationId);
  Future<LibraryRecycleReceipt> commitLibraryRecycle(
    LibraryRecycleChange change,
  );
}

/// Comparable with authoritative SQL rows inside a storage transaction. Values
/// are never exposed; credential bytes only participate through the vault hash.
String libraryRecycleStateToken({
  required Iterable<InformationDirectory> directories,
  required Iterable<InformationTag> tags,
  required Iterable<List<Object?>> informationVersions,
  required List<ManagedCredential> credentials,
  required List<CredentialMaterial> materials,
  required Iterable<RecycleEntry> entries,
  required Iterable<RecycleFact> facts,
  required Iterable<LibraryRecycleBatch> batches,
  String? orderDigest,
}) {
  List<List<Object?>> sorted(Iterable<List<Object?>> rows) =>
      rows.toList()..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            sorted(
              directories.map((d) => [d.id, d.name, d.parentId, d.version]),
            ),
            sorted(tags.map((t) => [t.id, t.name, t.version])),
            sorted(informationVersions),
            credentialVaultDigest(credentials, materials),
            sorted(
              entries.map(
                (e) => [
                  e.id,
                  e.itemId,
                  e.version,
                  e.state.name,
                  e.expiresAt.toUtc().toIso8601String(),
                ],
              ),
            ),
            sorted(
              facts.map((f) => [f.entryId, f.itemId, f.version, f.kind.name]),
            ),
            sorted(batches.map((b) => [b.id, b.version, b.state.name])),
            ?orderDigest,
          ]),
        ),
      )
      .toString();
}
