import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native desktop and separate CLI approve, limit, revoke', (
    tester,
  ) async {
    await app.main();
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
    ], workingDirectory: directory);
    final lines = StreamIterator(
      cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final errors = cli.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      await cli.stdin.close();
      cli.kill();
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

    expect((await command({'command': 'catalog'}))['status'], 'ok');
    expect(
      await command({'command': 'session', 'chatLabel': 'native-desktop-demo'}),
      {'status': 'ok'},
    );
    final request = await command({
      'command': 'request',
      'purpose': 'Use only the fictional address',
      'fields': [
        {'itemId': 'demo-server', 'fieldId': 'host'},
        {'itemId': 'demo-server', 'fieldId': 'username'},
      ],
    });
    expect(request['status'], 'pending');
    final id = request['requestId'];
    expect(
      (await command({
        'command': 'read',
        'requestId': id,
        'itemId': 'demo-server',
        'fieldId': 'host',
      }))['status'],
      'unauthorized',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byKey(const ValueKey('field-username')));
    await tester.pump();
    await tester.tap(find.text('批准所选字段'));
    await tester.pump();
    final claim = await command({'command': 'claim', 'requestId': id});
    expect(claim['status'], 'ok');
    expect(claim.containsKey('token'), isFalse);
    expect(
      (await command({
        'command': 'read',
        'requestId': id,
        'itemId': 'demo-server',
        'fieldId': 'host',
      }))['value'],
      'demo.example.invalid',
    );
    expect(
      (await command({
        'command': 'read',
        'requestId': id,
        'itemId': 'demo-server',
        'fieldId': 'username',
      }))['status'],
      'unauthorized',
    );
    await tester.tap(find.text('撤销授权'));
    await tester.pump();
    expect(
      (await command({
        'command': 'read',
        'requestId': id,
        'itemId': 'demo-server',
        'fieldId': 'host',
      }))['status'],
      'unauthorized',
    );
    await cli.stdin.close();
    expect(await cli.exitCode, 0);
    expect(await errors, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
