@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:info_server/owner_authentication.dart';
import 'package:test/test.dart';

void main() {
  test('PBKDF2 matches the SHA256 reference vector', () {
    final result = deriveConnectionPassword('password', utf8.encode('salt'), 2);
    expect(
      result.map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
      'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
    );
  });
  test(
    'password survives restart; changing it revokes password logins, preserves legacy owner',
    () async {
      final directory = await Directory.systemTemp.createTemp('chiyo-auth-');
      addTearDown(() => directory.delete(recursive: true));
      final root = 'A' * 43;
      final auth = await OwnerAuthentication.open(directory.path, root);
      expect(auth.configured, isFalse);
      expect(auth.requiresOwnerToken, isFalse);
      final token = await auth.initialize(
        'synthetic-first-password',
        peer: 'local',
      );
      expect(auth.accepts(token), isTrue);
      final reopened = await OwnerAuthentication.open(directory.path, root);
      expect(
        await reopened.login('synthetic-first-password', peer: 'local'),
        token,
      );
      await expectLater(
        reopened.login('wrong', peer: 'local'),
        throwsA(isA<OwnerAuthFailure>()),
      );
      final replacement = await reopened.change(
        'synthetic-first-password',
        'synthetic-new-password',
        token: token,
        peer: 'local',
      );
      expect(reopened.accepts(token), isFalse);
      expect(reopened.accepts(replacement), isTrue);
      expect(reopened.accepts(root), isTrue);
      final state = await File(
        '${directory.path}/connection-auth.json',
      ).readAsString();
      expect(state, isNot(contains('synthetic')));
      expect(state, isNot(contains(token)));
      final finalOpen = await OwnerAuthentication.open(directory.path, root);
      expect(
        await finalOpen.login('synthetic-new-password', peer: 'local'),
        replacement,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'an old library cannot be claimed without its original owner proof',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'chiyo-auth-old-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final database = File('${directory.path}/library.db');
      await database.writeAsString('synthetic unchanged data');
      final auth = await OwnerAuthentication.open(directory.path, 'B' * 43);
      expect(auth.requiresOwnerToken, isTrue);
      await expectLater(
        auth.initialize('synthetic', peer: 'local'),
        throwsA(
          isA<OwnerAuthFailure>().having(
            (e) => e.code,
            'code',
            'owner_confirmation_required',
          ),
        ),
      );
      await auth.initialize('synthetic', peer: 'local', ownerToken: 'B' * 43);
      expect(await database.readAsString(), 'synthetic unchanged data');
      await expectLater(
        auth.initialize('replacement', peer: 'local', ownerToken: 'B' * 43),
        throwsA(
          isA<OwnerAuthFailure>().having(
            (e) => e.code,
            'code',
            'already_initialized',
          ),
        ),
      );
    },
  );
  test('two simultaneous first setups cannot replace each other', () async {
    final directory = await Directory.systemTemp.createTemp('chiyo-auth-race-');
    addTearDown(() => directory.delete(recursive: true));
    final auth = await OwnerAuthentication.open(directory.path, 'D' * 43);
    final first = auth.initialize('synthetic-first', peer: 'first');
    final second = auth.initialize('synthetic-second', peer: 'second');
    final denied = expectLater(
      second,
      throwsA(
        isA<OwnerAuthFailure>().having(
          (e) => e.code,
          'code',
          'already_initialized',
        ),
      ),
    );
    final token = await first;
    await denied;
    expect(await auth.login('synthetic-first', peer: 'verify'), token);
    await expectLater(
      auth.login('synthetic-second', peer: 'verify'),
      throwsA(
        isA<OwnerAuthFailure>().having(
          (e) => e.code,
          'code',
          'invalid_password',
        ),
      ),
    );
  });
  test(
    'unconfigured login attempts are bounded without hashing or state writes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'chiyo-auth-rate-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final auth = await OwnerAuthentication.open(directory.path, 'C' * 43);
      final file = File('${directory.path}/connection-auth.json');
      final before = await file.readAsBytes();
      for (var i = 0; i < 10; i++) {
        await expectLater(
          auth.login('synthetic', peer: 'local'),
          throwsA(
            isA<OwnerAuthFailure>().having(
              (e) => e.code,
              'code',
              'not_initialized',
            ),
          ),
        );
      }
      await expectLater(
        auth.login('synthetic', peer: 'local'),
        throwsA(isA<OwnerAuthFailure>().having((e) => e.status, 'status', 429)),
      );
      expect(await file.readAsBytes(), before);
    },
  );
}
