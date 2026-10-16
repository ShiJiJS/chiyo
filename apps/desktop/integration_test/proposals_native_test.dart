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
    'isolated Windows CLI batch review retry current content reject delete conflict',
    (tester) async {
      final fixture = await IsolatedDesktopFixture.start(
        prepareLibrary: (service) async {
          await service.owner.createDirectory('Native reviewed folder');
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
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> input(String key, String value) async {
        final finder = find.byKey(ValueKey(key));
        await tester.ensureVisible(finder);
        await tester.enterText(finder, value);
        await tester.pumpAndSettle();
      }

      Future<void> decide(bool confirm) async {
        await tap(
          confirm
              ? find.byKey(const ValueKey('proposal-action-confirm'))
              : find.text('拒绝提案'),
        );
        await tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      }

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

      await command({'command': 'session', 'chatLabel': 'Native D3 review'});
      final invalid = await command({'command': 'import-submit', 'items': []});
      expect(invalid['status'], 'invalid_request');
      final submitted = await command({
        'command': 'import-submit',
        'agentName': 'Codex',
        'purpose': 'Native isolated review',
        'items': [
          {
            'name': 'Native first',
            'description': 'First public',
            'fields': [
              {
                'name': 'URL',
                'description': 'Entry',
                'value': 'first.native.example',
              },
            ],
          },
          {
            'name': 'Native second',
            'description': 'Second public',
            'directoryId': 'missing-native-directory',
            'tagIds': ['missing-native-tag'],
            'fields': [
              {
                'name': 'Note',
                'description': '',
                'value': 'second native note',
                'kind': 'textNote',
              },
            ],
          },
        ],
      });
      expect(submitted['status'], 'pending');
      final id = submitted['proposalId'] as String;
      await tap(find.byKey(const ValueKey('nav-2')));
      await tap(find.byKey(const ValueKey('edit-import-0')));
      await input('item-name', 'Native reviewed first');
      await input('field-value-0', 'reviewed.native.example');
      await tap(find.byKey(const ValueKey('save-information')));
      expect(owner.information, hasLength(1));
      await decide(true);
      expect(find.textContaining('草稿已保留'), findsOneWidget);
      await tap(find.text('返回核对'));
      expect(find.text('reviewed.native.example'), findsOneWidget);
      expect(owner.information, hasLength(1));
      expect(
        (await command({
          'command': 'import-status',
          'proposalId': id,
        }))['status'],
        'pending',
      );
      await tap(find.byKey(const ValueKey('edit-import-1')));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('item-directory')),
          matching: find.text('不可用目录（missing-native-directory）'),
        ),
        findsOneWidget,
      );
      await tap(find.byKey(const ValueKey('item-directory')));
      await tap(find.text('Native reviewed folder').last);
      await tap(find.byKey(const ValueKey('item-tags')));
      await tap(find.text('不可用标签（missing-native-tag）').last);
      await tap(find.text('使用所选标签'));
      await tap(find.byKey(const ValueKey('save-information')));
      await decide(true);
      expect(
        (await command({
          'command': 'import-status',
          'proposalId': id,
        }))['status'],
        'confirmed',
      );
      final batch = owner.importProposals.firstWhere((p) => p.id == id);
      final first = owner.information.firstWhere(
        (item) => item.id == batch.createdItemIds.first,
      );
      final second = owner.information.firstWhere(
        (item) => item.id == batch.createdItemIds.last,
      );
      expect(first.name, 'Native reviewed first');
      expect(first.fields.single.value, 'reviewed.native.example');
      expect(second.fields.single.value, 'second native note');
      expect(second.fields.single.kind, FieldKind.textNote);
      expect(owner.information, hasLength(3));
      await owner.confirmImport(id, 1, const []);
      expect(owner.information, hasLength(3));
      await owner.correctValue(
        FieldRef(first.id, first.fields.single.id),
        'current.native.example',
      );
      await tap(find.text('按信息身份查看当前内容 →'));
      expect(find.text('current.native.example'), findsOneWidget);
      expect(find.text('reviewed.native.example'), findsNothing);
      await tap(find.text('×').last);
      final rejected = await command({
        'command': 'import-submit',
        'items': [
          {
            'name': 'Rejected native',
            'description': '',
            'fields': [
              {
                'name': 'Value',
                'description': '',
                'value': 'do-not-retain-native',
              },
            ],
          },
        ],
      });
      final rejectedId = rejected['proposalId'] as String;
      await tap(find.byKey(const ValueKey('proposal-filter-pending')));
      await tap(find.byKey(ValueKey('proposal-entry-$rejectedId')));
      await decide(false);
      expect(
        (await command({
          'command': 'import-status',
          'proposalId': rejectedId,
        }))['status'],
        'rejected',
      );
      expect(find.text('do-not-retain-native'), findsNothing);
      final deletion = await command({
        'command': 'delete-submit',
        'itemId': first.id,
        'baseVersion': 2,
      });
      final deleteId = deletion['proposalId'] as String;
      await tap(find.byKey(const ValueKey('proposal-filter-pending')));
      await tap(find.byKey(ValueKey('proposal-entry-$deleteId')));
      expect(find.text('current.native.example'), findsOneWidget);
      await decide(true);
      await tap(find.text('按信息身份查看当前内容 →'));
      expect(find.textContaining('当前信息已不存在'), findsOneWidget);
      expect(find.text('current.native.example'), findsNothing);
      await tap(find.text('×').last);
      final update = await command({
        'command': 'update-submit',
        'update': {
          'itemId': second.id,
          'baseVersion': 1,
          'changes': [
            {
              'operation': 'correct',
              'fieldId': second.fields.single.id,
              'value': 'submitted native conflict',
            },
          ],
        },
      });
      expect(update['status'], 'pending');
      final updateId = update['proposalId'] as String;
      await owner.correctValue(
        FieldRef(second.id, second.fields.single.id),
        'manual native conflict',
      );
      await tap(find.byKey(const ValueKey('proposal-filter-pending')));
      await tap(find.byKey(ValueKey('proposal-entry-$updateId')));
      expect(find.text('信息已经发生变化'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('proposal-action-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(
        owner.information
            .firstWhere((item) => item.id == second.id)
            .fields
            .single
            .value,
        'manual native conflict',
      );
      await decide(false);
      expect(
        (await command({
          'command': 'update-status',
          'proposalId': updateId,
        }))['status'],
        'rejected',
      );
      expect(tester.takeException(), isNull);
      await cli.stdin.close();
      expect(await cli.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await errors, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await fixture.bootstrap.runtime!.stop();
      final repo = await EncryptedInformationRepository.open(
        fixture.root.path,
        WindowsDatabaseKeyStore('${fixture.root.path}/database-key.dpapi'),
      );
      final reopened = InformationService(repository: repo);
      try {
        expect(
          reopened.owner.information.any((item) => item.id == first.id),
          isFalse,
        );
        final saved = reopened.owner.information.firstWhere(
          (item) => item.id == second.id,
        );
        expect(saved.fields.single.id, second.fields.single.id);
        expect(saved.fields.single.value, 'manual native conflict');
        expect(
          reopened.owner.importProposals.firstWhere((p) => p.id == id).items,
          isEmpty,
        );
        expect(
          reopened.owner.deleteProposals.single.state,
          DeleteProposalState.confirmed,
        );
        expect(
          reopened.owner.updateProposals.single.state,
          UpdateProposalState.rejected,
        );
      } finally {
        await reopened.close();
        await repo.close();
      }
      debugPrint(
        'D3_NATIVE_VERIFIED CLI two-item → review one → classification validation failure retains whole draft → repair/retry → current-by-ID → reject/delete/conflict; SQLCipher/DPAPI reopen retained receipts and field IDs. Storage I/O fault is separately injected at the public repository widget seam.',
      );
    },
  );
}
