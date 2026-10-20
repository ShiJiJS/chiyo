import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart' show InformationApp;
import 'support/native_semantics_lifetime.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

// Native Flutter and SQLCipher with controlled concurrent edits/ephemeral key.
// The parent runs the independent shipped CLI outside the application sandbox.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac native batch review retry rejection deletion conflict and reopen',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      const marker = String.fromEnvironment('MAC_QA_OWNER');
      expect(marker, matches(RegExp(r'^[a-f0-9]{32}$')));
      final root = await Directory.systemTemp.createTemp(
        'aim-mac-proposals-ui-',
      );
      await File('${root.path}/.qa-owner').writeAsString(marker);
      debugPrint('MAC_PROPOSALS_ROOT=${root.path}');
      final semantics = NativeSemanticsLifetime(tester);
      final shadows = debugDisableShadows;
      debugDisableShadows = false;
      final keys = _Keys();
      var repository = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      var service = InformationService(repository: repository);
      var server = await AgentServer.start(service.agent, port: 0);
      final boundary = GlobalKey();
      final captures = <String>[];
      var step = 0;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await server.close();
        await service.close();
        await repository.close();
        semantics.finishAfterUnmount();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDisableShadows = shadows;
      });
      Future<Map<String, dynamic>> exchange(
        String phase, [
        Map<String, Object?> extra = const {},
      ]) async {
        step++;
        await File('${root.path}/phase-$step.json').writeAsString(
          jsonEncode({'phase': phase, 'port': server.port, ...extra}),
          flush: true,
        );
        final reply = File('${root.path}/reply-$step.json');
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (!await reply.exists()) {
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'Independent CLI deadline',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final result =
            jsonDecode(await reply.readAsString()) as Map<String, dynamic>;
        expect(result['ok'], isTrue);
        return result;
      }

      Future<void> mount() async {
        tester.view.physicalSize = const Size(1440, 1000);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: InformationApp(service: service, port: server.port),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(target.hitTestable(), findsOneWidget);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> input(String key, String value) async {
        final target = find.byKey(ValueKey(key));
        await tester.ensureVisible(target);
        await tester.enterText(target, value);
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${root.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        captures.add('$name.png');
      }

      final category = await service.owner.createDirectory(
        'Mac reviewed folder',
      );
      await mount();
      Future<void> decide(bool confirm) async {
        await tap(
          confirm
              ? find.byKey(const ValueKey('proposal-action-confirm'))
              : find.text('拒绝提案'),
        );
        await tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      }

      final submitted = await exchange('submit');
      final id = submitted['proposalId'] as String;
      await tap(find.byKey(const ValueKey('nav-2')));
      await tap(find.byKey(const ValueKey('edit-import-0')));
      await input('item-name', 'Mac reviewed first');
      await input('field-value-0', 'reviewed.native.example');
      await tap(find.byKey(const ValueKey('save-information')));
      expect(service.owner.information, isEmpty);
      await decide(true);
      expect(find.textContaining('草稿已保留'), findsOneWidget);
      await capture('01-validation-failure');
      await tap(find.text('返回核对'));
      expect(find.text('reviewed.native.example'), findsOneWidget);
      expect(service.owner.information, isEmpty);
      await exchange('draft-retained');
      await tap(find.byKey(const ValueKey('edit-import-1')));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('item-directory')),
          matching: find.text('不可用目录（missing-native-directory）'),
        ),
        findsOneWidget,
      );
      await tap(find.byKey(const ValueKey('item-directory')));
      await tap(find.text('Mac reviewed folder').last);
      await tap(find.byKey(const ValueKey('item-tags')));
      await tap(find.text('不可用标签（missing-native-tag）').last);
      await tap(find.text('使用所选标签'));
      await tap(find.byKey(const ValueKey('save-information')));
      await capture('02-corrected-draft');
      await decide(true);
      final batch = service.owner.importProposals.single;
      expect(batch.id, id);
      expect(batch.state, ImportProposalState.confirmed);
      expect(batch.createdItemIds, hasLength(2));
      var first = service.owner.information.firstWhere(
        (i) => i.id == batch.createdItemIds.first,
      );
      var second = service.owner.information.firstWhere(
        (i) => i.id == batch.createdItemIds.last,
      );
      expect(first.name, 'Mac reviewed first');
      expect(first.fields.single.value, 'reviewed.native.example');
      expect(second.fields.single.kind, FieldKind.textNote);
      expect(second.fields.single.value, 'second native note');
      expect(second.directoryId, category.id);
      expect(second.tagIds, isEmpty);
      expect(service.owner.information, hasLength(2));
      // Controlled public-owner retry checks duplicate confirmation independently.
      await service.owner.confirmImport(id, 1, const []);
      expect(service.owner.information, hasLength(2));
      await capture('03-confirmed');
      await exchange('confirmed', {
        'firstId': first.id,
        'firstField': first.fields.single.id,
        'secondId': second.id,
        'secondField': second.fields.single.id,
      });
      // Simulate a concurrent owner edit; the receipt must resolve current IDs.
      await service.owner.correctValue(
        FieldRef(first.id, first.fields.single.id),
        'current.native.example',
      );
      await tap(find.text('按信息身份查看当前内容 →'));
      expect(find.text('current.native.example'), findsOneWidget);
      expect(find.text('reviewed.native.example'), findsNothing);
      await capture('04-current-content');
      await tap(find.text('在信息库打开 →').first);
      expect(find.byKey(ValueKey('information-${first.id}')), findsOneWidget);
      expect(find.text('current.native.example'), findsOneWidget);
      await tap(find.byKey(const ValueKey('nav-2')));
      final rejected = await exchange('current-content');
      final rejectedId = rejected['proposalId'] as String;
      await tap(find.byKey(const ValueKey('proposal-filter-pending')));
      await tap(find.byKey(ValueKey('proposal-entry-$rejectedId')));
      await decide(false);
      expect(find.text('do-not-retain-native'), findsNothing);
      expect(service.owner.information, hasLength(2));
      await capture('05-rejected');
      final deletion = await exchange('rejected');
      final deleteId = deletion['proposalId'] as String;
      await tap(find.byKey(const ValueKey('proposal-filter-pending')));
      await tap(find.byKey(ValueKey('proposal-entry-$deleteId')));
      expect(find.text('current.native.example'), findsOneWidget);
      await decide(true);
      expect(service.owner.information.any((i) => i.id == first.id), isFalse);
      await tap(find.text('按信息身份查看当前内容 →'));
      expect(find.textContaining('当前信息已不存在'), findsOneWidget);
      expect(find.text('current.native.example'), findsNothing);
      await capture('06-deleted-current-content');
      await tap(find.text('×').last);
      final update = await exchange('deleted');
      final updateId = update['proposalId'] as String;
      await service.owner.correctValue(
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
        service.owner.information.single.fields.single.value,
        'manual native conflict',
      );
      await capture('07-conflict-confirm-disabled');
      await exchange('conflict');
      await decide(false);
      expect(
        service.owner.information.single.fields.single.value,
        'manual native conflict',
      );
      await capture('08-conflict-rejected');
      await exchange('conflict-rejected');
      await tester.pumpWidget(const SizedBox());
      await server.close();
      await service.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      service = InformationService(repository: repository);
      server = await AgentServer.start(service.agent, port: 0);
      expect(service.owner.information, hasLength(1));
      final saved = service.owner.information.single;
      expect(saved.id, second.id);
      expect(saved.fields.single.id, second.fields.single.id);
      expect(saved.fields.single.value, 'manual native conflict');
      expect(saved.version, 2);
      expect(saved.directoryId, category.id);
      expect(saved.tagIds, isEmpty);
      final imported = service.owner.importProposals.firstWhere(
        (p) => p.id == id,
      );
      expect(imported.items, isEmpty);
      expect(imported.createdItemIds, [first.id, second.id]);
      expect(imported.state, ImportProposalState.confirmed);
      final declined = service.owner.importProposals.firstWhere(
        (p) => p.id == rejectedId,
      );
      expect(declined.state, ImportProposalState.rejected);
      expect(declined.items, isEmpty);
      expect(service.owner.deleteProposals.single.id, deleteId);
      expect(
        service.owner.deleteProposals.single.state,
        DeleteProposalState.confirmed,
      );
      expect(service.owner.updateProposals.single.id, updateId);
      expect(
        service.owner.updateProposals.single.state,
        UpdateProposalState.rejected,
      );
      await mount();
      await tap(find.byKey(const ValueKey('nav-2')));
      await capture('09-reopened-receipts');
      await tap(find.byKey(const ValueKey('nav-1')));
      expect(find.text('manual native conflict'), findsOneWidget);
      expect(find.text('Mac reviewed first'), findsNothing);
      await capture('10-reopened-library');
      await exchange('repository-reopened');
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'complete': true,
          'phases': step + 1,
          'firstItemId': first.id,
          'secondItemId': second.id,
          'secondFieldId': second.fields.single.id,
          'captures': captures,
          'scope':
              'Native Flutter/SQLCipher tester-driven proposal review; parent AOT CLI submits and polls; fixture directory, ephemeral key, concurrent owner corrections and duplicate-confirm retry. No physical input, Keychain or app process relaunch.',
        }),
        flush: true,
      );
      await exchange('complete');
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
