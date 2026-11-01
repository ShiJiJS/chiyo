part of 'info_storage.dart';

extension _AdditionalApprovalStorage on EncryptedInformationRepository {
  Future<InformationApprovalReceipt?> _additionalApprovalReceipt(
    String id,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT payload,invalidated FROM additional_approval_operations WHERE operation_id=?',
          variables: [Variable(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    if (rows.single.read<int>('invalidated') != 0) {
      throw const AccessFailure('library_changed');
    }
    final result = InformationApprovalReceipt.fromJson(
      jsonDecode(rows.single.read<String>('payload')) as Map<String, dynamic>,
    );
    if (result.operationId != id) {
      throw const StorageFailure('invalid_operation_receipt');
    }
    return result;
  }

  Future<int> _additionalApprovalRevision(String requestId) async {
    if (_closed) throw const StorageFailure('library_closed');
    final rows = await _db
        .customSelect(
          'SELECT COUNT(*) AS count FROM additional_approval_operations WHERE request_id=?',
          variables: [Variable(requestId)],
        )
        .get();
    return rows.single.read<int>('count');
  }

  Future<void> _additionalApprovalCommit(String id, String kind) async {
    final operation = pendingAdditionalApproval;
    if (operation == null || operation.written) return;
    if (operation.kind != kind || operation.command.requestId != id) {
      throw const AccessFailure('request_changed');
    }
    final rows = await _db
        .customSelect(
          'SELECT COUNT(*) AS count FROM additional_approval_operations WHERE request_id=?',
          variables: [Variable(id)],
        )
        .get();
    final receipt = operation.complete(
      id,
      kind,
      rows.single.read<int>('count') + 1,
    );
    await _db.customStatement(
      'INSERT INTO additional_approval_operations(operation_id,request_id,payload) VALUES(?,?,?)',
      [receipt.operationId, id, jsonEncode(receipt.toJson())],
    );
  }
}
