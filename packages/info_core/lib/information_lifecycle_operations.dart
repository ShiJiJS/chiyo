part of 'info_core.dart';

enum InformationLifecycleAction {
  recycle,
  restoreRevision,
  restoreRecycled,
  purge,
}

/// The exact owner intent. Contains identities and versions, never body values.
final class InformationLifecycleCommand {
  InformationLifecycleCommand({
    required this.operationId,
    required this.itemId,
    required this.action,
    required this.expectedVersion,
    this.revisionVersion,
    this.snapshotId,
    this.entryId,
    this.expectedCatalogVersion,
    this.expectedCurrentVersion,
  }) {
    _validateRecordOperationId(operationId);
    bool validId(String value) =>
        value.isNotEmpty &&
        value.length <= 200 &&
        !value.codeUnits.any((c) => c < 33 || c > 126);
    if (snapshotId != null &&
        (action != InformationLifecycleAction.restoreRevision ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(snapshotId!)))
      throw const AccessFailure('invalid_information');
    if (!validId(itemId) ||
        expectedVersion < 1 ||
        (revisionVersion != null && revisionVersion! < 1) ||
        (expectedCatalogVersion != null && expectedCatalogVersion! < 1) ||
        (expectedCurrentVersion != null && expectedCurrentVersion! < 1) ||
        (entryId != null && !validId(entryId!))) {
      throw const AccessFailure('invalid_information');
    }
    final valid = switch (action) {
      InformationLifecycleAction.recycle =>
        revisionVersion == null &&
            entryId == null &&
            expectedCurrentVersion == null,
      InformationLifecycleAction.restoreRevision =>
        revisionVersion != null &&
            entryId == null &&
            expectedCatalogVersion != null &&
            expectedCurrentVersion == null,
      InformationLifecycleAction.purge =>
        revisionVersion == null && entryId != null,
      InformationLifecycleAction.restoreRecycled =>
        revisionVersion == null &&
            entryId != null &&
            expectedCatalogVersion != null,
    };
    if (!valid) throw const AccessFailure('invalid_information');
  }
  final String operationId, itemId;
  final InformationLifecycleAction action;
  final int expectedVersion;
  final int? revisionVersion, expectedCatalogVersion, expectedCurrentVersion;
  final String? entryId;
  final String? snapshotId;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'itemId': itemId,
    'action': action.name,
    'expectedVersion': expectedVersion,
    'revisionVersion': revisionVersion,
    if (snapshotId != null) 'snapshotId': snapshotId,
    'entryId': entryId,
    'expectedCatalogVersion': expectedCatalogVersion,
    'expectedCurrentVersion': expectedCurrentVersion,
  };
  String get digest =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
  factory InformationLifecycleCommand.fromJson(Map<String, dynamic> json) {
    if (json.length != (json.containsKey('snapshotId') ? 9 : 8) ||
        (json.containsKey('snapshotId') && json['snapshotId'] is! String) ||
        json['operationId'] is! String ||
        json['itemId'] is! String ||
        json['action'] is! String ||
        json['expectedVersion'] is! int ||
        !json.containsKey('revisionVersion') ||
        !json.containsKey('entryId') ||
        !json.containsKey('expectedCatalogVersion') ||
        !json.containsKey('expectedCurrentVersion') ||
        (json['revisionVersion'] != null && json['revisionVersion'] is! int) ||
        (json['entryId'] != null && json['entryId'] is! String) ||
        (json['expectedCatalogVersion'] != null &&
            json['expectedCatalogVersion'] is! int) ||
        (json['expectedCurrentVersion'] != null &&
            json['expectedCurrentVersion'] is! int)) {
      throw const FormatException('Invalid lifecycle command');
    }
    try {
      return InformationLifecycleCommand(
        operationId: json['operationId'] as String,
        itemId: json['itemId'] as String,
        action: InformationLifecycleAction.values.byName(
          json['action'] as String,
        ),
        expectedVersion: json['expectedVersion'] as int,
        revisionVersion: json['revisionVersion'] as int?,
        snapshotId: json['snapshotId'] as String?,
        entryId: json['entryId'] as String?,
        expectedCatalogVersion: json['expectedCatalogVersion'] as int?,
        expectedCurrentVersion: json['expectedCurrentVersion'] as int?,
      );
    } on AccessFailure {
      throw const FormatException('Invalid lifecycle command');
    } on ArgumentError {
      throw const FormatException('Invalid lifecycle command');
    }
  }
}

final class InformationLifecycleReceipt {
  InformationLifecycleReceipt({
    required this.command,
    required this.version,
    this.entryId,
  }) {
    if ((command.action != InformationLifecycleAction.restoreRecycled &&
            command.action != InformationLifecycleAction.purge &&
            version != command.expectedVersion + 1) ||
        version <= command.expectedVersion ||
        (command.expectedCurrentVersion != null &&
            version <= command.expectedCurrentVersion!) ||
        (entryId != null &&
            (entryId!.isEmpty ||
                entryId!.length > 200 ||
                entryId!.codeUnits.any((c) => c < 33 || c > 126))) ||
        (command.action == InformationLifecycleAction.recycle &&
            entryId == null) ||
        ((command.action == InformationLifecycleAction.restoreRecycled ||
                command.action == InformationLifecycleAction.purge) &&
            entryId != command.entryId)) {
      throw const FormatException('Invalid lifecycle receipt');
    }
  }
  final InformationLifecycleCommand command;
  final int version;
  final String? entryId;
  Map<String, Object?> toJson() => {
    'command': command.toJson(),
    'version': version,
    'entryId': entryId,
  };
  factory InformationLifecycleReceipt.fromJson(Map<String, dynamic> json) {
    if (json.length != 3 ||
        json['command'] is! Map<String, dynamic> ||
        json['version'] is! int ||
        !json.containsKey('entryId') ||
        (json['entryId'] != null && json['entryId'] is! String)) {
      throw const FormatException('Invalid lifecycle receipt');
    }
    return InformationLifecycleReceipt(
      command: InformationLifecycleCommand.fromJson(
        json['command'] as Map<String, dynamic>,
      ),
      version: json['version'] as int,
      entryId: json['entryId'] as String?,
    );
  }
}

abstract interface class InformationLifecycleRepository {
  Future<InformationLifecycleReceipt?> informationLifecycleReceipt(
    String operationId,
  );
}

extension OwnerInformationLifecycle on OwnerAccess {
  /// Historical identity references remain in the archive. Restoring current
  /// content only keeps targets that still exist, never a same-name substitute.
  InformationLayout? _existingLayoutRelations(
    InformationLayout? layout, {
    Set<String> additionalItems = const {},
    Set<String> additionalCredentials = const {},
  }) {
    if (layout == null) return null;
    final items = {...information.map((i) => i.id), ...additionalItems};
    final vault = _service._repository;
    final credentialIds = vault is CredentialRepository
        ? (vault as CredentialRepository).managedCredentials
              .where((c) => c.deletedAt == null)
              .map((c) => c.id)
              .toSet()
        : <String>{};
    credentialIds.addAll(additionalCredentials);
    return InformationLayout(
      typeId: layout.typeId,
      snapshot: layout.snapshot,
      fieldIds: layout.fieldIds,
      relations: {
        for (final entry in layout.relations.entries)
          entry.key: [
            for (final ref in entry.value)
              if (ref.kind == 'information'
                  ? items.contains(ref.id)
                  : credentialIds.contains(ref.id))
                ref,
          ],
      },
    );
  }

  InformationLifecycleRepository get _lifecycleOperations {
    if (_service._repository
        case final InformationLifecycleRepository repository) {
      return repository;
    }
    throw const AccessFailure('unsupported_capability');
  }

  Future<InformationLifecycleReceipt?> informationLifecycleReceipt(
    String operationId,
  ) => _serialize(() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    _validateRecordOperationId(operationId);
    return _lifecycleOperations.informationLifecycleReceipt(operationId);
  });

  Future<InformationLifecycleReceipt> changeInformationLifecycle(
    InformationLifecycleCommand command,
  ) => _serialize(() async {
    final generation = _service._libraryGeneration;
    void validate() {
      if (!serviceAvailable) throw const AccessFailure('service_unavailable');
      if (generation != _service._libraryGeneration) {
        throw const AccessFailure('library_changed');
      }
    }

    validate();
    final old = await _lifecycleOperations.informationLifecycleReceipt(
      command.operationId,
    );
    validate();
    if (old != null) {
      if (old.command.digest != command.digest) {
        throw const AccessFailure('operation_conflict');
      }
      return old;
    }
    if (command.expectedCatalogVersion != null) {
      if (_service._repository is! InformationClassificationRepository) {
        throw const AccessFailure('unsupported_capability');
      }
      final version =
          await (_service._repository as InformationClassificationRepository)
              .informationClassificationVersion();
      validate();
      if (version != command.expectedCatalogVersion) {
        throw const AccessFailure('organization_conflict');
      }
    }
    switch (command.action) {
      case InformationLifecycleAction.recycle:
        final entry = await _deleteInformation(
          command.itemId,
          command.expectedVersion,
          command: command,
          validate: validate,
        );
        return InformationLifecycleReceipt(
          command: command,
          version: entry.version,
          entryId: entry.id,
        );
      case InformationLifecycleAction.restoreRevision:
        // The helper commits the receipt, including any resulting recycle entry.
        await _restoreRevision(
          command.itemId,
          command.revisionVersion!,
          command.expectedVersion,
          command: command,
          validate: validate,
        );
      case InformationLifecycleAction.purge:
        final entry = recycleEntries
            .where((e) => e.id == command.entryId)
            .firstOrNull;
        if (entry == null) throw const AccessFailure('recycle_unavailable');
        await _purgeInformationEntry(entry, command: command, expired: false);
      case InformationLifecycleAction.restoreRecycled:
        final entry = recycleEntries
            .where((e) => e.id == command.entryId)
            .firstOrNull;
        if (entry == null) throw const AccessFailure('recycle_unavailable');
        final current = information
            .where((i) => i.id == command.itemId)
            .firstOrNull;
        if (entry.itemId != command.itemId ||
            entry.version != command.expectedVersion ||
            current?.version != command.expectedCurrentVersion ||
            (entry.wholeItem && current != null) ||
            (!entry.wholeItem && current == null)) {
          throw const AccessFailure('recycle_conflict');
        }
        await _restoreRecycled(entry.id, command: command, validate: validate);
    }
    // A failure here is an unknown result; callers reconcile the same operation.
    final receipt = await _lifecycleOperations.informationLifecycleReceipt(
      command.operationId,
    );
    if (receipt == null) throw const AccessFailure('operation_result_unknown');
    return receipt;
  });
}
