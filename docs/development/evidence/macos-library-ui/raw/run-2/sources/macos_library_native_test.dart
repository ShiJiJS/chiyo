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

// Native Flutter and SQLCipher with controlled owner approvals/ephemeral key.
// The parent runs the independent shipped CLI outside the application sandbox.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac native template edit recycle regrant revision and reopen',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      const marker = String.fromEnvironment('MAC_QA_OWNER');
      expect(marker, matches(RegExp(r'^[a-f0-9]{32}$')));
      final root = await Directory.systemTemp.createTemp('aim-mac-library-ui-');
      await File('${root.path}/.qa-owner').writeAsString(marker);
      debugPrint('MAC_LIBRARY_ROOT=${root.path}');
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

      // Directory/tag creation is fixture preparation; their assignment is UI.
      final category = await service.owner.createDirectory('Project');
      final child = await service.owner.createDirectory(
        'Services',
        parentId: category.id,
      );
      final tag = await service.owner.createTag('Self hosted');
      await mount();
      await tap(find.byKey(const ValueKey('nav-4')));
      await tap(find.byKey(const ValueKey('settings-section-templates')));
      await tap(find.text('新建模板'));
      await input('template-name', 'Mac 合成模板');
      await input('template-field-name-0', '地址');
      await tap(find.text('＋ 添加字段'));
      await input('template-field-name-1', '备注');
      await tap(find.byTooltip('字段形式').last);
      await tap(find.text('多行文本').last);
      await tap(find.text('保存模板'));
      expect(
        service.owner.templates.single.fields.last.kind,
        FieldKind.textNote,
      );
      expect(service.owner.information, isEmpty);
      await capture('01-template');
      await tap(find.byKey(const ValueKey('nav-1')));
      await tap(find.byKey(const ValueKey('new-information')));
      await tap(find.byKey(const ValueKey('new-template')));
      await tap(find.text('Mac 合成模板').last);
      await input('item-name', 'Mac 合成资料');
      await tap(find.byKey(const ValueKey('item-directory')));
      await tap(find.text('Project / Services').last);
      await input('field-value-0', 'https://old.native.example');
      await input('field-value-1', 'controlled note');
      expect(service.owner.information, isEmpty);
      await tap(find.byKey(const ValueKey('save-information')));
      var item = service.owner.information.single;
      expect(item.version, 1);
      expect(item.directoryId, child.id);
      expect(item.fields.last.kind, FieldKind.textNote);
      final itemId = item.id,
          original = item.fields.first.id,
          note = item.fields.last.id;
      await capture('02-created');
      final requested = await exchange('request', {
        'itemId': itemId,
        'oldField': original,
        'remainingField': note,
      });
      service.owner.approve(requested['requestId'] as String, [
        FieldRef(itemId, original),
        FieldRef(itemId, note),
      ]);
      await exchange('approved');
      await tap(find.byKey(const ValueKey('edit-information-description')));
      await input('field-value-0', 'https://corrected.native.example');
      await input('item-description', 'Reviewed public description');
      await tap(find.byKey(const ValueKey('save-information')));
      await tap(find.byKey(const ValueKey('edit-information-category')));
      await tap(find.byKey(const ValueKey('item-directory')));
      await tap(find.text('Project').last);
      await tap(find.byKey(const ValueKey('item-tags')));
      await tap(find.text('Self hosted').last);
      await tap(find.text('使用所选标签'));
      await tap(find.byKey(const ValueKey('save-information')));
      item = service.owner.information.single;
      expect(item.directoryId, category.id);
      expect(item.tagIds, [tag.id]);
      expect(item.description, 'Reviewed public description');
      await capture('03-edited-category');
      await exchange('edited');
      await tap(find.byKey(const ValueKey('edit-information-description')));
      await tap(find.text('移除字段').first);
      await tap(find.byKey(const ValueKey('save-information')));
      expect(service.owner.information.single.fields, hasLength(2));
      await capture('04-delete-confirmation');
      await tap(find.text('取消').last);
      expect(service.owner.information.single.fields, hasLength(2));
      await tap(find.byKey(const ValueKey('save-information')));
      await tap(find.text('确认保存'));
      expect(service.owner.information.single.fields.single.id, note);
      await exchange('partial');
      await tap(find.text('回收站'));
      await tap(find.text('恢复信息'));
      await tap(find.text('确认恢复'));
      item = service.owner.information.single;
      final fresh = item.fields.firstWhere((f) => f.id != note).id;
      expect(fresh, isNot(original));
      await capture('05-restored');
      final regrant = await exchange('restored', {'freshField': fresh});
      service.owner.approve(regrant['requestId'] as String, [
        FieldRef(itemId, fresh),
      ]);
      await exchange('reapproved');
      await tap(find.text('×').last);
      await tap(find.text('修改历史 ↗'));
      await capture('06-revision-history');
      await tap(find.text('恢复为新版本').last);
      await tap(find.text('确认恢复为新版本'));
      item = service.owner.information.single;
      expect(
        item.fields.firstWhere((f) => f.id == fresh).value,
        'https://old.native.example',
      );
      expect(item.fields.any((f) => f.id == original), isFalse);
      expect(item.version, 6);
      expect(item.directoryId, child.id);
      expect(item.tagIds, isEmpty);
      await capture('07-revision-restored');
      await tap(find.text('×').last);
      await tap(find.byKey(const ValueKey('nav-4')));
      await tap(find.byKey(const ValueKey('settings-section-templates')));
      await tap(find.text('修改模板'));
      await tap(find.text('编辑说明'));
      expect(find.textContaining('保存模板不会修改已有信息'), findsOneWidget);
      await input('template-field-name-0', '新模板地址');
      await tap(find.text('保存模板'));
      expect(service.owner.templates.single.version, 2);
      expect(service.owner.templates.single.fields.first.name, '新模板地址');
      expect(
        service.owner.information.single.fields
            .firstWhere((f) => f.id == fresh)
            .name,
        '地址',
      );
      await capture('08-template-edited');
      await exchange('version-restored');
      final finalVersion = item.version;
      final finalDirectory = item.directoryId;
      final finalTags = List<String>.of(item.tagIds);
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
      item = service.owner.information.single;
      expect(item.id, itemId);
      expect(item.version, finalVersion);
      expect(item.directoryId, finalDirectory);
      expect(item.tagIds, finalTags);
      expect(
        item.fields.firstWhere((f) => f.id == fresh).value,
        'https://old.native.example',
      );
      expect(
        item.fields.firstWhere((f) => f.id == note).value,
        'controlled note',
      );
      expect(service.owner.templates.single.name, 'Mac 合成模板');
      expect(service.owner.templates.single.version, 2);
      expect(service.owner.templates.single.fields.first.name, '新模板地址');
      expect(item.fields.firstWhere((f) => f.id == fresh).name, '地址');
      expect(repository.grantHistory, hasLength(2));
      expect(repository.grantHistory.every((grant) => !grant.active), isTrue);
      expect(service.owner.directories, hasLength(2));
      expect(service.owner.tags.single.id, tag.id);
      expect(
        service.owner.recycleFacts
            .firstWhere((f) => f.kind == RecycleFactKind.restored)
            .restoredFieldIds[original],
        fresh,
      );
      expect(service.owner.importProposals, isEmpty);
      expect(service.owner.updateProposals, isEmpty);
      await mount();
      await tap(find.byKey(const ValueKey('nav-1')));
      expect(find.text('Mac 合成资料'), findsWidgets);
      await capture('09-reopened');
      await exchange('repository-reopened');
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'complete': true,
          'phases': step + 1,
          'itemId': itemId,
          'oldField': original,
          'restoredField': fresh,
          'remainingField': note,
          'finalVersion': finalVersion,
          'captures': captures,
          'scope':
              'Real native Flutter/SQLCipher; tester-driven UI; ephemeral key, fixture directory/tag creation and owner approvals; independent parent AOT CLI. No physical input, Keychain or system panels.',
        }),
        flush: true,
      );
      await exchange('complete');
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
