import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/ui.dart';
import 'package:info_desktop/desktop_scroll.dart';
import 'package:info_desktop/desktop_interaction_host.dart';

class CaptureRepository extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<InformationDraftReceipt> commitInformationDraft(
    InformationDraftChange change,
  ) async {
    if (fail) throw StateError('synthetic draft storage failure');
    return super.commitInformationDraft(change);
  }

  @override
  Future<void> commitRecycleChange({
    required String itemId,
    InformationItem? item,
    InformationRevision? previous,
    required List<RecycleEntry> entries,
    required List<RecycleFact> facts,
    DeleteProposal? proposal,
    InformationLifecycleReceipt? lifecycleReceipt,
    void Function()? validate,
  }) async {
    if (fail) throw StateError('synthetic failure');
    await super.commitRecycleChange(
      itemId: itemId,
      item: item,
      previous: previous,
      entries: entries,
      facts: facts,
      proposal: proposal,
      lifecycleReceipt: lifecycleReceipt,
      validate: validate,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'ProductSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))).load();
    await (FontLoader(
      'AppSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final f in {
      'SimSun': 'simsun.ttc',
      'Georgia': 'georgia.ttf',
      'Consolas': 'consola.ttf',
    }.entries) {
      await (FontLoader(f.key)..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '${Platform.environment['WINDIR']}/Fonts/${f.value}',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
    }
  });
  for (final scenario in [
    (
      name: 'purple-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.purple,
      scale: 1.0,
    ),
    (
      name: 'purple-1280',
      size: const Size(1280, 800),
      theme: DesktopColorTheme.purple,
      scale: 1.0,
    ),
    (
      name: 'mono-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.mono,
      scale: 1.0,
    ),
    (
      name: 'green-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.green,
      scale: 1.0,
    ),
    (
      name: 'blue-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.blue,
      scale: 1.0,
    ),
    (
      name: 'purple-long',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.purple,
      scale: 1.0,
    ),
    (
      name: 'purple-200',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.purple,
      scale: 2.0,
    ),
  ]) {
    testWidgets('library capture ${scenario.name}', (tester) async {
      debugDisableShadows = false;
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(() => debugDisableShadows = true);
      final repo = CaptureRepository();
      final service = InformationService(
        repository: repo,
        clock: () => DateTime(2026, 10, 17, 13, 40),
      );
      final owner = service.owner;
      final work = await owner.createDirectory('工作');
      final project = await owner.createDirectory('北辰项目', parentId: work.id);
      final services = await owner.createDirectory('服务', parentId: project.id);
      final info = await owner.createDirectory('项目资料', parentId: project.id);
      final test = await owner.createDirectory('测试环境', parentId: work.id);
      final other = await owner.createDirectory('其他项目', parentId: work.id);
      final personal = await owner.createDirectory('个人');
      final family = await owner.createDirectory('家庭');
      final tags = [
        await owner.createTag('开发'),
        await owner.createTag('自托管'),
        await owner.createTag('常用'),
      ];
      InformationItem? docs;
      for (final entry in <(String, String, String, List<FieldInput>)>[
        (
          '备份服务',
          '项目备份目录与执行时间',
          services.id,
          const [
            FieldInput('备份目录', '', '/backup/beichen'),
            FieldInput('执行时间', '', '每天02:00'),
          ],
        ),
        (
          '部署说明',
          '发布流程与环境切换约定',
          info.id,
          const [
            FieldInput('发布流程', '', '发布前检查测试环境', kind: FieldKind.textNote),
            FieldInput('环境约定', '', '先测试后生产', kind: FieldKind.textNote),
          ],
        ),
        (
          '监测服务',
          '服务运行状态与通知入口',
          services.id,
          const [
            FieldInput('访问地址', '', 'https://status.beichen.example'),
            FieldInput('维护人', '', '项目维护组'),
          ],
        ),
        (
          '接口服务',
          '业务接口入口与开发环境说明',
          services.id,
          const [
            FieldInput('访问地址', '', 'https://api.beichen.example'),
            FieldInput('接口版本', '', 'v2'),
          ],
        ),
        (
          '文档服务',
          '北辰项目的文档访问入口与部署配置',
          services.id,
          const [
            FieldInput('访问地址', '文档站的公开访问入口', 'https://docs.beichen.example'),
            FieldInput('部署目录', '服务器上的文档存放位置', '/srv/beichen/docs'),
          ],
        ),
        (
          '项目约定',
          '项目代号、日常协作与联系信息',
          info.id,
          const [
            FieldInput('项目代号', '', 'BEICHEN', kind: FieldKind.textNote),
            FieldInput(
              '联系邮箱',
              '',
              'owner@beichen.example',
              kind: FieldKind.textNote,
            ),
          ],
        ),
        (
          '测试服务器',
          '测试环境的连接信息',
          test.id,
          const [FieldInput('地址', '', 'test.example')],
        ),
        ('测试约定', '联调约定', test.id, const [FieldInput('时间', '', '工作日')]),
        (
          '归档入口',
          '归档服务',
          other.id,
          const [FieldInput('地址', '', 'https://archive.example')],
        ),
        ('个人介绍', '个人站点介绍', personal.id, const [FieldInput('介绍', '', '个人介绍')]),
        (
          '联系信息',
          '日常联系',
          personal.id,
          const [FieldInput('邮箱', '', 'hello@example')],
        ),
        (
          '家庭网络',
          '家庭路由入口',
          family.id,
          const [FieldInput('地址', '', 'https://router.example')],
        ),
      ]) {
        final item = await owner.createInformation(
          entry.$1,
          entry.$2,
          entry.$4,
          directoryId: entry.$3,
          tagIds: entry.$1 == '文档服务' ? [tags[1].id] : [],
        );
        if (entry.$1 == '文档服务') docs = item;
      }
      for (var i = 0; i < 8; i++) {
        final session = service.agent.openSession('合成待办$i');
        service.agent.request(session, '合成请求', [
          FieldRef(docs!.id, docs.fields.first.id),
        ]);
      }
      if (scenario.name == 'purple-long') {
        docs = await owner.editInformation(
          docs!.id,
          docs.version,
          name: docs.name,
          description: '这是较长的公开说明，用于验证信息详情的独立滚动。' * 20,
          directoryId: services.id,
          tagIds: [tags[1].id],
          changes: [
            for (var n = 0; n < 24; n++)
              FieldChange.add(
                FieldInput('Stress field $n', '公开说明$n', '长内容换行测试$n ' * 180),
              ),
          ],
        );
        for (var n = 0; n < 120; n++) {
          await owner.createInformation(
            'Archive ${n.toString().padLeft(3, '0')}',
            'Public',
            [const FieldInput('F', '', 'V')],
            directoryId: services.id,
          );
        }
      }
      const boundaryKey = ValueKey('library-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            theme: informationTheme(scenario.theme),
            scrollBehavior: const DesktopScrollBehavior(),
            builder: (_, child) => DesktopInteractionHost(child: child!),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: DesktopShell(
                service: service,
                port: 47125,
                index: 1,
                onSelected: (_) {},
                hasBackups: true,
                colorTheme: scenario.theme,
                onThemeChanged: (_) {},
                child: InformationLibrary(
                  owner: owner,
                  initialDirectoryId: project.id,
                  initialItemId: docs!.id,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      Future<void> capture(String suffix) async {
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory(
            Platform.environment['LIBRARY_CAPTURE_OUT'] ??
                '../../build/library-ux/flutter/library',
          );
          await output.create(recursive: true);
          await File(
            '${output.path}/${scenario.name}$suffix.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('');
      if (scenario.scale == 1 && scenario.name != 'purple-long') {
        await tester.tap(
          find.byKey(const ValueKey('edit-information-description')),
        );
        await tester.pumpAndSettle();
        await capture('-editor');
        if (scenario.name == 'purple-1440') {
          await tester.enterText(
            find.byKey(const ValueKey('item-name')),
            '文档服务修订',
          );
          repo.fail = true;
          await tester.tap(find.byKey(const ValueKey('save-information')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.textContaining('输入已保留'));
          await tester.pumpAndSettle();
          await capture('-failure');
          repo.fail = false;
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('放弃更改'));
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('new-directory')));
        await tester.pumpAndSettle();
        await capture('-taxonomy');
        await tester.tap(find.text('×'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全部信息').first);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('library-search')),
          '无匹配资料',
        );
        await tester.pumpAndSettle();
        await capture('-empty');
        if (scenario.name == 'purple-1440') {
          await tester.enterText(
            find.byKey(const ValueKey('library-search')),
            'x' * 2001,
          );
          await tester.pumpAndSettle();
          await capture('-query-failure');
          await tester.enterText(
            find.byKey(const ValueKey('library-search')),
            '',
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.byKey(ValueKey(docs.id)),
            220,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('library-list')),
                  matching: find.byType(Scrollable),
                )
                .last,
          );
          await tester.tap(find.byKey(ValueKey(docs.id)));
          await tester.pumpAndSettle();
          await tester.tap(find.text('修改历史 ↗'));
          await tester.pumpAndSettle();
          await capture('-history-empty');
          await tester.tap(find.text('×').last);
          await tester.pumpAndSettle();
          await owner.correctValue(
            FieldRef(docs.id, docs.fields.first.id),
            'https://corrected.beichen.example',
          );
          await tester.tap(find.text('修改历史 ↗'));
          await tester.pumpAndSettle();
          await capture('-history');
          await tester.tap(find.text('恢复为新版本'));
          await tester.pumpAndSettle();
          await capture('-revision-confirm');
          repo.fail = true;
          await tester.tap(find.text('确认恢复为新版本'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.textContaining('恢复失败'));
          await tester.pumpAndSettle();
          await capture('-revision-failure');
          repo.fail = false;
          await tester.tap(find.text('确认恢复为新版本'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('×').last);
          await tester.pumpAndSettle();
          var current = owner.information.firstWhere((i) => i.id == docs!.id);
          await owner.deleteInformation(
            current.id,
            current.version,
            fieldId: current.fields.first.id,
          );
          await tester.tap(find.text('回收站'));
          await tester.pumpAndSettle();
          await capture('-trash');
          await tester.tap(find.text('恢复信息'));
          await tester.pumpAndSettle();
          await capture('-recycle-confirm');
          repo.fail = true;
          await tester.tap(find.text('确认恢复'));
          await tester.pumpAndSettle();
          await capture('-recycle-failure');
          repo.fail = false;
          await tester.tap(find.text('恢复信息'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认恢复'));
          await tester.pumpAndSettle();
          await capture('-trash-empty');
          await tester.tap(find.text('×').last);
          await tester.pumpAndSettle();
        }
      }
      if (scenario.scale == 2) {
        await tester.drag(
          find.byType(SingleChildScrollView).last,
          const Offset(0, -1400),
        );
        await tester.pumpAndSettle();
        await capture('-last');
      }
      if (scenario.name == 'purple-long') {
        await tester.ensureVisible(find.text('Stress field 23'));
        await tester.pumpAndSettle();
        await capture('-last');
        final detailScroll = tester
            .widget<SingleChildScrollView>(
              find.descendant(
                of: find.byKey(const ValueKey('library-detail')),
                matching: find.byType(SingleChildScrollView),
              ),
            )
            .controller!;
        detailScroll.jumpTo(detailScroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('Agent 能看到什么？').hitTestable(), findsOneWidget);
        await capture('-bottom');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
      debugDisableShadows = true;
    });
  }
}
