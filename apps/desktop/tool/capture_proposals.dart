import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/import_proposals.dart';
import 'package:info_desktop/ui.dart';

class CaptureRepository extends MemoryInformationRepository {
  bool failImport = false;
  @override
  Future<void> commitInformationAdmission(
    List<ImportProposal> proposals,
    List<InformationItem> items, {
    required String decisionProposalId,
    required bool confirm,
    ProposalKind decisionKind = ProposalKind.addition,
    List<InformationUpdateAdmission> updates = const [],
    List<ManagedCredential> credentialRecords = const [],
    List<CredentialMaterial> credentialMaterials = const [],
    List<InformationImportFilePromotion> filePromotions = const [],
    List<ImportReceipt> decisionRecords = const [],
    List<String> awaitingKeys = const [],
    List<InformationDirectory> newDirectories = const [],
    List<InformationTag> newTags = const [],
  }) async {
    if (failImport) throw StateError('Synthetic confirmation failure');
    await super.commitInformationAdmission(
      proposals,
      items,
      decisionProposalId: decisionProposalId,
      confirm: confirm,
      decisionKind: decisionKind,
      updates: updates,
      credentialRecords: credentialRecords,
      credentialMaterials: credentialMaterials,
      filePromotions: filePromotions,
      decisionRecords: decisionRecords,
      awaitingKeys: awaitingKeys,
      newDirectories: newDirectories,
      newTags: newTags,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in ['ProductSans', 'AppSans']) {
      await (FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf')))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final font in {
      'SimSun': 'simsun.ttc',
      'Georgia': 'georgia.ttf',
      'Consolas': 'consola.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '${Platform.environment['WINDIR']}/Fonts/${font.value}',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
    }
  });
  for (final width in [1440, 1280]) {
    testWidgets('proposal representative $width', (tester) async {
      tester.view.physicalSize = Size(
        width.toDouble(),
        width == 1440 ? 900 : 800,
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDisableShadows = false;
      var now = DateTime(2026, 10, 14, 14, 10);
      final repository = CaptureRepository();
      var textScale = 1.0;
      final service = InformationService(
        repository: repository,
        clock: () => now,
      );
      final owner = service.owner;
      final work = await owner.createDirectory('工作');
      final project = await owner.createDirectory('北辰项目', parentId: work.id);
      final services = await owner.createDirectory('服务', parentId: project.id);
      final materials = await owner.createDirectory(
        '项目资料',
        parentId: project.id,
      );
      final tags = [await owner.createTag('自托管'), await owner.createTag('运维')];
      final docs = await owner.createInformation(
        '文档服务',
        '文档站入口',
        [
          const FieldInput('访问地址', '', 'https://docs.beichen.example'),
          const FieldInput('部署目录', '', '/srv/beichen/docs'),
        ],
        directoryId: project.id,
        tagIds: [tags.first.id],
      );
      final rejected = await service.agent.submitUpdate(
        service.agent.openSession('更新归档服务器'),
        UpdateInput(docs.id, 1, [
          FieldChange.correct(docs.fields.first.id, 'rejected.example'),
        ]),
      );
      await owner.rejectUpdate(rejected, 1);
      now = DateTime(2026, 10, 16, 14, 25);
      final oldImport = await service.agent.submitImport(
        service.agent.openSession('录入北辰项目服务信息'),
        [
          ImportItemInput('旧服务', '已入库', [
            const FieldInput('入口', '', 'old.example'),
          ]),
          ImportItemInput('旧备份', '已入库', [const FieldInput('保留天数', '', '30 天')]),
        ],
        agentName: 'Claude Code',
      );
      await owner.confirmImport(oldImport, 1, owner.importProposals.last.items);
      final organized = [
        docs,
        for (final name in ['接口服务', '备份服务', '监测服务'])
          await owner.createInformation(name, '', [
            const FieldInput('入口', '', 'organization.example'),
          ], directoryId: project.id),
      ];
      final organizeSession = service.agent.openSession('整理项目服务资料');
      final organization = await service.agent.requestOrganization(
        organizeSession,
        '已按照你批准的整理范围调整分类与标签。',
        organized.map((item) => item.id).toList(),
        agentName: 'Codex',
      );
      await owner.approveOrganization(
        organization.id,
        organized.map((item) => item.id).toList(),
      );
      await service.agent.submitOrganization(organizeSession, organization.id, [
        for (final item in organized)
          OrganizationChange(
            itemId: item.id,
            baseVersion: 1,
            directoryId: services.id,
            tagIds: [tags.first.id],
          ),
      ]);
      now = DateTime(2026, 10, 17, 10, 24);
      final archive = await owner.createInformation('归档项目入口', '旧记录', [
        const FieldInput('访问地址', '', 'https://archive.example'),
      ]);
      final deletion = await service.agent.submitDelete(
        service.agent.openSession('移除旧项目访问入口'),
        archive.id,
        1,
      );
      now = DateTime(2026, 10, 17, 11, 32);
      final testDirectory = await owner.createDirectory(
        '测试环境',
        parentId: work.id,
      );
      final testServer = await owner.createInformation('测试服务器', '', [
        const FieldInput('连接端口', '', '22'),
      ], directoryId: testDirectory.id);
      await owner.correctValue(
        FieldRef(testServer.id, testServer.fields.first.id),
        '2200',
      );
      await owner.correctValue(
        FieldRef(testServer.id, testServer.fields.first.id),
        '2201',
      );
      final conflict = await service.agent.submitUpdate(
        service.agent.openSession('调整测试服务器连接配置'),
        UpdateInput(testServer.id, 3, [
          FieldChange.correct(testServer.fields.first.id, '2200'),
        ]),
      );
      await owner.correctValue(
        FieldRef(testServer.id, testServer.fields.first.id),
        '2222',
      );
      now = DateTime(2026, 10, 17, 13, 46);
      final modification = await service.agent.submitUpdate(
        service.agent.openSession('更新文档服务访问地址'),
        UpdateInput(docs.id, 2, [
          FieldChange.correct(
            docs.fields.first.id,
            'https://guide.beichen.example',
          ),
          FieldChange.correct(docs.fields.last.id, '/srv/beichen/guide'),
        ]),
      );
      now = DateTime(2026, 10, 17, 14, 18);
      final addition = await service.agent.submitImport(
        service.agent.openSession('补全北辰项目服务信息'),
        [
          ImportItemInput(
            '监测服务',
            '',
            [
              const FieldInput('访问地址', '', 'https://status.beichen.example'),
              const FieldInput('维护人', '', '项目维护组'),
            ],
            directoryId: services.id,
            tagIds: [tags.first.id],
          ),
          ImportItemInput(
            '备份安排',
            '',
            [
              const FieldInput('执行时间', '', '每天 02:00'),
              const FieldInput('保留天数', '', '30 天'),
            ],
            directoryId: materials.id,
            tagIds: [tags.last.id],
          ),
        ],
        agentName: 'Codex',
        purpose: '整理部署过程中确认的服务入口与备份安排，作为后续维护时的参考。',
      );
      expect(
        owner.queryProposals(search: conflict).entries.single.status,
        ProposalStatus.conflicted,
      );
      for (var n = 0; n < 8; n++) {
        service.agent.request(service.agent.openSession('合成申请$n'), '合成请求', [
          FieldRef(docs.id, docs.fields.first.id),
        ]);
      }
      const boundaryKey = ValueKey('proposal-capture');
      Widget workspace(String id, {String? pageKey}) => RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: informationTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: DesktopShell(
            service: service,
            port: 0,
            index: 2,
            onSelected: (_) {},
            hasBackups: false,
            onThemeChanged: (_) {},
            child: ImportProposalsPage(
              key: ValueKey(pageKey ?? 'ordinary-proposals'),
              owner: owner,
              initialProposalId: id,
            ),
          ),
        ),
      );
      await tester.pumpWidget(workspace(addition));
      await tester.pumpAndSettle();
      Future<void> capture(String state) async {
        expect(tester.takeException(), isNull);
        if (state == 'new') {
          final rectangles = <String, Object?>{};
          for (final value in [
            '录入提案',
            '将要入库的内容',
            '监测服务',
            'https://status.beichen.example',
            '项目维护组',
            '备份安排',
          ]) {
            final finder = find.text(value);
            if (finder.evaluate().length == 1) {
              final rect = tester.getRect(finder);
              rectangles[value] = [
                rect.left,
                rect.top,
                rect.width,
                rect.height,
              ];
            }
          }
          for (final id in [addition, modification, conflict, deletion]) {
            final rect = tester.getRect(
              find.byKey(ValueKey('proposal-entry-$id')),
            );
            rectangles[id] = [rect.left, rect.top, rect.width, rect.height];
          }
          await tester.runAsync(() async {
            await File(
              '../../docs/development/evidence/25-proposals/fidelity/geometry-$width-new.json',
            ).writeAsString(
              '${const JsonEncoder.withIndent('  ').convert(rectangles)}\n',
            );
          });
        }
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory(
            '../../docs/development/evidence/25-proposals/fidelity',
          );
          await directory.create(recursive: true);
          await File(
            '${directory.path}/purple-$width-$state.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> select(String id) =>
          tap(find.byKey(ValueKey('proposal-entry-$id')));

      await capture('new');
      await tester.tap(find.byKey(const ValueKey('edit-import-0')));
      await tester.pumpAndSettle();
      await capture('editor');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tester.pumpAndSettle();
      await capture('confirm');
      await tap(find.text('返回核对'));
      await select(modification);
      await capture('diff');
      await tap(find.byKey(const ValueKey('edit-update')));
      await capture('update-editor');
      await tap(find.text('取消'));
      await select(conflict);
      await capture('conflict');
      await select(deletion);
      await capture('delete');
      await tap(find.byKey(const ValueKey('proposal-filter-handled')));
      await select(organization.id);
      await capture('organization');
      await select(oldImport);
      await capture('confirmed');
      await tap(find.text('按信息身份查看当前内容 →'));
      await capture('current');
      await tap(find.text('×').last);
      final old = owner.information.firstWhere((item) => item.name == '旧服务');
      await owner.correctValue(
        FieldRef(old.id, old.fields.first.id),
        'current.example',
      );
      await tap(find.text('按信息身份查看当前内容 →'));
      await capture('current-updated');
      await tap(find.text('×').last);
      await owner.deleteInformation(old.id, 2);
      await tap(find.text('按信息身份查看当前内容 →'));
      await capture('current-missing');
      await tap(find.text('×').last);
      await tap(find.byKey(const ValueKey('proposal-filter-pending')));
      await select(addition);
      repository.failImport = true;
      await tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await capture('save-failed');
      await tap(find.text('返回核对'));
      repository.failImport = false;
      await tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await capture('confirmed-new');
      await tester.enterText(
        find.byKey(const ValueKey('proposal-search')),
        'no matching proposal',
      );
      await tester.pumpAndSettle();
      await capture('no-results');
      textScale = 2;
      await tester.pumpWidget(workspace(modification, pageKey: 'large-text'));
      await tester.pumpAndSettle();
      await capture('200-first');
      final documentScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('proposal-document')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      documentScroll.position.jumpTo(documentScroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await capture('200-bottom');
      textScale = 1;
      now = DateTime(2026, 10, 17, 14, 30);
      final longBatch = await service.agent.submitImport(
        service.agent.openSession('长批次核对${' · 项目服务' * 10}'),
        [
          for (var n = 0; n < 20; n++)
            ImportItemInput(
              '第 $n 条${'长名称中文' * 14}',
              '长批次公开说明',
              [
                for (var field = 0; field < 10; field++)
                  FieldInput(
                    '字段 $field ${'长字段名称' * 8}',
                    '',
                    'https://docs.example/project/$n/$field\n${'中文长内容测试与 ASCII code_path /srv/project\n' * 4}',
                  ),
              ],
              directoryId: services.id,
              tagIds: tags.map((tag) => tag.id),
            ),
        ],
        agentName: 'Codex',
        purpose: '完整核对 20 条信息与 200 个字段，包含中文、路径和换行。',
      );
      await tester.pumpWidget(workspace(longBatch, pageKey: 'long-batch'));
      await tester.pumpAndSettle();
      await capture('long-first');
      final longScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('proposal-document')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      longScroll.position.jumpTo(longScroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await capture('long-bottom');
      final noOpSession = service.agent.openSession('整理项目服务资料 · 无改动');
      final noOp = await service.agent.requestOrganization(
        noOpSession,
        '核对目录与标签，无需更改。',
        [docs.id],
        agentName: 'Codex',
      );
      await owner.approveOrganization(noOp.id, [docs.id]);
      await service.agent.submitOrganization(noOpSession, noOp.id, []);
      await tester.pumpWidget(workspace(noOp.id, pageKey: 'organization-noop'));
      await tester.pumpAndSettle();
      await capture('organization-noop');
      final changedSession = service.agent.openSession('整理项目服务资料 · 冲突');
      final changed = await service.agent.requestOrganization(
        changedSession,
        '调整目录与标签。',
        [docs.id],
        agentName: 'Codex',
      );
      await owner.approveOrganization(changed.id, [docs.id]);
      await owner.correctValue(
        FieldRef(docs.id, docs.fields.first.id),
        'https://current.docs.example',
      );
      await expectLater(
        service.agent.submitOrganization(changedSession, changed.id, [
          OrganizationChange(
            itemId: docs.id,
            baseVersion: 2,
            directoryId: services.id,
          ),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      await tester.pumpWidget(
        workspace(changed.id, pageKey: 'organization-conflict'),
      );
      await tester.pumpAndSettle();
      await capture('organization-conflict');
      final revokedSession = service.agent.openSession('整理项目服务资料 · 撤销');
      final revoked = await service.agent.requestOrganization(
        revokedSession,
        '调整目录与标签。',
        [docs.id],
        agentName: 'Codex',
      );
      await owner.approveOrganization(revoked.id, [docs.id]);
      await owner.cancelOrganization(revoked.id);
      await tester.pumpWidget(
        workspace(revoked.id, pageKey: 'organization-revoked'),
      );
      await tester.pumpAndSettle();
      await capture('organization-revoked');
      await tester.runAsync(service.close);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await capture('offline');
      await tester.pumpWidget(const SizedBox());
      debugDisableShadows = true;
    });
  }
}
