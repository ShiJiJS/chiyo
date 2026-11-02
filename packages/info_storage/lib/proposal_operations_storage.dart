part of 'info_storage.dart';

extension _ProposalOperationStorage on EncryptedInformationRepository {
  Future<OwnerProposalReceipt?> _proposalReceipt(String id) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM owner_proposal_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0)
      throw const AccessFailure('library_changed');
    final r = OwnerProposalReceipt.fromJson(
      jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
    );
    if (r.command.operationId != id)
      throw const StorageFailure('invalid_operation_receipt');
    return r;
  }

  Future<void> _proposalCommit(
    String id,
    ProposalKind kind,
    bool confirm,
    int version,
    Iterable<OwnerProposalTarget> records, {
    Iterable<String> awaitingKeys = const [],
  }) async {
    final operation = pendingOwnerProposalOperation;
    if (operation == null) return;
    final receipt = operation.complete(
      id,
      kind,
      confirm,
      version,
      records,
      awaitingKeys: awaitingKeys,
    );
    await _db.customStatement(
      'INSERT INTO owner_proposal_operations(operation_id,payload) VALUES(?,?)',
      [receipt.command.operationId, jsonEncode(receipt.toJson())],
    );
    operation.validate();
  }
}
