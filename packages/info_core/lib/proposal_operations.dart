part of 'info_core.dart';

class OwnerProposalCommand {
  OwnerProposalCommand({
    required this.operationId,
    required this.proposalId,
    required this.kind,
    required this.confirm,
    required this.version,
    required this.reviewToken,
    required this.commandDigest,
  }) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(operationId) ||
        proposalId.isEmpty ||
        proposalId.length > 200 ||
        version < 1 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(reviewToken) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(commandDigest)) {
      throw const AccessFailure('invalid_proposal_operation');
    }
  }
  final String operationId, proposalId, reviewToken, commandDigest;
  final ProposalKind kind;
  final bool confirm;
  final int version;
  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'proposalId': proposalId,
    'kind': kind.name,
    'confirm': confirm,
    'version': version,
    'reviewToken': reviewToken,
    'commandDigest': commandDigest,
  };
  factory OwnerProposalCommand.fromJson(Map<String, dynamic> j) =>
      OwnerProposalCommand(
        operationId: j['operationId'] as String,
        proposalId: j['proposalId'] as String,
        kind: ProposalKind.values.byName(j['kind'] as String),
        confirm: j['confirm'] as bool,
        version: j['version'] as int,
        reviewToken: j['reviewToken'] as String,
        commandDigest: j['commandDigest'] as String,
      );
}

class OwnerProposalTarget {
  const OwnerProposalTarget(this.id, this.version, {this.recycleId});
  final String id;
  final int version;
  final String? recycleId;
  Map<String, Object?> toJson() => {
    'id': id,
    'version': version,
    if (recycleId != null) 'recycleId': recycleId,
  };
}

class OwnerProposalReceipt {
  OwnerProposalReceipt(
    this.command,
    this.resultingVersion,
    Iterable<OwnerProposalTarget> records,
  ) : records = List.unmodifiable(records);
  final OwnerProposalCommand command;
  final int resultingVersion;
  final List<OwnerProposalTarget> records;
  Map<String, Object?> toJson() => {
    'command': command.toJson(),
    'resultingVersion': resultingVersion,
    'records': records.map((r) => r.toJson()).toList(),
  };
  factory OwnerProposalReceipt.fromJson(Map<String, dynamic> j) =>
      OwnerProposalReceipt(
        OwnerProposalCommand.fromJson(
          Map<String, dynamic>.from(j['command'] as Map),
        ),
        j['resultingVersion'] as int,
        (j['records'] as List).map(
          (r) => OwnerProposalTarget(
            r['id'] as String,
            r['version'] as int,
            recycleId: r['recycleId'] as String?,
          ),
        ),
      );
}

abstract interface class OwnerProposalOperationRepository {
  Future<OwnerProposalReceipt?> ownerProposalReceipt(String operationId);
}

final _ownerProposalOperationKey = Object();

/// Trusted Owner call context. Only a metadata receipt crosses into storage;
/// submitted/current values stay in existing proposal and information writes.
class OwnerProposalOperation {
  OwnerProposalOperation._(this.owner, this.command, this._validation)
    : _scope = owner.captureLibraryScope();
  final OwnerAccess owner;
  final OwnerProposalCommand command;
  final void Function() _validation;
  final OwnerLibraryScope _scope;
  void validate() {
    if (!_scope.isCurrent) throw const AccessFailure('library_changed');
    if (!owner.serviceAvailable) {
      throw const AccessFailure('service_unavailable');
    }
    _validation();
  }

  bool _entered = false;
  bool _active = true;
  Future<void> _before(OwnerAccess caller) async {
    if (!identical(owner, caller)) {
      throw const AccessFailure('invalid_proposal_operation');
    }
    // Background maintenance may inherit this async zone, but is not a second
    // owner decision and must not re-run its guard or claim its receipt.
    if (!_active || _entered) return;
    _entered = true;
    final prior = await owner._proposalOperations.ownerProposalReceipt(
      command.operationId,
    );
    if (prior != null) {
      if (jsonEncode(prior.command.toJson()) != jsonEncode(command.toJson())) {
        throw const AccessFailure('operation_conflict');
      }
      throw _CommittedOwnerProposal(prior);
    }
    validate();
  }

  OwnerProposalReceipt complete(
    String id,
    ProposalKind kind,
    bool confirm,
    int version,
    Iterable<OwnerProposalTarget> records,
  ) {
    if (!_entered ||
        id != command.proposalId ||
        kind != command.kind ||
        confirm != command.confirm ||
        version != command.version + 1) {
      throw const AccessFailure('proposal_changed');
    }
    validate();
    return OwnerProposalReceipt(command, version, records);
  }
}

OwnerProposalOperation? get pendingOwnerProposalOperation {
  final operation =
      Zone.current[_ownerProposalOperationKey] as OwnerProposalOperation?;
  return operation?._active == true ? operation : null;
}

class _CommittedOwnerProposal implements Exception {
  _CommittedOwnerProposal(this.receipt);
  final OwnerProposalReceipt receipt;
}

extension OwnerProposalOperations on OwnerAccess {
  OwnerProposalOperationRepository get _proposalOperations =>
      _service._repository is OwnerProposalOperationRepository
      ? _service._repository as OwnerProposalOperationRepository
      : throw const AccessFailure('unsupported_capability');
  Future<OwnerProposalReceipt?> ownerProposalReceipt(String id) =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        return _proposalOperations.ownerProposalReceipt(id);
      });

  /// Wrap exactly one existing decision. Its queue guard and receipt are
  /// installed at the original core write/transaction, not before or after it.
  Future<OwnerProposalReceipt> performProposalDecision(
    OwnerProposalCommand command, {
    required void Function() validate,
    required Future<void> Function() decide,
  }) async {
    if (!serviceAvailable || pendingOwnerProposalOperation != null) {
      throw const AccessFailure('service_unavailable');
    }
    final prior = await ownerProposalReceipt(command.operationId);
    if (prior != null) {
      if (jsonEncode(prior.command.toJson()) != jsonEncode(command.toJson())) {
        throw const AccessFailure('operation_conflict');
      }
      return prior;
    }
    final context = OwnerProposalOperation._(this, command, validate);
    try {
      await runZoned(decide, zoneValues: {_ownerProposalOperationKey: context});
    } on _CommittedOwnerProposal catch (e) {
      return e.receipt;
    } finally {
      context._active = false;
    }
    final receipt = await ownerProposalReceipt(command.operationId);
    if (receipt == null) throw const AccessFailure('unknown_outcome');
    return receipt;
  }
}
