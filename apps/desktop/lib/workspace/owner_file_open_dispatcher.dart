import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

class NativeOwnerFileOpenDispatcher implements OwnerFileOpenDispatcher {
  const NativeOwnerFileOpenDispatcher();
  static const _channel = MethodChannel('agent_info_manage/owner_file_open');
  OwnerFileDispatchOutcome _outcome(String? value) => switch (value) {
    'pending' => OwnerFileDispatchOutcome.pending,
    'opened' => OwnerFileDispatchOutcome.opened,
    'notOpened' => OwnerFileDispatchOutcome.notOpened,
    _ => throw const StorageFailure('file_outcome_unknown'),
  };
  @override
  Future<OwnerFileDispatchOutcome> open(
    String id,
    String digest,
    InformationDeliveryLease lease,
    int length,
    String sha256,
  ) async => _outcome(
    await _channel.invokeMethod<String>('open', {
      'operationId': id,
      'commandDigest': digest,
      ...lease.toPrivateJson(),
      'byteLength': length,
      'sha256': sha256,
    }),
  );
  @override
  Future<OwnerFileDispatchOutcome?> status(String id, String digest) async {
    final result = await _channel.invokeMethod<String>('status', {
      'operationId': id,
      'commandDigest': digest,
    });
    return result == null ? null : _outcome(result);
  }
}
