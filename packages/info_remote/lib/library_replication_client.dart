import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/library_replication.dart';
import 'owner_client.dart';

final class RemoteInitialExport {
  RemoteInitialExport._(this.resourceId, this.transfer, this.transferKey);
  final String resourceId, transferKey;
  final LibraryInitialTransfer transfer;
}

/// Owner transport only; files are encrypted staging selected by the App.
/// Each upload is tied to one durable operation. A missing reply is queried
/// through that operation, never replaced with an unrelated submission.
final class LibraryReplicationClient {
  LibraryReplicationClient(this.client);
  final OwnerClient client;
  static const base = '/v1/owner/replication';
  static const chunkBytes = 512 * 1024;

  Future<({LibraryReplicaIdentity identity, bool empty})> status() async {
    final server = await client.request('GET', '/v1/server');
    final capabilities = server['replication'];
    if (capabilities is! Map ||
        capabilities['wireVersion'] != 1 ||
        capabilities['initialTransfer'] != true ||
        capabilities['chunkBytes'] != chunkBytes)
      throw const RemoteFailure('unsupported_sync');
    final result = await client.request('GET', base);
    if (result['wireVersion'] != 1 || result['empty'] is! bool)
      throw const RemoteFailure('invalid_response');
    return (
      identity: LibraryReplicaIdentity.fromJson(
        Map<String, dynamic>.from(result['identity'] as Map),
      ),
      empty: result['empty'] as bool,
    );
  }

  Future<RemoteInitialExport> prepareExport(String operationId) async {
    replicaOperationId(operationId);
    final result = await client.request('POST', '$base/exports', {
      'wireVersion': 1,
      'operationId': operationId,
    });
    if (result['wireVersion'] != 1 ||
        result['transferKey'] is! String ||
        !RegExp(
          r'^aim-recovery-v1:[A-Za-z0-9_-]{43}=$',
        ).hasMatch(result['transferKey'] as String))
      throw const RemoteFailure('invalid_response');
    return RemoteInitialExport._(
      libraryReplicaId(result['resourceId']),
      LibraryInitialTransfer.fromJson(
        Map<String, dynamic>.from(result['transfer'] as Map),
      ),
      result['transferKey'] as String,
    );
  }

  Future<void> download(
    RemoteInitialExport source,
    File target, {
    void Function(int completed, int total)? progress,
  }) async {
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound)
      throw const RemoteFailure('invalid_sync_file');
    var offset = type == FileSystemEntityType.file ? await target.length() : 0;
    if (offset > source.transfer.byteLength)
      throw const RemoteFailure('sync_integrity_failed');
    final output = await target.open(mode: FileMode.append);
    try {
      while (offset < source.transfer.byteLength) {
        final length = min(chunkBytes, source.transfer.byteLength - offset);
        final result = await client.request(
          'POST',
          '$base/transfers/${source.resourceId}/read',
          {'wireVersion': 1, 'offset': offset, 'length': length},
        );
        if (result['wireVersion'] != 1 ||
            result['offset'] != offset ||
            result['bytesBase64'] is! String)
          throw const RemoteFailure('invalid_response');
        final bytes = base64Decode(result['bytesBase64'] as String);
        if (bytes.length != length)
          throw const RemoteFailure('sync_integrity_failed');
        await output.writeFrom(bytes);
        await output.flush();
        offset += length;
        progress?.call(offset, source.transfer.byteLength);
      }
    } finally {
      await output.close();
    }
    await _verifyFile(target, source.transfer);
  }

  Future<void> _verifyFile(File file, LibraryInitialTransfer transfer) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != transfer.byteLength ||
        (await sha256.bind(file.openRead()).single).toString() !=
            transfer.archiveDigest)
      throw const RemoteFailure('sync_integrity_failed');
  }

  Future<LibraryInitialReceipt?> receipt(String operationId) async {
    replicaOperationId(operationId);
    final result = await client.request('GET', '$base/operations/$operationId');
    if (result['wireVersion'] != 1)
      throw const RemoteFailure('invalid_response');
    final raw = result['receipt'];
    if (raw == null) return null;
    final receipt = LibraryInitialReceipt.fromJson(
      Map<String, dynamic>.from(raw as Map),
    );
    if (receipt.operationId != operationId)
      throw const RemoteFailure('invalid_response');
    return receipt;
  }

  LibraryInitialReceipt _confirmed(
    LibraryInitialReceipt receipt,
    String operationId,
    LibraryInitialTransfer transfer,
  ) {
    if (receipt.operationId != operationId ||
        receipt.identity.libraryId != transfer.libraryId ||
        jsonEncode(receipt.transfer.toJson()) != jsonEncode(transfer.toJson()))
      throw const RemoteFailure('sync_operation_conflict');
    return receipt;
  }

  Future<LibraryInitialReceipt> upload({
    required File file,
    required LibraryInitialTransfer transfer,
    required String transferKey,
    required String operationId,
    void Function(int completed, int total)? progress,
  }) async {
    replicaOperationId(operationId);
    final known = await receipt(operationId);
    if (known != null) return _confirmed(known, operationId, transfer);
    await _verifyFile(file, transfer);
    final prepared = await client.request('POST', '$base/imports', {
      'wireVersion': 1,
      'operationId': operationId,
      'transfer': transfer.toJson(),
    });
    if (prepared['wireVersion'] != 1)
      throw const RemoteFailure('invalid_response');
    if (prepared['receipt'] != null)
      return _confirmed(
        LibraryInitialReceipt.fromJson(
          Map<String, dynamic>.from(prepared['receipt'] as Map),
        ),
        operationId,
        transfer,
      );
    final resource = libraryReplicaId(prepared['resourceId']);
    final uploaded = prepared['offset'];
    if (uploaded is! int || uploaded < 0 || uploaded > transfer.byteLength)
      throw const RemoteFailure('invalid_response');
    var offset = uploaded;
    final input = await file.open();
    try {
      await input.setPosition(offset);
      while (offset < transfer.byteLength) {
        final bytes = await input.read(
          min(chunkBytes, transfer.byteLength - offset),
        );
        if (bytes.isEmpty) throw const RemoteFailure('sync_integrity_failed');
        final result = await client.request(
          'POST',
          '$base/transfers/$resource/write',
          {
            'wireVersion': 1,
            'offset': offset,
            'bytesBase64': base64Encode(bytes),
          },
        );
        if (result['wireVersion'] != 1 ||
            result['offset'] != offset + bytes.length)
          throw const RemoteFailure('invalid_response');
        offset += bytes.length;
        progress?.call(offset, transfer.byteLength);
      }
    } finally {
      await input.close();
    }
    final result = await client.request(
      'POST',
      '$base/transfers/$resource/commit',
      {'wireVersion': 1, 'transferKey': transferKey},
    );
    if (result['wireVersion'] != 1 || result['receipt'] == null)
      throw const RemoteFailure('invalid_response');
    return _confirmed(
      LibraryInitialReceipt.fromJson(
        Map<String, dynamic>.from(result['receipt'] as Map),
      ),
      operationId,
      transfer,
    );
  }

  Future<void> release(RemoteInitialExport source) async {
    try {
      await client.request('DELETE', '$base/transfers/${source.resourceId}');
    } on RemoteFailure catch (e) {
      if (e.code != 'sync_transfer_expired') rethrow;
    }
  }
}
