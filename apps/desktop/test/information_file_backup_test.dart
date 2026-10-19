import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/information_attachment_capacity.dart';
import 'package:info_desktop/ui.dart';
import 'package:info_desktop/settings.dart';
import 'support/information_attachment_fixture.dart';

class _UsageRepository extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<InformationAttachmentUsage> informationAttachmentUsage() {
    if (fail) throw StateError('synthetic accounting failure');
    return super.informationAttachmentUsage();
  }
}

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

class _Files extends BackupFilePicker {
  const _Files(this.root);
  final String root;
  @override
  Future<String?> recoveryKeyOutput() async => null;
  @override
  Future<String?> backupOutput() async => '$root/files.aimbackup';
  @override
  Future<String?> backupInput() async => '$root/files.aimbackup';
  @override
  Future<String?> recoveryKeyInput() async => '$root/recovery.txt';
}

void main({
  Widget Function(Widget app)? wrapApp,
  Future<void> Function(WidgetTester tester, String state)? capture,
  DesktopColorTheme theme = DesktopColorTheme.purple,
  Size viewport = const Size(1280, 800),
}) {
  Future<void> mount(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    final app = MaterialApp(
      debugShowCheckedModeBanner: false,
      key: UniqueKey(),
      theme: informationTheme(theme),
      home: Scaffold(body: body),
    );
    await tester.pumpWidget(wrapApp?.call(app) ?? app);
  }

  Future<void> shown(WidgetTester tester, Finder target) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    do {
      await tester.pump(const Duration(milliseconds: 50));
      if (target.evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.text('正在刷新…').evaluate().isEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    } while (DateTime.now().isBefore(deadline));
    expect(target, findsWidgets);
  }

  testWidgets(
    'capacity retains the last known value on failure and refreshes stages and held copies without names or paths',
    (tester) async {
      await tester.runAsync(() async {
        final repo = _UsageRepository();
        final f = await AttachmentUiFixture.create(repository: repo);
        try {
          final draft = await f.owner.beginInformationFileDraft();
          await f.owner.stageInformationFile(
            draft,
            '${f.root.path}/fictional-resume.pdf',
          );
          final session = f.service.agent.openSession('领取文件');
          final ref = FieldRef(f.item.id, f.item.fields.last.id);
          final request = f.service.agent.request(session, '读取简历', [ref]);
          f.owner.approve(request.id, [ref]);
          await f.owner.retryAuditStorage();
          await f.fetch(session, request.id, 'capacity-copy');
          await mount(tester, InformationAttachmentCapacity(owner: f.owner));
          await shown(tester, find.textContaining('原件与草稿 6 B'));
          expect(find.textContaining('未保存草稿 1 份'), findsOneWidget);
          expect(find.textContaining('1 / 32 份'), findsOneWidget);
          expect(find.textContaining('fictional-resume.pdf'), findsNothing);
          expect(find.textContaining('synthetic-private-path'), findsNothing);
          await capture?.call(tester, 'capacity-current');
          repo.fail = true;
          await mount(tester, InformationAttachmentCapacity(owner: f.owner));
          await shown(tester, find.textContaining('尚无可用的用量结果'));
          expect(find.textContaining('原件与草稿 6 B'), findsNothing);
          await capture?.call(tester, 'capacity-initial-failure');
          repo.fail = false;
          await tester.tap(
            find.byKey(const ValueKey('refresh-attachment-usage')),
          );
          await shown(tester, find.textContaining('原件与草稿 6 B'));
          repo.fail = true;
          await tester.tap(
            find.byKey(const ValueKey('refresh-attachment-usage')),
          );
          await shown(tester, find.text('用量未更新'));
          expect(find.textContaining('原件与草稿 6 B'), findsOneWidget);
          await capture?.call(tester, 'capacity-failed-refresh');
          await f.owner.releaseInformationFileDraft(draft);
          f.owner.revoke(request.id);
          await f.owner.retryAuditStorage();
          await f.owner.reconcileInformationFileDeliveries();
          repo.fail = false;
          await tester.tap(
            find.byKey(const ValueKey('refresh-attachment-usage')),
          );
          await shown(tester, find.textContaining('原件与草稿 3 B'));
          expect(find.textContaining('未保存草稿 0 份'), findsOneWidget);
          expect(find.textContaining('0 / 32 份'), findsOneWidget);
          expect(find.text('用量未更新'), findsNothing);
          await capture?.call(tester, 'capacity-refreshed');
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.close();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      });
    },
  );

  testWidgets(
    'SQLCipher backup flow reports and restores exact current and retained originals without grants, stages or live copies',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'attachment-backup-ui-',
        );
        final source = await EncryptedInformationRepository.open(
          '${root.path}/source',
          _Keys(),
        );
        final target = await EncryptedInformationRepository.open(
          '${root.path}/target',
          _Keys(),
        );
        final driver = MemoryInformationDeliveries();
        final sourceService = InformationService(
          repository: source,
          informationDeliveryFiles: driver,
        );
        final targetService = InformationService(repository: target);
        InformationItem? current;
        Future<InformationItem> save(List<int> bytes) async {
          final path = '${root.path}/fictional-resume.pdf';
          await File(path).writeAsBytes(bytes);
          final draft = await sourceService.owner.beginInformationFileDraft();
          final stage = await sourceService.owner.stageInformationFile(
            draft,
            path,
          );
          final item = await sourceService.owner.commitInformationDraft(
            draft,
            'save',
            InformationDraftInput(
              name: '求职资料',
              description: '',
              itemId: current?.id,
              baseVersion: current?.version,
              fields: [
                InformationDraftField.stagedFile(
                  '简历',
                  '',
                  stage.id,
                  fieldId: current?.fields.single.id,
                ),
              ],
            ),
          );
          await sourceService.owner.releaseInformationFileDraft(draft);
          current = item;
          return item;
        }

        try {
          final first = await save([0, 255, 7]);
          final session = sourceService.agent.openSession('读取旧版本');
          final ref = FieldRef(first.id, first.fields.single.id);
          final request = sourceService.agent.request(session, '读取简历', [ref]);
          sourceService.owner.approve(request.id, [ref]);
          await sourceService.owner.retryAuditStorage();
          await sourceService.agent.fetchInformationFile(
            session,
            InformationFileFetchInput.fromJson({
              'protocolVersion': 2,
              'command': 'file-fetch',
              'requestId': request.id,
              'itemId': ref.itemId,
              'fieldId': ref.fieldId,
              'operationId': 'old-copy',
            }),
          );
          final second = await save([1, 2, 3, 4]);
          final pending = await sourceService.owner.beginInformationFileDraft();
          await sourceService.owner.stageInformationFile(
            pending,
            '${root.path}/fictional-resume.pdf',
          );
          await source.backups.enable();
          await source.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
          final files = _Files(root.path);
          if (capture != null) {
            await mount(
              tester,
              SettingsPage(
                owner: sourceService.owner,
                backups: source.backups,
                files: files,
                initialSection: SettingsSection.backups,
              ),
            );
            await shown(tester, find.textContaining('原件与草稿'));
            await capture(tester, 'settings-capacity');
          }
          await mount(
            tester,
            BackupFlowDialog(
              backups: source.backups,
              owner: sourceService.owner,
              files: files,
            ),
          );
          await shown(tester, find.text('恢复密钥已另存'));
          await tester.tap(find.text('导出加密备份'));
          await shown(tester, find.text('加密备份已导出。'));
          expect(
            find.textContaining('当前文件字段 1 个，可恢复原文版本 2 份（含保留版本）· 7 B'),
            findsOneWidget,
          );
          expect(find.textContaining('文件交付事实 1 条'), findsOneWidget);
          await capture?.call(tester, 'backup-export');
          final oldRuntime = targetService.agent.openSession('恢复前的空库会话');
          await mount(
            tester,
            BackupFlowDialog(
              backups: target.backups,
              owner: targetService.owner,
              files: files,
            ),
          );
          await shown(tester, find.text('首次启用备份'));
          await tester.tap(find.byKey(const ValueKey('backup-select-file')));
          await shown(tester, find.text('files.aimbackup'));
          await tester.tap(find.byKey(const ValueKey('backup-select-key')));
          await shown(tester, find.text('recovery.txt'));
          await tester.tap(find.text('检查备份与恢复密钥'));
          await shown(tester, find.text('恢复预览'));
          expect(
            find.textContaining('当前文件字段 1 个，可恢复原文版本 2 份（含保留版本）· 7 B'),
            findsOneWidget,
          );
          expect(find.textContaining('不重建活副本'), findsOneWidget);
          await capture?.call(tester, 'backup-preview');
          await tester.ensureVisible(find.text('确认恢复到空库'));
          await tester.tap(find.text('确认恢复到空库'));
          await shown(tester, find.textContaining('资料已恢复'));
          await capture?.call(tester, 'backup-restored');
          expect(
            await target.readInformationAttachmentChunk(
              first.fields.single.attachment!,
              0,
              3,
            ),
            [0, 255, 7],
          );
          expect(
            await target.readInformationAttachmentChunk(
              second.fields.single.attachment!,
              0,
              4,
            ),
            [1, 2, 3, 4],
          );
          final usage = await targetService.owner.informationAttachmentUsage();
          expect(usage.storedBytes, 7);
          expect(usage.stagedFiles, 0);
          final fact = targetService.owner.informationFileDeliveries.single;
          expect(fact.runtime, isFalse);
          expect(fact.lease, isNull);
          expect(
            () => targetService.agent.validateSession(oldRuntime),
            throwsA(isA<AccessFailure>()),
          );
          expect(targetService.owner.requests, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await sourceService.close();
          await targetService.close();
          await source.close();
          await target.close();
          if (root.absolute.parent.path != Directory.systemTemp.absolute.path ||
              !root.path
                  .split(Platform.pathSeparator)
                  .last
                  .startsWith('attachment-backup-ui-')) {
            throw StateError('Unexpected test cleanup directory');
          }
          await root.delete(recursive: true);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      });
    },
  );
}
