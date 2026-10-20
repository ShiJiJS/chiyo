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
    'isolated Windows library template edit recycle regrant and history',
    (tester) async {
      final fixture = await IsolatedDesktopFixture.start(
        prepareLibrary: (service) async {
          final root = await service.owner.createDirectory('Project');
          await service.owner.createDirectory('Services', parentId: root.id);
          await service.owner.createTag('Self hosted');
          await service.owner.createTemplate('Docs template', 'Public docs', [
            const TemplateFieldInput('URL', 'Public entry'),
            const TemplateFieldInput('Note', '', kind: FieldKind.textNote),
          ]);
        },
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await fixture.close();
      });
      final owner = fixture.service.owner;
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
        'D2_NATIVE_VIEW physical=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio} logical=${tester.view.physicalSize / tester.view.devicePixelRatio}',
      );
      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      Future<void> input(String key, String value) async {
        final target = find.byKey(ValueKey(key));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.enterText(target, value);
        await tester.pumpAndSettle();
      }

      await tap(find.byKey(const ValueKey('nav-1')));
      await tap(find.byKey(const ValueKey('new-information')));
      await tap(find.byKey(const ValueKey('new-template')));
      await tap(find.text('Docs template').last);
      await input('item-name', 'Native documentation');
      await tap(find.byKey(const ValueKey('item-directory')));
      await tap(find.text('Project / Services').last);
      await input('field-value-0', 'https://old.native.example');
      await input('field-value-1', 'controlled note');
      await tap(find.byKey(const ValueKey('save-information')));
      var item = owner.information.firstWhere(
        (i) => i.name == 'Native documentation',
      );
      expect(item.version, 1);
      expect(item.fields.last.kind, FieldKind.textNote);
      expect(item.directoryId, owner.directories.last.id);
      final original = item.fields.first.id, note = item.fields.last.id;
      const dart = String.fromEnvironment(
        'DART_EXECUTABLE',
        defaultValue: 'dart',
      );
      const cliDirectory = String.fromEnvironment(
        'CLI_DIRECTORY',
        defaultValue: '../../packages/info_cli',
      );
      final cli = await Process.start(dart, [
        'run',
        'bin/info.dart',
        '--port',
        '${fixture.port}',
      ], workingDirectory: cliDirectory);
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
      Future<Map<String, dynamic>> command(Map<String, Object?> data) async {
        cli.stdin.writeln(jsonEncode(data));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      await command({
        'command': 'session',
        'chatLabel': 'Native library reader',
      });
      final request = await command({
        'command': 'request',
        'purpose': 'Read native docs',
        'fields': [
          {'itemId': item.id, 'fieldId': original},
          {'itemId': item.id, 'fieldId': note},
        ],
      });
      final requestId = request['requestId'] as String;
      owner.approve(requestId, [
        FieldRef(item.id, original),
        FieldRef(item.id, note),
      ]);
      await command({'command': 'claim', 'requestId': requestId});
      Future<Map<String, dynamic>> read(String field, String request) =>
          command({
            'command': 'read',
            'requestId': request,
            'itemId': item.id,
            'fieldId': field,
          });
      await tap(find.byKey(const ValueKey('edit-information-description')));
      await input('field-value-0', 'https://corrected.native.example');
      await input('item-description', 'Reviewed public description');
      await tap(find.byKey(const ValueKey('save-information')));
      expect(
        (await read(original, requestId))['value'],
        'https://corrected.native.example',
      );
      await tap(find.byKey(const ValueKey('edit-information-category')));
      await tap(find.byKey(const ValueKey('item-directory')));
      await tap(find.text('Project').last);
      await tap(find.byKey(const ValueKey('item-tags')));
      await tap(find.text('Self hosted').last);
      await tap(find.text('使用所选标签'));
      await tap(find.byKey(const ValueKey('save-information')));
      item = owner.information.firstWhere((i) => i.id == item.id);
      expect(item.directoryId, owner.directories.first.id);
      expect(item.tagIds, [owner.tags.single.id]);
      expect(
        (await read(original, requestId))['value'],
        'https://corrected.native.example',
      );
      await tap(find.byKey(const ValueKey('edit-information-description')));
      await tap(find.text('移除字段').first);
      await tap(find.byKey(const ValueKey('save-information')));
      await tap(find.text('确认保存'));
      expect((await read(original, requestId))['status'], 'unauthorized');
      expect((await read(note, requestId))['value'], 'controlled note');
      await tap(find.text('回收站'));
      await tap(find.text('恢复信息'));
      await tap(find.text('确认恢复'));
      item = owner.information.firstWhere((i) => i.id == item.id);
      final fresh = item.fields.firstWhere((f) => f.id != note).id;
      expect(fresh, isNot(original));
      expect((await read(original, requestId))['status'], 'unauthorized');
      expect((await read(fresh, requestId))['status'], 'unauthorized');
      await tap(find.text('×').last);
      final next = await command({
        'command': 'request',
        'purpose': 'Read explicitly restored field',
        'fields': [
          {'itemId': item.id, 'fieldId': fresh},
        ],
      });
      final nextId = next['requestId'] as String;
      owner.approve(nextId, [FieldRef(item.id, fresh)]);
      await command({'command': 'claim', 'requestId': nextId});
      expect(
        (await read(fresh, nextId))['value'],
        'https://corrected.native.example',
      );
      await tap(find.text('修改历史 ↗'));
      await tap(find.text('恢复为新版本').last);
      await tap(find.text('确认恢复为新版本'));
      expect(
        (await read(fresh, nextId))['value'],
        'https://old.native.example',
      );
      expect((await read(original, requestId))['status'], 'unauthorized');
      expect((await read(note, requestId))['value'], 'controlled note');
      expect(owner.importProposals, isEmpty);
      expect(owner.updateProposals, isEmpty);
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
      try {
        final saved = restarted.owner.information.firstWhere(
          (i) => i.id == item.id,
        );
        expect(
          saved.fields.firstWhere((f) => f.id == fresh).value,
          'https://old.native.example',
        );
        expect(
          restarted.owner.recycleFacts
              .firstWhere((f) => f.kind == RecycleFactKind.restored)
              .restoredFieldIds[original],
          fresh,
        );
      } finally {
        await restarted.close();
        await reopened.close();
      }
      debugPrint(
        'D2_NATIVE_VERIFIED template→edit→category→delete→restore→new grant→history; SQLCipher/DPAPI reopen retained identities',
      );
    },
  );
}
