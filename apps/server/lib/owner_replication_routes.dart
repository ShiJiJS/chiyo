import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'package:info_core/library_replication.dart';
import 'package:info_core/library_sync_changes.dart';
import 'package:info_core/protocol_json.dart';
import 'package:info_storage/info_storage.dart';
part 'owner_incremental_routes.dart';

class _TransferFile {
  _TransferFile(
    this.id,
    this.operationId,
    this.file,
    this.transfer,
    this.deadline, {
    this.key,
    String? cacheKey,
    this.delta,
    this.baseline,
  }) : cacheKey = cacheKey ?? operationId;
  final String id, operationId, cacheKey;
  final File file;
  final LibraryInitialTransfer transfer;
  final Duration deadline;
  final String? key;
  final LibraryDeltaTransfer? delta;
  final _BaselineTransfer? baseline;
}

/// Owner-only staging of encrypted content. Actual installation uses the same
/// snapshot barrier, portable validators and SQL transaction as local storage.
class OwnerReplicationRoutes {
  OwnerReplicationRoutes({
    required this.owner,
    required this.replication,
    required this.directory,
    Duration Function()? elapsed,
  }) : _scope = owner.captureLibraryScope(),
       _elapsed = elapsed ?? _clock();
  final OwnerAccess owner;
  final LibraryReplication replication;
  final Directory directory;
  late final LibraryIncremental _incremental = LibraryIncremental(replication);
  Future<void>? _incrementalReady;
  OwnerLibraryScope _scope;
  bool _swept = false;
  final Duration Function() _elapsed;
  static Duration Function() _clock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final _exports = <String, Future<_TransferFile>>{};
  final _files = <String, _TransferFile>{};
  final _imports = <String, _TransferFile>{};
  static const chunkBytes = 512 * 1024;
  static const lifetime = Duration(minutes: 30);
  static const maxTransfers = 2;
  static const capabilities = {
    'wireVersion': 1,
    'initialTransfer': true,
    'incrementalWireVersion': 2,
    'versionedInitial': true,
    'contentFormats': [
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      16,
      17,
      18,
      19,
      20,
      21,
      22,
      23,
      24,
      25,
      26,
      27,
      28,
      29,
    ],
    'chunkBytes': chunkBytes,
  };
  String _id() => base64Url
      .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  Map<String, dynamic> _input(
    Object? raw,
    Set<String> fields, {
    int version = 1,
  }) {
    if (raw is! Map ||
        raw['wireVersion'] != version ||
        raw.length != fields.length + 1 ||
        !fields.every(raw.containsKey))
      throw const FormatException('Invalid replication request');
    return Map<String, dynamic>.from(raw);
  }

  Future<File> _newFile() async => File(
    '${(await directory.createTemp('replica-')).path}/content.encrypted',
  );

  Future<_TransferFile> _export(String operation) async {
    final file = await _newFile();
    try {
      final prepared = await owner.exportLibrary(
        () => replication.exportInitial(file.path),
      );
      final transfer = _TransferFile(
        _id(),
        operation,
        file,
        prepared.transfer,
        _elapsed() + lifetime,
        key: prepared.transferKey,
      );
      _files[transfer.id] = transfer;
      return transfer;
    } on Object {
      await file.parent.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> dispose() async {
    await Future.wait(
      _exports.values.map((v) => v.then<void>((_) {}, onError: (Object _) {})),
    );
    for (final transfer in _files.values.toList()) {
      await transfer.file.parent.delete(recursive: true);
    }
    _files.clear();
    _exports.clear();
    _imports.clear();
  }

  bool get needsCleanup =>
      !_swept ||
      !_scope.isCurrent ||
      _files.values.any((v) => v.deadline <= _elapsed());

  Future<void> cleanup() async {
    if (!_scope.isCurrent) {
      await dispose();
      _incrementalReady = null;
      _scope = owner.captureLibraryScope();
    }
    for (final transfer in _files.values.toList()) {
      if (transfer.deadline > _elapsed()) continue;
      await _release(transfer);
    }
    if (!_swept) {
      final retained = _files.values.map((v) => v.file.parent.path).toSet();
      await for (final entity in directory.list(followLinks: false)) {
        if (entity.uri.pathSegments
                .where((s) => s.isNotEmpty)
                .last
                .startsWith('replica-') &&
            !retained.contains(entity.path) &&
            await FileSystemEntity.type(entity.path, followLinks: false) ==
                FileSystemEntityType.directory) {
          await entity.delete(recursive: true);
        }
      }
      _swept = true;
    }
  }

  Future<void> _release(_TransferFile transfer) async {
    await transfer.file.parent.delete(recursive: true);
    _files.remove(transfer.id);
    if (transfer.key == null) {
      _imports.remove(transfer.cacheKey);
    } else {
      _exports.remove(transfer.cacheKey);
    }
  }

  void _reserve() {
    if (_exports.length + _imports.length >= maxTransfers)
      throw const StorageFailure('sync_transfer_capacity');
  }

  Future<(int, Map<String, Object?>)> dispatch(
    String method,
    List<String> path,
    Object? raw,
  ) async {
    if (needsCleanup) await cleanup();
    final tail = path.skip(3).toList();
    if (tail.isNotEmpty &&
        {
          'changes',
          'versioned-exports',
          'versioned-imports',
          'delta-exports',
          'delta-imports',
        }.contains(tail[0])) {
      return _dispatchIncremental(method, tail, raw);
    }
    if (tail.isEmpty && method == 'GET')
      return (
        200,
        {
          'wireVersion': 1,
          'identity': (await replication.identity()).toJson(),
          'empty': await replication.empty(),
          'capabilities': capabilities,
        },
      );
    if (tail.length == 1 && tail[0] == 'exports' && method == 'POST') {
      final operation = replicaOperationId(
        _input(raw, {'operationId'})['operationId'],
      );
      if (!_exports.containsKey(operation)) _reserve();
      late _TransferFile transfer;
      try {
        transfer = await (_exports[operation] ??= _export(operation));
      } on Object {
        _exports.remove(operation);
        rethrow;
      }
      return (
        200,
        {
          'wireVersion': 1,
          'resourceId': transfer.id,
          'transfer': transfer.transfer.toJson(),
          'transferKey': transfer.key,
        },
      );
    }
    if (tail.length == 1 && tail[0] == 'imports' && method == 'POST') {
      final input = _input(raw, {'operationId', 'transfer'});
      final operation = replicaOperationId(input['operationId']);
      final manifest = LibraryInitialTransfer.fromJson(
        Map<String, dynamic>.from(input['transfer'] as Map),
      );
      final receipt = await replication.receipt(operation, manifest);
      if (receipt != null)
        return (200, {'wireVersion': 1, 'receipt': receipt.toJson()});
      final previous = _imports[operation];
      if (previous != null) {
        if (jsonEncode(previous.transfer.toJson()) !=
            jsonEncode(manifest.toJson()))
          throw const StorageFailure('sync_operation_conflict');
        return (
          200,
          {
            'wireVersion': 1,
            'resourceId': previous.id,
            'offset': await previous.file.length(),
          },
        );
      }
      if (!await replication.empty())
        throw const StorageFailure('recipient_not_empty');
      _reserve();
      final file = await _newFile();
      await file.create(exclusive: true);
      final incoming = _TransferFile(
        _id(),
        operation,
        file,
        manifest,
        _elapsed() + lifetime,
      );
      _files[incoming.id] = incoming;
      _imports[operation] = incoming;
      return (200, {'wireVersion': 1, 'resourceId': incoming.id, 'offset': 0});
    }
    if (tail.length == 2 && tail[0] == 'operations' && method == 'GET')
      return (
        200,
        {
          'wireVersion': 1,
          'receipt': (await replication.lookupReceipt(tail[1]))?.toJson(),
        },
      );
    if (tail.length < 2 || tail[0] != 'transfers')
      return (404, {'error': 'not_found'});
    final transfer = _files[tail[1]];
    if (transfer == null || transfer.deadline <= _elapsed())
      return (410, {'error': 'sync_transfer_expired'});
    if (tail.length == 2 && method == 'DELETE') {
      await _release(transfer);
      return (200, {'wireVersion': 1});
    }
    if (tail.length == 4 && tail[2] == 'baseline') {
      return _baselineChunk(method, tail[3], transfer, raw);
    }
    if (tail.length == 3 &&
        tail[2] == 'read' &&
        method == 'POST' &&
        transfer.key != null) {
      final input = _input(raw, {'offset', 'length'});
      final offset = input['offset'], length = input['length'];
      if (offset is! int ||
          length is! int ||
          offset < 0 ||
          length < 1 ||
          length > chunkBytes ||
          offset + length > transfer.transfer.byteLength)
        throw const FormatException();
      final handle = await transfer.file.open();
      try {
        await handle.setPosition(offset);
        final bytes = await handle.read(length);
        if (bytes.length != length)
          throw const StorageFailure('sync_integrity_failed');
        return (
          200,
          {
            'wireVersion': 1,
            'offset': offset,
            'bytesBase64': base64Encode(bytes),
          },
        );
      } finally {
        await handle.close();
      }
    }
    if (tail.length == 3 &&
        tail[2] == 'write' &&
        method == 'POST' &&
        transfer.key == null) {
      final input = _input(raw, {'offset', 'bytesBase64'});
      final offset = input['offset'];
      if (offset is! int ||
          offset < 0 ||
          input['bytesBase64'] is! String ||
          (input['bytesBase64'] as String).length > (chunkBytes * 4 ~/ 3 + 8))
        throw const FormatException();
      final bytes = base64Decode(input['bytesBase64'] as String);
      if (bytes.isEmpty ||
          bytes.length > chunkBytes ||
          offset + bytes.length > transfer.transfer.byteLength)
        throw const FormatException();
      final size = await transfer.file.length();
      if (offset > size || offset < size && offset + bytes.length > size)
        throw const StorageFailure('sync_offset_conflict');
      if (offset < size) {
        final handle = await transfer.file.open();
        try {
          await handle.setPosition(offset);
          if (base64Encode(await handle.read(bytes.length)) !=
              base64Encode(bytes))
            throw const StorageFailure('sync_offset_conflict');
        } finally {
          await handle.close();
        }
      } else {
        final handle = await transfer.file.open(mode: FileMode.append);
        try {
          await handle.writeFrom(bytes);
          await handle.flush();
        } finally {
          await handle.close();
        }
      }
      return (200, {'wireVersion': 1, 'offset': await transfer.file.length()});
    }
    if (tail.length == 3 &&
        tail[2] == 'commit' &&
        method == 'POST' &&
        transfer.key == null) {
      final input = _input(raw, {'transferKey'});
      if (input['transferKey'] is! String) throw const FormatException();
      if (transfer.delta != null || transfer.baseline != null) {
        return _commitIncremental(transfer, input['transferKey'] as String);
      }
      final receipt = await owner.restoreLibraryOnce(
        previous: () =>
            replication.receipt(transfer.operationId, transfer.transfer),
        restore: () => replication.installInitial(
          path: transfer.file.path,
          transferKey: input['transferKey'] as String,
          operationId: transfer.operationId,
          transfer: transfer.transfer,
        ),
      );
      return (200, {'wireVersion': 1, 'receipt': receipt.toJson()});
    }
    return (404, {'error': 'not_found'});
  }
}
