import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/private_connection_files.dart';

class ChiyoIntentFailure implements Exception {
  const ChiyoIntentFailure(this.code);
  final String code;
  @override
  String toString() => 'ChiyoIntentFailure($code)';
}

Object? _canonical(Object? value) => value is Map<String, dynamic>
    ? {
        for (final key in value.keys.toList()..sort())
          key: _canonical(value[key]),
      }
    : value is List
    ? value.map(_canonical).toList()
    : value;
String chiyoIntentDigest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();

class ChiyoIntent {
  ChiyoIntent(this.operationId, this.kind, this.payload, this.createdAt);
  final String operationId, kind;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  Map<String, Object?> get summary => {
    'id': operationId,
    'operationId': operationId,
    'kind': kind,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'source': 'local-intent',
    'state': 'unconfirmed',
  };
}

/// Immutable pre-send records, scoped to the authenticated chat/library, not a
/// global current chat. Only non-material intent is accepted by its callers;
/// proposal contents use frozen source references rather than copied secrets.
/// Server records remain the authority for approval and execution outcomes.
class ChiyoIntentStore {
  ChiyoIntentStore(this.root, this.scope) {
    if (!root.isAbsolute || !RegExp(r'^[0-9a-f]{64}$').hasMatch(scope)) {
      throw const ChiyoIntentFailure('operation_store_unavailable');
    }
  }
  final Directory root;
  final String scope;
  static const kinds = {
    'access-request',
    'fill-request',
    'fill-run',
    'exec-request',
    'exec-run',
    'proposal-submit',
    'reveal-request',
    'reveal-read',
  };
  static const maxRecordBytes = 100 * 1024;
  static const maxRecords = 1000;
  static const maxTotalBytes = 8 * 1024 * 1024;
  Directory get _folder => Directory('${root.path}/$scope');
  static bool validId(String id) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(id);
  static String newOperationId() =>
      'op-${base64Url.encode(List.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '')}';
  File _file(String id) {
    if (!validId(id)) throw const ChiyoIntentFailure('invalid_operation');
    return File('${_folder.path}/${chiyoIntentDigest(id)}.json');
  }

  Future<bool> _verify(Directory dir) async {
    final type = await FileSystemEntity.type(dir.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.directory) throw const FormatException();
    if (Platform.isWindows) {
      WindowsPrivateFiles.verify(dir.path, directory: true);
    } else if ((await dir.stat()).mode & 0xE3F != 0) {
      throw const FormatException();
    }
    return true;
  }

  Future<void> _ensure(Directory dir) async {
    if (await _verify(dir)) return;
    if (Platform.isWindows) {
      WindowsPrivateFiles.directory(dir);
    } else {
      // The parent is already private. Set the mode at directory creation,
      // rather than exposing a chmod window to another first sender.
      await Process.run('/bin/mkdir', ['-m', '700', dir.path]);
      if (!await _verify(dir)) throw const FormatException();
    }
  }

  Future<ChiyoIntent?> read(String id) async {
    try {
      final file = _file(id);
      if (!await _verify(root) || !await _verify(_folder)) return null;
      final raw = await PrivateConnectionFiles.read(file);
      if (raw == null) return null;
      if (raw.length != 8 ||
          raw['version'] != 1 ||
          raw['role'] != 'chiyo-intent' ||
          raw['scope'] != scope ||
          raw['operationId'] != id ||
          !kinds.contains(raw['kind']) ||
          raw['payload'] is! Map<String, dynamic> ||
          raw['digest'] !=
              chiyoIntentDigest({
                'kind': raw['kind'],
                'payload': raw['payload'],
              }) ||
          raw['createdAt'] is! String) {
        throw const FormatException();
      }
      return ChiyoIntent(
        id,
        raw['kind'] as String,
        raw['payload'] as Map<String, dynamic>,
        DateTime.parse(raw['createdAt'] as String),
      );
    } on ChiyoIntentFailure {
      rethrow;
    } on Object {
      throw const ChiyoIntentFailure('operation_store_unavailable');
    }
  }

  Future<ChiyoIntent> remember(
    String kind,
    Map<String, dynamic> payload, {
    String? operationId,
  }) async {
    final id = operationId ?? newOperationId();
    if (!kinds.contains(kind) || !validId(id)) {
      throw const ChiyoIntentFailure('invalid_operation');
    }
    try {
      final digest = chiyoIntentDigest({'kind': kind, 'payload': payload});
      ChiyoIntent match(ChiyoIntent record) {
        if (chiyoIntentDigest({
              'kind': record.kind,
              'payload': record.payload,
            }) !=
            digest) {
          throw const ChiyoIntentFailure('operation_conflict');
        }
        return record;
      }

      final previous = await read(id);
      if (previous != null) return match(previous);
      final raw = <String, Object?>{
        'version': 1,
        'role': 'chiyo-intent',
        'scope': scope,
        'operationId': id,
        'kind': kind,
        'payload': _canonical(payload),
        'digest': digest,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      };
      final size = utf8.encode(jsonEncode(raw)).length;
      if (size > maxRecordBytes) {
        throw const ChiyoIntentFailure('intent_too_large');
      }
      await _ensure(root);
      await _ensure(_folder);
      final files = await _records();
      var bytes = size;
      for (final file in files) {
        bytes += (await file.stat()).size;
      }
      if (files.length >= maxRecords || bytes > maxTotalBytes) {
        throw const ChiyoIntentFailure('operation_store_full');
      }
      try {
        await PrivateConnectionFiles.write(_file(id), raw, replace: false);
      } on Object {
        // Another first sender can publish only the exact same immutable intent.
        final winner = await read(id);
        if (winner != null) return match(winner);
        rethrow;
      }
      return (await read(id))!;
    } on ChiyoIntentFailure {
      rethrow;
    } on Object {
      throw const ChiyoIntentFailure('operation_store_unavailable');
    }
  }

  Future<List<File>> _records() async {
    if (!await _verify(root) || !await _verify(_folder)) return [];
    final files = <File>[];
    await for (final entity in _folder.list(followLinks: false)) {
      final basename = entity.path.replaceAll('\\', '/').split('/').last;
      if (!RegExp(r'^[0-9a-f]{64}\.json$').hasMatch(basename)) continue;
      if (entity is! File) throw const FormatException();
      files.add(entity);
      if (files.length > maxRecords) throw const FormatException();
    }
    return files;
  }

  Future<List<ChiyoIntent>> list() async {
    try {
      final result = <ChiyoIntent>[];
      for (final file in await _records()) {
        final raw = await PrivateConnectionFiles.read(file);
        if (raw?['operationId'] is! String) throw const FormatException();
        final record = await read(raw!['operationId'] as String);
        if (record == null || _file(record.operationId).path != file.path) {
          throw const FormatException();
        }
        result.add(record);
      }
      result.sort((a, b) {
        final time = b.createdAt.compareTo(a.createdAt);
        return time != 0 ? time : a.operationId.compareTo(b.operationId);
      });
      return result;
    } on Object {
      throw const ChiyoIntentFailure('operation_store_unavailable');
    }
  }
}
