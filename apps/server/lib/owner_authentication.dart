import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' show WindowsPrivateFiles;
import 'server_configuration.dart' show readPrivateFile;

bool _equal(List<int> a, List<int> b) {
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ (i < b.length ? b[i] : 0);
  }
  return difference == 0;
}

String _random() => base64Url
    .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

// PBKDF2-HMAC-SHA256, one 32-byte block. Work is kept off the HTTP isolate.
// https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
List<int> deriveConnectionPassword(
  String password,
  List<int> salt,
  int iterations,
) {
  final hmac = Hmac(sha256, utf8.encode(password));
  var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final result = List<int>.from(block);
  for (var round = 1; round < iterations; round++) {
    block = hmac.convert(block).bytes;
    for (var index = 0; index < result.length; index++) {
      result[index] ^= block[index];
    }
  }
  return result;
}

final class OwnerAuthFailure implements Exception {
  const OwnerAuthFailure(this.code, this.status);
  final String code;
  final int status;
}

/// Owner login state is private server metadata, not library content. Login is
/// read-only; only initial setup/password changes write this small file.
final class OwnerAuthentication {
  OwnerAuthentication._(this._file, this._rootToken, this._state);
  final File _file;
  final String _rootToken;
  Map<String, dynamic> _state;
  Future<void> _serial = Future.value();
  final _attempts = <String, ({DateTime at, int count})>{};
  static const passwordIterations = 600000;

  static Future<OwnerAuthentication> open(
    String dataDirectory,
    String rootToken, {
    bool newLibrary = false,
  }) async {
    final directory = Directory(dataDirectory);
    final file = File('$dataDirectory/connection-auth.json');
    final exists = await FileSystemEntity.type(file.path, followLinks: false);
    Map<String, dynamic> state;
    if (exists == FileSystemEntityType.notFound) {
      // An existing library may only acquire its first password through an
      // authenticated old Owner connection; a stranger cannot claim it.
      final existingData =
          !newLibrary &&
          await FileSystemEntity.type(
                '$dataDirectory/library.db',
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound;
      state = {
        'version': 1,
        'requiresOwnerToken': existingData,
        'password': null,
      };
      await directory.create(recursive: true);
      await _write(file, state);
    } else {
      state =
          jsonDecode(
                Platform.isWindows
                    ? WindowsPrivateFiles.readSecret(file)!
                    : utf8.decode(
                        await readPrivateFile(file.path, maxBytes: 16384),
                      ),
              )
              as Map<String, dynamic>;
    }
    if (state['version'] != 1 ||
        state['requiresOwnerToken'] is! bool ||
        state.keys.toSet().difference({
          'version',
          'requiresOwnerToken',
          'password',
        }).isNotEmpty) {
      throw const FormatException('Invalid connection authentication state');
    }
    final password = state['password'];
    if (password != null) {
      if (password is! Map ||
          password['iterations'] != passwordIterations ||
          password['salt'] is! String ||
          password['hash'] is! String ||
          password['generation'] is! String ||
          base64Url.decode(password['salt'] as String).length != 32 ||
          base64Url.decode(password['hash'] as String).length != 32 ||
          !RegExp(
            r'^[A-Za-z0-9_-]{43}$',
          ).hasMatch(password['generation'] as String)) {
        throw const FormatException('Invalid connection password state');
      }
    }
    return OwnerAuthentication._(file, rootToken, state);
  }

  bool get configured => _state['password'] != null;
  bool get requiresOwnerToken =>
      !configured && _state['requiresOwnerToken'] == true;
  String get _sessionToken => base64Url
      .encode(
        Hmac(sha256, utf8.encode(_rootToken))
            .convert(
              utf8.encode(
                'chiyo-owner-login:${(_state['password'] as Map)['generation']}',
              ),
            )
            .bytes,
      )
      .replaceAll('=', '');
  bool isRoot(String value) =>
      _equal(utf8.encode(value), utf8.encode(_rootToken));
  bool accepts(String value) =>
      isRoot(value) ||
      configured && _equal(utf8.encode(value), utf8.encode(_sessionToken));

  Map<String, Object?> status(String serverId) => {
    'protocolVersion': 1,
    'serverId': serverId,
    'passwordConfigured': configured,
    'requiresOwnerToken': requiresOwnerToken,
  };

  void _limit(String peer) {
    final now = DateTime.now();
    _attempts.removeWhere(
      (_, value) => now.difference(value.at) > const Duration(minutes: 1),
    );
    final previous = _attempts[peer];
    if ((previous?.count ?? 0) >= 10 ||
        previous == null && _attempts.length >= 256) {
      throw const OwnerAuthFailure('too_many_attempts', 429);
    }
    _attempts[peer] = (
      at: previous?.at ?? now,
      count: (previous?.count ?? 0) + 1,
    );
  }

  void _validatePassword(String password) {
    if (password.isEmpty || utf8.encode(password).length > 1024) {
      throw const OwnerAuthFailure('invalid_password', 400);
    }
  }

  Future<bool> _verify(String password) async {
    _validatePassword(password);
    if (!configured) return false;
    final record = Map<String, dynamic>.from(_state['password'] as Map);
    final salt = base64Url.decode(record['salt'] as String);
    final actual = await Isolate.run(
      () => deriveConnectionPassword(password, salt, passwordIterations),
    );
    return _equal(actual, base64Url.decode(record['hash'] as String));
  }

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final next = _serial.then((_) => action());
    _serial = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<String> initialize(
    String password, {
    required String peer,
    String ownerToken = '',
  }) async {
    _limit(peer);
    return _exclusive(() async {
      if (configured) throw const OwnerAuthFailure('already_initialized', 409);
      if (requiresOwnerToken && !isRoot(ownerToken)) {
        throw const OwnerAuthFailure('owner_confirmation_required', 401);
      }
      await _setPassword(password);
      return _sessionToken;
    });
  }

  Future<String> login(String password, {required String peer}) async {
    _limit(peer);
    return _exclusive(() async {
      if (!configured) throw const OwnerAuthFailure('not_initialized', 409);
      if (!await _verify(password))
        throw const OwnerAuthFailure('invalid_password', 401);
      return _sessionToken;
    });
  }

  Future<String> change(
    String current,
    String replacement, {
    required String token,
    required String peer,
  }) async {
    _limit(peer);
    return _exclusive(() async {
      if (!accepts(token)) throw const OwnerAuthFailure('unauthorized', 401);
      if (!await _verify(current))
        throw const OwnerAuthFailure('invalid_password', 401);
      await _setPassword(replacement);
      return _sessionToken;
    });
  }

  Future<void> _setPassword(String password) async {
    _validatePassword(password);
    final salt = List.generate(32, (_) => Random.secure().nextInt(256));
    final hash = await Isolate.run(
      () => deriveConnectionPassword(password, salt, passwordIterations),
    );
    final updated = <String, dynamic>{
      'version': 1,
      'requiresOwnerToken': false,
      'password': {
        'iterations': passwordIterations,
        'salt': base64Url.encode(salt),
        'hash': base64Url.encode(hash),
        'generation': _random(),
      },
    };
    await _write(_file, updated);
    _state = updated;
  }

  static Future<void> _write(File file, Map<String, dynamic> value) async {
    if (Platform.isWindows) {
      WindowsPrivateFiles.writeSecret(file, jsonEncode(value));
      return;
    }
    final temp = File('${file.path}.${_random()}.pending');
    try {
      await temp.create(exclusive: true);
      if ((await Process.run('/bin/chmod', ['600', temp.path])).exitCode != 0) {
        throw const FileSystemException(
          'Private authentication storage unavailable',
        );
      }
      await temp.writeAsString(jsonEncode(value), flush: true);
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const FileSystemException('Invalid authentication state path');
      }
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
