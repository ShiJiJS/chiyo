import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'codex_association.dart';

/// Index contains only independent end capabilities, never a read-capable
/// association locator or secret. Public-ID callbacks can cause termination only.
class CodexEndIndex {
  CodexEndIndex(Directory root)
    : _directory = Directory('${root.path}/end-only');
  final Directory _directory;
  static const _maxGenerations = 64;

  String _key(String chat) {
    if (!validChatId(chat)) throw const FormatException();
    return sha256.convert(utf8.encode(chat)).toString();
  }

  Future<void> register(String chat, int port, String endCapability) async {
    _key(chat);
    _validateCapability(endCapability);
    if (port < 1 || port > 65535) throw const FormatException();
    await _directory
        .create(); // Parent was protected when association was saved.
    await _checkDirectory();
    await _locked(chat, () async {
      final records = await _read(chat);
      if (records.length >= _maxGenerations) {
        throw const FileSystemException('end_index_full');
      }
      final random = Random.secure();
      final generation = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      records.add(_EndRecord(generation, port, endCapability));
      await _write(chat, records);
    }, create: true);
  }

  /// No directory creation or ACL subprocess is permitted on this path.
  /// A single monotonic deadline bounds locking, file work and network I/O.
  Future<String> end(
    String chat, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    _key(chat);
    final watch = Stopwatch()..start();
    Duration remaining() {
      final rest = timeout - watch.elapsed;
      if (rest <= Duration.zero) throw TimeoutException('end_deadline');
      return rest;
    }

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await (() async {
        if (!await _directory.exists()) return 'no_active_session';
        await _checkDirectory();
        final snapshot = await _locked(
          chat,
          () => _read(chat),
          remaining: remaining,
        );
        if (snapshot.isEmpty) return 'no_active_session';
        final confirmed = <String>{};
        await Future.wait(
          snapshot.map((record) async {
            try {
              final request = await client.post(
                '127.0.0.1',
                record.port,
                '/session/end',
              );
              request.followRedirects = false;
              request.headers.contentType = ContentType.json;
              request.write(jsonEncode({'endCapability': record.capability}));
              final response = await request.close();
              final bytes = <int>[];
              await for (final chunk in response) {
                if (bytes.length + chunk.length > 1024) {
                  throw const FormatException();
                }
                bytes.addAll(chunk);
              }
              final result = jsonDecode(utf8.decode(bytes));
              if (result is Map && result['status'] == 'ended') {
                confirmed.add(record.generation);
              }
            } on Object {
              /* Failed generations remain available for a later end. */
            }
          }),
        ).timeout(remaining());
        if (confirmed.isNotEmpty) {
          await _locked(chat, () async {
            final current = await _read(chat);
            current.removeWhere(
              (record) => confirmed.contains(record.generation),
            );
            await _write(chat, current);
          }, remaining: remaining);
        }
        return confirmed.length == snapshot.length
            ? 'ended'
            : 'end_unavailable';
      })().timeout(remaining());
    } on Object {
      return 'end_unavailable';
    } finally {
      client.close(force: true);
      watch.stop();
    }
  }

  Future<void> _checkDirectory() async {
    if (await FileSystemEntity.type(_directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(
              _directory.parent.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
      throw const FormatException();
    }
  }

  Future<T> _locked<T>(
    String chat,
    Future<T> Function() action, {
    bool create = false,
    Duration Function()? remaining,
  }) async {
    final lock = File('${_directory.path}/${_key(chat)}.lock');
    if (create && !await lock.exists()) {
      try {
        await lock.create(exclusive: true);
      } on FileSystemException {
        if (!await lock.exists()) rethrow;
      }
    }
    if (await FileSystemEntity.type(lock.path, followLinks: false) !=
        FileSystemEntityType.file) {
      // Absence is harmless on duplicate/unknown SessionEnd.
      if (!create && !await lock.exists()) return action();
      throw const FormatException();
    }
    final handle = await lock.open(mode: FileMode.append);
    var held = false;
    final wait = Stopwatch()..start();
    try {
      while (!held) {
        remaining?.call();
        try {
          await handle.lock(FileLock.exclusive);
          held = true;
        } on FileSystemException {
          if (wait.elapsed > const Duration(seconds: 2)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      return await action();
    } finally {
      if (held) await handle.unlock();
      await handle.close();
    }
  }

  Future<List<_EndRecord>> _read(String chat) async {
    final file = File('${_directory.path}/${_key(chat)}.json');
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return [];
    if (type != FileSystemEntityType.file || await file.length() > 32768) {
      throw const FormatException();
    }
    final data = jsonDecode(await file.readAsString());
    if (data is! Map ||
        data.keys.any((key) => !['version', 'chatId', 'records'].contains(key)) ||
        data['version'] != 1 ||
        data['chatId'] != chat ||
        data['records'] is! List) {
      throw const FormatException();
    }
    final records = data['records'] as List;
    if (records.length > _maxGenerations) throw const FormatException();
    final result = records.map((raw) => _EndRecord.parse(raw)).toList();
    if (result.map((r) => r.generation).toSet().length != result.length) {
      throw const FormatException();
    }
    return result;
  }

  Future<void> _write(String chat, List<_EndRecord> records) async {
    final file = File('${_directory.path}/${_key(chat)}.json');
    if (records.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    final temp = File('${file.path}.${Random.secure().nextInt(1 << 32)}.tmp');
    await temp.create(exclusive: true);
    try {
      await temp.writeAsString(
        jsonEncode({
          'version': 1,
          'chatId': chat,
          'records': records.map((r) => r.toJson()).toList(),
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}

void _validateCapability(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(value)) {
    throw const FormatException();
  }
}

class _EndRecord {
  const _EndRecord(this.generation, this.port, this.capability);
  final String generation, capability;
  final int port;
  Map<String, Object> toJson() => {
    'generation': generation,
    'port': port,
    'endCapability': capability,
  };
  factory _EndRecord.parse(dynamic data) {
    if (data is! Map ||
        data.keys.any(
          (k) => !['generation', 'port', 'endCapability'].contains(k),
        ) ||
        data['generation'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(data['generation'] as String) ||
        data['port'] is! int ||
        data['port'] < 1 ||
        data['port'] > 65535 ||
        data['endCapability'] is! String) {
      throw const FormatException();
    }
    _validateCapability(data['endCapability'] as String);
    return _EndRecord(
      data['generation'] as String,
      data['port'] as int,
      data['endCapability'] as String,
    );
  }
}
