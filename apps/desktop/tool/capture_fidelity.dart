import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

class _FidelityRepository extends MemoryInformationRepository {
  bool failHistory = false;
  @override
  Future<void> saveGrantHistory(GrantHistory history) async {
    if (failHistory) throw StateError('synthetic audit failure');
    await super.saveGrantHistory(history);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'ProductSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))).load();
    await (FontLoader('AppSans')
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Medium.otf')))
        .load();
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
    ),
    (
      name: 'green-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.green,
    ),
    (
      name: 'purple-1280',
      size: const Size(1280, 800),
      theme: DesktopColorTheme.purple,
    ),
    (
      name: 'mono-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.mono,
    ),
  ]) {
    testWidgets('fidelity ${scenario.name}', (tester) async {
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime(2026, 10, 17, 14, 0);
      final repository = _FidelityRepository();
      final service = InformationService(
        repository: repository,
        clock: () => now,
      );
      final work = await service.owner.createDirectory('工作');
      final project = await service.owner.createDirectory(
        '北辰项目',
        parentId: work.id,
      );
      final services = await service.owner.createDirectory(
        '服务',
        parentId: project.id,
      );
      final documents = await service.owner.createDirectory(
        '项目资料',
        parentId: project.id,
      );
      final docs = await service.owner.createInformation('文档服务', '', const [
        FieldInput('访问地址', '', 'https://docs.beichen.example'),
        FieldInput('部署目录', '', '/srv/beichen/docs'),
      ]);
      final info = await service.owner.createInformation('项目约定', '', const [
        FieldInput('项目代号', '', 'BEICHEN'),
        FieldInput('联系人邮箱', '', 'owner@beichen.example'),
      ]);
      await service.owner.organizeInformation(
        docs.id,
        directoryId: services.id,
      );
      await service.owner.organizeInformation(
        info.id,
        directoryId: documents.id,
      );
      // Unrequested synthetic catalog mirrors the prototype's scope-picker density.
      for (final catalog in <(String, List<FieldInput>)>[
        (
          '接口服务',
          const [
            FieldInput('访问地址', '', 'https://api.beichen.example'),
            FieldInput('接口版本', '', 'v2'),
          ],
        ),
        (
          '备份服务',
          const [
            FieldInput('备份目录', '', '/backup/beichen'),
            FieldInput('执行时间', '', '每天02:00'),
          ],
        ),
        (
          '部署说明',
          const [
            FieldInput('发布分支', '', 'release'),
            FieldInput('发布约定', '', '发布前先检查测试环境'),
          ],
        ),
        (
          '监测服务',
          const [
            FieldInput('访问地址', '', 'https://status.beichen.example'),
            FieldInput('维护人', '', '项目维护组'),
          ],
        ),
        (
          '测试服务器',
          const [
            FieldInput('服务器地址', '', 'test.beichen.example'),
            FieldInput('连接端口', '', '2222'),
            FieldInput('连接用户', '', 'developer'),
          ],
        ),
        ('测试约定', const [FieldInput('联调时间', '', '工作日14:00–18:00')]),
        ('归档项目入口', const [FieldInput('访问地址', '', 'https://archive.example')]),
        (
          '个人介绍',
          const [
            FieldInput('显示名称', '', '林予安'),
            FieldInput('一句话介绍', '', '记录开发与日常的个人站点'),
          ],
        ),
        ('联系信息', const [FieldInput('联系邮箱', '', 'hello@personal.example')]),
        ('家庭网络', const [FieldInput('管理入口', '', 'https://router.home.example')]),
      ]) {
        await service.owner.createInformation(
          catalog.$1,
          '仅用于原型对照的合成信息',
          catalog.$2,
        );
      }
      await service.owner.setRequestLifetime(const Duration(minutes: 15));
      final fields = [
        for (final i in [docs, info])
          for (final f in i.fields) FieldRef(i.id, f.id),
      ];
      String? selected;
      const titles = [
        '更新项目访问入口',
        '整理常用联系资料',
        '核对备份任务配置',
        '补全个人站点介绍',
        '部署北辰文档站',
        '检查备份任务',
        '同步项目配置',
        '部署北辰服务',
      ];
      for (var i = 0; i < 27; i++) {
        now = DateTime(2026, 10, 17, 14, 5 + i);
        final session = service.agent.openSession(
          i < 19 ? '已处理申请 $i' : titles[i - 19],
        );
        final r = service.agent.request(
          session,
          i == 23 ? '检查文档服务的部署配置，确认项目代号与访问入口，并更新部署说明。' : '核对项目资料与部署配置。',
          fields,
        );
        if (i < 19) service.owner.deny(r.id);
        if (i == 23) selected = r.id;
      }
      now = DateTime(2026, 10, 17, 14, 31);
      await service.owner.setColorTheme(scenario.theme);
      const boundaryKey = ValueKey('capture-boundary');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: InformationApp(service: service, port: 47125),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('request-$selected')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('approve-selection')).hitTestable(),
        findsOneWidget,
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      Future<void> capture(String suffix) async {
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory(
            '../../docs/development/evidence/23-workspace/fidelity',
          );
          await output.create(recursive: true);
          await File(
            '${output.path}/${scenario.name}$suffix.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('');
      if (scenario.name == 'purple-1440' || scenario.name == 'mono-1440') {
        await tester.tap(find.text('调整提供范围 / 补选其他信息'));
        await tester.pumpAndSettle();
        await capture('-scope');
        await tester.tap(find.byKey(const ValueKey('scope-apply')));
        await tester.pumpAndSettle();
        now = now.add(const Duration(seconds: 1));
        final organizer = service.agent.openSession('整理项目服务资料');
        final task = await service.agent.requestOrganization(
          organizer,
          '按服务用途整理项目资料的目录和标签。',
          [docs.id, info.id],
          agentName: 'Codex',
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('request-${task.id}')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey('organization-lifetime-${task.id}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('15 分钟').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('request-$selected')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('request-${task.id}')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButton<int>>(
                find.byKey(ValueKey('organization-lifetime-${task.id}')),
              )
              .value,
          15,
        );
        await capture('-organization');
        await tester.tap(find.text('批准整理范围'));
        await tester.pumpAndSettle();
        expect(
          service.agent.organizationStatus(organizer, task.id)['status'],
          'active',
        );
        await capture('-organization-active');
        await service.agent.submitOrganization(organizer, task.id, []);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        await capture('-organization-complete');
        await tester.tap(find.byKey(ValueKey('request-$selected')));
        await tester.pumpAndSettle();
        repository.failHistory = true;
        await tester.tap(find.byKey(const ValueKey('approve-selection')));
        await tester.pumpAndSettle();
        expect(service.owner.auditStorageUnavailable, isTrue);
        await capture('-audit-failure');
        repository.failHistory = false;
        await tester.tap(find.text('重试保存记录'));
        await tester.pumpAndSettle();
        await capture('-handled');
        await tester.enterText(
          find.byKey(const ValueKey('inbox-search')),
          '无匹配的合成条件',
        );
        await tester.pumpAndSettle();
        await capture('-empty');
        await tester.enterText(find.byKey(const ValueKey('inbox-search')), '');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('request-$selected')));
        await tester.pumpAndSettle();
        await tester.runAsync(service.close);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        await capture('-offline');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
      debugDisableShadows = true;
    });
  }
}
