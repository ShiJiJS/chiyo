part of 'info_core.dart';

/// Owner-only acknowledgement. It contains no password material and is kept
/// in private encrypted server state, outside Agent status and portable history.
final class OwnerPasswordFillReceipt {
  OwnerPasswordFillReceipt(
    this.operationId,
    this.proposalId,
    this.baseVersion,
    this.resultingVersion,
    this.inputDigest,
    Iterable<String> keys,
  ) : keys = List.unmodifiable(keys) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(operationId) ||
        proposalId.isEmpty ||
        proposalId.length > 200 ||
        baseVersion < 1 ||
        resultingVersion != baseVersion + 1 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(inputDigest) ||
        this.keys.isEmpty ||
        this.keys.length > 20 ||
        this.keys.toSet().length != this.keys.length ||
        this.keys.any(
          (k) => !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(k),
        )) {
      throw const AccessFailure('invalid_password_operation');
    }
  }
  final String operationId, proposalId, inputDigest;
  final int baseVersion, resultingVersion;
  final List<String> keys;
  static String digest(
    String operationId,
    String proposalId,
    int version,
    Map<String, String> values,
  ) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            operationId,
            proposalId,
            version,
            {
              for (final key in (values.keys.toList()..sort()))
                key: values[key],
            },
          ]),
        ),
      )
      .toString();
  Map<String, Object?> toPrivateJson() => {
    'operationId': operationId,
    'proposalId': proposalId,
    'baseVersion': baseVersion,
    'resultingVersion': resultingVersion,
    'inputDigest': inputDigest,
    'keys': keys,
  };
  factory OwnerPasswordFillReceipt.fromPrivateJson(Map<String, dynamic> j) {
    if (j.length != 6 ||
        j.keys.any(
          (k) => !const {
            'operationId',
            'proposalId',
            'baseVersion',
            'resultingVersion',
            'inputDigest',
            'keys',
          }.contains(k),
        )) {
      throw const AccessFailure('invalid_password_operation');
    }
    return OwnerPasswordFillReceipt(
      j['operationId'] as String,
      j['proposalId'] as String,
      j['baseVersion'] as int,
      j['resultingVersion'] as int,
      j['inputDigest'] as String,
      (j['keys'] as List).cast<String>(),
    );
  }
}

extension OwnerProposalPasswordOperations on OwnerAccess {
  Map<String, dynamic> _passwordOperations(ServerStateSnapshot state) {
    final raw = state.payload['ownerPasswordFills'];
    if (raw == null && !state.payload.containsKey('ownerPasswordFills')) {
      return {};
    }
    if (raw is! Map || raw.length > 10000) {
      throw const AccessFailure('invalid_server_state');
    }
    final operations = Map<String, dynamic>.from(raw);
    try {
      for (final entry in operations.entries) {
        final receipt = OwnerPasswordFillReceipt.fromPrivateJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (receipt.operationId != entry.key) {
          throw const AccessFailure('invalid_server_state');
        }
      }
    } on Object {
      throw const AccessFailure('invalid_server_state');
    }
    return operations;
  }

  ServerProposalPasswordRepository get _passwordRepository {
    if (!serviceAvailable ||
        _service._repository is! ServerProposalPasswordRepository) {
      throw const AccessFailure('unsupported_capability');
    }
    return _service._repository as ServerProposalPasswordRepository;
  }

  Future<OwnerPasswordFillReceipt?> importPasswordFillReceipt(
    String operationId,
  ) => _serialize(() async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(operationId)) {
      throw const AccessFailure('invalid_password_operation');
    }
    final row = _passwordOperations(
      await _passwordRepository.openServerState(),
    )[operationId];
    if (row == null) return null;
    final receipt = OwnerPasswordFillReceipt.fromPrivateJson(
      Map<String, dynamic>.from(row as Map),
    );
    if (receipt.operationId != operationId) {
      throw const AccessFailure('invalid_server_state');
    }
    return receipt;
  });
  Future<OwnerPasswordFillReceipt> fillImportCredentialsOperation(
    String id,
    int version,
    Map<String, String> values,
    String operationId,
  ) {
    // Freeze before the queue: an async caller cannot substitute its input.
    final frozen = Map<String, String>.unmodifiable(values);
    final receipt = OwnerPasswordFillReceipt(
      operationId,
      id,
      version,
      version + 1,
      OwnerPasswordFillReceipt.digest(operationId, id, version, frozen),
      frozen.keys.toList()..sort(),
    );
    return _serialize(() async {
      final repo = _passwordRepository;
      final snapshot = await repo.openServerState();
      final operations = _passwordOperations(snapshot);
      final prior = operations[operationId];
      if (prior != null) {
        if (jsonEncode(
              OwnerPasswordFillReceipt.fromPrivateJson(
                Map<String, dynamic>.from(prior as Map),
              ).toPrivateJson(),
            ) !=
            jsonEncode(receipt.toPrivateJson())) {
          throw const AccessFailure('operation_conflict');
        }
        return receipt;
      }
      if (operations.length >= 10000) {
        throw const AccessFailure('operation_capacity');
      }
      final revised = _filledImportCredentials(id, version, frozen)!;
      await repo.commitServerProposalPasswords(
        snapshot,
        {
          ...snapshot.payload,
          'ownerPasswordFills': {
            ...operations,
            operationId: receipt.toPrivateJson(),
          },
        },
        revised,
        version,
      );
      return receipt;
    });
  }

  Future<String> readImportPasswordForOwner(
    String id,
    int version,
    String key,
  ) => _serialize(() async {
    final proposal = _pendingImport(id, version);
    final credential = proposal.items
        .where((i) => i.key == key)
        .firstOrNull
        ?.credential;
    if (credential == null || credential.source != 'owner') {
      throw const AccessFailure('invalid_credential_input');
    }
    return credential.material == null ? '' : utf8.decode(credential.material!);
  });
}
