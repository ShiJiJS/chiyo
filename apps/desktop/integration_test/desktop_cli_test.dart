import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/main.dart' as app;

import 'support/isolated_desktop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'isolated native desktop and real CLI approve, limit, repeat, revoke',
    (tester) async {
      final fixture = await IsolatedDesktopFixture.start();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await fixture.close();
      });
      await tester.pumpWidget(
        app.InformationApp(
          service: fixture.service,
          port: fixture.port,
          runtime: fixture.bootstrap.runtime,
          backups: fixture.bootstrap.library!.backups,
        ),
      );
      await tester.pumpAndSettle();
      const dart = String.fromEnvironment(
        'DART_EXECUTABLE',
        defaultValue: 'dart',
      );
      const directory = String.fromEnvironment(
        'CLI_DIRECTORY',
        defaultValue: '../../packages/info_cli',
      );
      final cli = await Process.start(dart, [
        'run',
        'bin/info.dart',
        '--port',
        '${fixture.port}',
      ], workingDirectory: directory);
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        await cli.stdin.close();
        cli.kill();
        await cli.exitCode.timeout(const Duration(seconds: 10));
        await lines.cancel();
      });
      Future<Map<String, dynamic>> command(Map<String, dynamic> command) async {
        cli.stdin.writeln(jsonEncode(command));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      final catalog = await command({'command': 'catalog'});
      expect(catalog['status'], 'ok');
      expect(catalog['items'], hasLength(1));
      final item = (catalog['items'] as List).single as Map;
      final itemId = item['id'] as String;
      final fields = item['fields'] as List;
      final address =
          fields.firstWhere((dynamic f) => f['name'] == 'Address') as Map;
      final username =
          fields.firstWhere((dynamic f) => f['name'] == 'Username') as Map;
      final addressId = address['id'] as String;
      final usernameId = username['id'] as String;
      expect(
        await command({
          'command': 'session',
          'chatLabel': 'native-desktop-demo',
        }),
        {'status': 'ok'},
      );
      final request = await command({
        'command': 'request',
        'purpose': 'Use only the fictional address',
        'fields': [
          {'itemId': itemId, 'fieldId': addressId},
          {'itemId': itemId, 'fieldId': usernameId},
        ],
      });
      expect(request['status'], 'pending');
      final id = request['requestId'];
      Future<Map<String, dynamic>> read(String fieldId) => command({
        'command': 'read',
        'requestId': id,
        'itemId': itemId,
        'fieldId': fieldId,
      });
      expect((await read(addressId))['status'], 'unauthorized');
      await tester.pump(const Duration(seconds: 2));
      final usernameChoice = find.byKey(ValueKey('field-$usernameId'));
      await tester.ensureVisible(usernameChoice);
      await tester.pumpAndSettle();
      await tester.tap(usernameChoice);
      await tester.pump();
      final approve = find.byKey(const ValueKey('approve-selection'));
      await tester.ensureVisible(approve);
      await tester.pumpAndSettle();
      await tester.tap(approve);
      await tester.pump();
      final claim = await command({'command': 'claim', 'requestId': id});
      expect(claim['status'], 'ok');
      expect(claim.containsKey('token'), isFalse);
      expect(claim['fields'], [
        {'itemId': itemId, 'fieldId': addressId},
      ]);
      expect((await read(addressId))['value'], 'native.example.invalid');
      expect((await read(addressId))['value'], 'native.example.invalid');
      expect((await read(usernameId))['status'], 'unauthorized');
      final revoke = find.text('撤销授权');
      await tester.ensureVisible(revoke);
      await tester.pumpAndSettle();
      await tester.tap(revoke);
      await tester.pump();
      expect((await read(addressId))['status'], 'unauthorized');
      await cli.stdin.close();
      expect(await cli.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await errors, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
