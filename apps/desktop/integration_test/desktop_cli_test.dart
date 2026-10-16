import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
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
      debugPrint(
        'D1_NATIVE_VIEW physical=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio} logical=${tester.view.physicalSize / tester.view.devicePixelRatio} dpi=${96 * tester.view.devicePixelRatio}',
      );
      await tester.tap(find.byKey(const ValueKey('theme-green')));
      await tester.pumpAndSettle();
      expect(fixture.service.owner.colorTheme, DesktopColorTheme.green);
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
      final additional = await fixture.service.owner.createInformation(
        'Other fictional connection',
        '',
        [const FieldInput('Reviewed note', '', 'native-reviewed-note')],
      );
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
      await tester.scrollUntilVisible(
        usernameChoice,
        150,
        scrollable: find
            .descendant(
              of: find.byKey(PageStorageKey('detail-$id')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      const hold = int.fromEnvironment('D1_VISUAL_HOLD_SECONDS');
      if (hold > 0) {
        debugPrint('D1_VISUAL_READY request=$id');
        await tester.runAsync(
          () => Future<void>.delayed(Duration(seconds: hold.clamp(0, 60))),
        );
      }
      await tester.tap(usernameChoice);
      await tester.pump();
      await tester.tap(find.text('调整提供范围 / 补选其他信息'));
      await tester.pumpAndSettle();
      final additionalChoice = find.byKey(
        ValueKey('scope-field-${additional.fields.single.id}'),
      );
      await tester.ensureVisible(additionalChoice);
      await tester.pumpAndSettle();
      await tester.tap(additionalChoice);
      await tester.tap(find.byKey(const ValueKey('scope-apply')));
      await tester.pumpAndSettle();
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
        {'itemId': additional.id, 'fieldId': additional.fields.single.id},
      ]);
      final remaining = DateTime.parse(
        claim['expiresAt'] as String,
      ).difference(DateTime.now());
      expect(remaining.inMinutes, inInclusiveRange(478, 480));
      expect((await read(addressId))['value'], 'native.example.invalid');
      expect((await read(addressId))['value'], 'native.example.invalid');
      expect((await read(usernameId))['status'], 'unauthorized');
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          'itemId': additional.id,
          'fieldId': additional.fields.single.id,
        }))['value'],
        'native-reviewed-note',
      );
      final revoke = find.text('撤销授权');
      await tester.ensureVisible(revoke);
      await tester.pumpAndSettle();
      await tester.tap(revoke);
      await tester.pump();
      expect((await read(addressId))['status'], 'unauthorized');
      final organized = await command({
        'command': 'organize-request',
        'purpose': 'Classify synthetic information',
        'itemIds': [itemId],
      });
      expect(organized['status'], 'pending');
      final taskId = organized['taskId'] as String;
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byKey(ValueKey('request-$taskId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批准整理范围'));
      await tester.pumpAndSettle();
      expect(
        (await command({
          'command': 'organize-metadata',
          'taskId': taskId,
        }))['status'],
        'ok',
      );
      expect(
        (await command({
          'command': 'organize-submit',
          'taskId': taskId,
          'changes': [],
        }))['status'],
        'confirmed',
      );
      expect(
        await command({'command': 'organize-metadata', 'taskId': taskId}),
        {'status': 'confirmed'},
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('查看整理结果'), findsOneWidget);
      await tester.ensureVisible(find.text('查看整理结果'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看整理结果'));
      await tester.pumpAndSettle();
      expect(find.text('本次未改动分类或标签。'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await cli.stdin.close();
      expect(await cli.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await errors, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await fixture.bootstrap.runtime!.stop();
      final reopened = await EncryptedInformationRepository.open(
        fixture.root.path,
        WindowsDatabaseKeyStore('${fixture.root.path}/database-key.dpapi'),
      );
      final restarted = InformationService(repository: reopened);
      expect(restarted.owner.colorTheme, DesktopColorTheme.green);
      await restarted.close();
      await reopened.close();
    },
  );
}
