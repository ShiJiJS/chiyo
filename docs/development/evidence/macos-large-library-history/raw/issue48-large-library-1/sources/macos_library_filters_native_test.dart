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
    'Mac native directory tags search pagination and reopen',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      const marker = String.fromEnvironment('MAC_QA_OWNER');
      expect(marker, matches(RegExp(r'^[a-f0-9]{32}$')));
      final root = await Directory.systemTemp.createTemp(
        'aim-mac-library-filters-ui-',
      );
      await File('${root.path}/.qa-owner').writeAsString(marker);
      debugPrint('MAC_LIBRARY_FILTERS_ROOT=${root.path}');
      final semantics = NativeSemanticsLifetime(tester);
      tester.testTextInput.register();
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
        tester.testTextInput.unregister();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
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

      Future<void> manager() => tap(find.text('目录与标签'));
      Future<void> closeManager() => tap(find.text('×').last);
      Future<void> createDirectory(String name, [String? parent]) async {
        await tap(find.text('添加目录'));
        await input('organization-name', name);
        if (parent != null) {
          await tap(find.byKey(const ValueKey('organization-parent')));
          await tap(find.text(parent).last);
        }
        await tap(find.text('保存').last);
      }

      Finder directoryEdit(String path) => find.descendant(
        of: find
            .ancestor(of: find.text(path).last, matching: find.byType(Row))
            .first,
        matching: find.text('编辑'),
      );
      void total(int count) =>
          expect(find.text('共 $count 条信息'), findsOneWidget);
      await mount();
      await tap(find.byKey(const ValueKey('nav-1')));
      await manager();
      await createDirectory('私人工作');
      await createDirectory('私人子目录', '私人工作');
      await createDirectory('私人归档');
      final parent = service.owner.directories.firstWhere(
        (d) => d.name == '私人工作',
      );
      final child = service.owner.directories.firstWhere(
        (d) => d.name == '私人子目录',
      );
      final archive = service.owner.directories.firstWhere(
        (d) => d.name == '私人归档',
      );
      await tap(find.text('新建标签'));
      await input('organization-name', '私人标签甲');
      await tap(find.text('保存').last);
      await tap(find.text('新建标签'));
      await input('organization-name', '私人标签乙');
      await tap(find.text('保存').last);
      final tagA = service.owner.tags.firstWhere((t) => t.name == '私人标签甲');
      final tagB = service.owner.tags.firstWhere((t) => t.name == '私人标签乙');
      await capture('01-created');
      // An invalid parent cycle must preserve both labels and item membership.
      await tap(directoryEdit('私人工作'));
      await tap(find.byKey(const ValueKey('organization-parent')));
      await tap(find.text('私人工作 / 私人子目录').last);
      await tap(find.text('保存').last);
      expect(find.textContaining('目录不能移动到自身下级'), findsOneWidget);
      expect(
        service.owner.directories.firstWhere((d) => d.id == parent.id).parentId,
        isNull,
      );
      await capture('02-cycle-rejected');
      await tap(find.text('取消').last);
      await closeManager();
      // Volume is fixture preparation; all label creation/editing above is UI.
      const large = bool.fromEnvironment('MAC_QA_LARGE');
      const itemCount = large ? 1000 : 125;
      final seedTime = Stopwatch()..start();
      final items = <InformationItem>[];
      for (var i = 0; i < itemCount; i++) {
        items.add(
          await service.owner.createInformation(
            '资料${i.toString().padLeft(3, '0')}',
            '公共说明 $i',
            [
              FieldInput(
                '字段',
                i == itemCount - 1 ? '唯一公开检索词' : '公共字段说明',
                'private-fixture-$i',
              ),
            ],
            directoryId: i < 50
                ? child.id
                : i < 75
                ? parent.id
                : i < 100
                ? archive.id
                : null,
            tagIds: [if (i.isEven) tagA.id, if (i % 3 == 0) tagB.id],
          ),
        );
      }
      seedTime.stop();
      // Remount to render the fixture data from the actual encrypted repository.
      await tester.pumpWidget(const SizedBox());
      await mount();
      await tap(find.byKey(const ValueKey('nav-1')));
      total(itemCount);
      final target = items.first;
      final grant = await exchange('request', {
        'itemId': target.id,
        'fieldId': target.fields.single.id,
        'parentId': parent.id,
        'childId': child.id,
        'archiveId': archive.id,
        'tagA': tagA.id,
        'tagB': tagB.id,
      });
      service.owner.approve(grant['requestId'] as String, [
        FieldRef(target.id, target.fields.single.id),
      ]);
      await exchange('approved');
      final pageCount = (itemCount / 50).ceil();
      expect(find.text('1 / $pageCount'), findsOneWidget);
      await tap(find.text('›'));
      expect(find.text('2 / $pageCount'), findsOneWidget);
      expect(
        find.byKey(ValueKey('information-${items[50].id}')),
        findsOneWidget,
      );
      await tap(find.text('›'));
      expect(find.text('3 / $pageCount'), findsOneWidget);
      expect(
        find.byKey(ValueKey('information-${items[100].id}')),
        findsOneWidget,
      );
      for (var page = 4; page <= pageCount; page++) {
        await tap(find.text('›'));
        expect(find.text('$page / $pageCount'), findsOneWidget);
        expect(
          find.byKey(ValueKey('information-${items[(page - 1) * 50].id}')),
          findsOneWidget,
        );
      }
      final list = find.byKey(const ValueKey('library-item-scroll'));
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(items.last.id)),
        400,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      await tap(find.byKey(ValueKey(items.last.id)));
      expect(
        find.byKey(ValueKey('information-${items.last.id}')),
        findsOneWidget,
      );
      await capture('03-last-page');
      await input('library-search', '唯一公开检索词');
      total(1);
      expect(find.text('1 / 1'), findsOneWidget);
      expect(
        find.byKey(ValueKey('information-${items.last.id}')),
        findsOneWidget,
      );
      await capture('04-public-field-search');
      for (final query in [
        'private-fixture-${itemCount - 1}',
        '私人标签甲',
        '私人工作',
      ]) {
        await input('library-search', query);
        total(0);
        expect(find.text('请选择一条信息'), findsOneWidget);
      }
      await input('library-search', 'x' * 2001);
      expect(find.textContaining('信息库查询失败'), findsOneWidget);
      expect(find.text('请选择一条信息'), findsOneWidget);
      await capture('05-invalid-query');
      await tap(find.text('查看全部'));
      total(itemCount);
      await tap(find.byKey(ValueKey('directory-${parent.id}')));
      total(75);
      await tap(find.text('75 条信息 · 包含下级目录'));
      total(25);
      await tap(find.text('25 条信息'));
      total(75);
      await tap(find.byKey(ValueKey('library-tag-${tagA.id}')));
      total(38);
      await tap(find.byKey(ValueKey('library-tag-${tagB.id}')));
      total(13);
      await capture('06-combined-filters');
      await exchange('filtered');
      await tap(find.text('全部信息').first);
      total(itemCount);
      await manager();
      await tap(directoryEdit('私人工作 / 私人子目录'));
      await input('organization-name', '私人移动后');
      await tap(find.byKey(const ValueKey('organization-parent')));
      await tap(find.text('私人归档').last);
      await tap(find.text('保存').last);
      final tagTile = find.ancestor(
        of: find.text('私人标签甲').last,
        matching: find.byType(ListTile),
      );
      await tap(find.descendant(of: tagTile, matching: find.byTooltip('编辑标签')));
      await input('organization-name', '私人改名甲');
      await tap(find.text('保存').last);
      await capture('07-moved-renamed');
      await closeManager();
      expect(
        service.owner.directories.firstWhere((d) => d.id == child.id).parentId,
        archive.id,
      );
      expect(
        service.owner.tags.firstWhere((t) => t.id == tagA.id).name,
        '私人改名甲',
      );
      await tap(find.byKey(ValueKey('directory-${parent.id}')));
      total(25);
      await tap(find.byKey(ValueKey('directory-${archive.id}')));
      total(75);
      await tap(find.byKey(ValueKey('library-tag-${tagA.id}')));
      total(37);
      await capture('08-moved-filter');
      await exchange('moved');
      for (final old in items) {
        final actual = service.owner.information.firstWhere(
          (i) => i.id == old.id,
        );
        expect(actual.version, old.version);
        expect(actual.directoryId, old.directoryId);
        expect(actual.tagIds, old.tagIds);
        expect(actual.fields.single.id, old.fields.single.id);
        expect(actual.fields.single.value, old.fields.single.value);
      }
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
      await mount();
      await tap(find.byKey(const ValueKey('nav-1')));
      total(itemCount);
      await tap(find.byKey(ValueKey('directory-${archive.id}')));
      total(75);
      await tap(find.byKey(ValueKey('library-tag-${tagA.id}')));
      total(37);
      for (final old in items) {
        final actual = service.owner.information.firstWhere(
          (i) => i.id == old.id,
        );
        expect(actual.version, old.version);
        expect(actual.fields.single.value, old.fields.single.value);
        expect(actual.fields.single.id, old.fields.single.id);
      }
      await capture('09-reopened');
      await exchange('repository-reopened');
      // Label volume is controlled fixture setup. Test the complete native app
      // at both text scales; this does not prove physical scroll/keyboard input.
      for (var i = 0; i < (large ? 126 : 50); i++) {
        await service.owner.createTag('资料分类标签 $i');
      }
      if (large) {
        for (var i = 0; i < 29; i++) {
          await service.owner.createDirectory('规模验收目录 $i');
        }
      }
      final lastTag = service.owner.tags.last;
      final lastDirectory = service.owner.directories.last;
      for (final theme in DesktopColorTheme.values) {
        for (final scale in [1.0, 2.0]) {
          await tester.pumpWidget(const SizedBox());
          await service.owner.setColorTheme(theme);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await mount();
          tester.view.physicalSize = const Size(1280, 800);
          await tester.pumpAndSettle();
          await tap(find.byKey(const ValueKey('nav-1')));
          total(itemCount);
          await capture('10-initial-${theme.name}-${(scale * 100).toInt()}');
          await tap(find.byKey(ValueKey('library-tag-${lastTag.id}')));
          total(0);
          expect(find.text('请选择一条信息'), findsOneWidget);
          await capture('10-tags-${theme.name}-${(scale * 100).toInt()}');
          await tap(find.text('全部信息').first);
          total(itemCount);
          if (large) {
            await tap(find.byKey(ValueKey('directory-${lastDirectory.id}')));
            total(0);
            await capture(
              '11-directory-${theme.name}-${(scale * 100).toInt()}',
            );
            await tap(find.text('全部信息').first);
            total(itemCount);
          }
          await tap(find.text('›'));
          expect(find.text('2 / $pageCount'), findsOneWidget);
          await capture('11-pagination-${theme.name}-${(scale * 100).toInt()}');
        }
      }

      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'complete': true,
          'items': itemCount,
          'pagesTraversed': pageCount,
          'directories': service.owner.directories.length,
          'tags': service.owner.tags.length,
          'seedWallMilliseconds': seedTime.elapsedMilliseconds,
          'captures': captures,
          'scope':
              'Native Flutter SQLCipher and independent AOT CLI; tester input registered; $itemCount fixture items and owner grant approval; no physical IME, Keychain or process restart.',
        }),
      );
      await exchange('complete');
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
