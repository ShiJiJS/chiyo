import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/credential_use_approval.dart';
import 'package:info_desktop/import_proposals.dart';
import 'package:info_desktop/prototype_dialog.dart';
import 'package:info_desktop/recycle.dart';
import 'package:info_desktop/revisions.dart';
import 'package:info_desktop/ui.dart';
import 'support/information_attachment_fixture.dart';

void main() {
  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> mount(WidgetTester tester, Widget body) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Scaffold(body: body),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'owner deletion and recycle preview retain file version, restoring never revives the old field grant',
    (tester) async {
      await tester.runAsync(() async {
        viewport(tester);
        final f = await AttachmentUiFixture.create();
        try {
          final field = f.item.fields.last;
          final session = f.service.agent.openSession('回收简历');
          final ref = FieldRef(f.item.id, field.id);
          final request = f.service.agent.request(session, '读取简历', [ref]);
          f.owner.approve(request.id, [ref]);
          await f.owner.retryAuditStorage();
          await mount(
            tester,
            Builder(
              builder: (context) => TextButton(
                onPressed: () => confirmInformationDeletion(
                  context,
                  f.owner,
                  f.item,
                  fieldId: field.id,
                ),
                child: const Text('删除文件字段'),
              ),
            ),
          );
          await tester.tap(find.text('删除文件字段'));
          await tester.pumpAndSettle();
          expect(find.text('fictional-resume.pdf'), findsOneWidget);
          expect(find.textContaining('application/pdf · 版本 1'), findsOneWidget);
          await tester.tap(find.text('确认删除'));
          await tester.pumpAndSettle();
          expect(
            f.owner.information.single.fields.any((v) => v.id == field.id),
            isFalse,
          );
          await expectLater(
            f.fetch(session, request.id, 'deleted-field'),
            throwsA(isA<InformationFileFailure>()),
          );
          await mount(tester, RecyclePage(owner: f.owner));
          expect(find.text('包含文件及其保留版本'), findsOneWidget);
          await tester.tap(find.text('查看内容'));
          await tester.pumpAndSettle();
          expect(find.text('fictional-resume.pdf'), findsOneWidget);
          expect(find.textContaining('原文件已清理'), findsNothing);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('恢复'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认恢复'));
          await tester.pumpAndSettle();
          final restored = f.owner.information.single.fields.last;
          expect(restored.id, isNot(field.id));
          expect(restored.attachment, field.attachment);
          expect(f.owner.recycleEntries, isEmpty);
          await expectLater(
            f.fetch(session, request.id, 'restored-still-denied'),
            throwsA(isA<InformationFileFailure>()),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.close();
        }
      });
    },
  );

  testWidgets(
    'revision comparison displays both exact file versions and restores the old original as a new current revision',
    (tester) async {
      await tester.runAsync(() async {
        viewport(tester);
        final f = await AttachmentUiFixture.create();
        try {
          final original = f.item.fields.last;
          await f.replace([0, 255, 8, 9]);
          await mount(
            tester,
            RevisionHistoryPage(owner: f.owner, itemId: f.item.id),
          );
          expect(find.text('简历 · 文件版本 1'), findsOneWidget);
          await tester.tap(find.text('查看差异'));
          await tester.pumpAndSettle();
          expect(find.text('fictional-resume.pdf'), findsNWidgets(2));
          expect(find.textContaining('application/pdf · 版本 1'), findsOneWidget);
          expect(find.textContaining('application/pdf · 版本 2'), findsOneWidget);
          await tester.tap(find.text('确认恢复为新版本'));
          await tester.pumpAndSettle();
          final restored = f.owner.information.single;
          expect(restored.version, 3);
          expect(restored.fields.last.id, original.id);
          expect(restored.fields.last.attachment, original.attachment);
          final session = f.service.agent.openSession('读取恢复后的简历');
          final ref = FieldRef(restored.id, original.id);
          final request = f.service.agent.request(session, '确认原件', [ref]);
          f.owner.approve(request.id, [ref]);
          await f.owner.retryAuditStorage();
          await f.fetch(session, request.id, 'restored-version');
          expect(f.driver.bodies.values.single, [0, 255, 7]);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.close();
        }
      });
    },
  );

  testWidgets(
    'text proposal review preserves an existing file and file deletion proposals preview private metadata',
    (tester) async {
      await tester.runAsync(() async {
        viewport(tester);
        final f = await AttachmentUiFixture.create();
        try {
          final attachment = f.item.fields.last.attachment;
          final session = f.service.agent.openSession('调整求职资料');
          await f.service.agent.submitUpdate(
            session,
            UpdateInput(f.item.id, 1, [
              FieldChange.correct(f.item.fields.first.id, '新姓名'),
            ]),
          );
          await mount(tester, ImportProposalsPage(owner: f.owner));
          expect(find.text('简历 · 保留原文件与版本'), findsOneWidget);
          expect(find.text('fictional-resume.pdf'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('edit-update')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('field-value-0')),
            '主人复核的姓名',
          );
          await tester.tap(find.byKey(const ValueKey('save-information')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('proposal-action-confirm')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('confirm-proposal-decision')),
          );
          await tester.pumpAndSettle();
          final current = f.owner.information.single;
          expect(current.fields.first.value, '主人复核的姓名');
          expect(current.fields.last.attachment, attachment);
          await tester.tap(find.text('按信息身份查看当前内容 →'));
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(PrototypeDialog),
              matching: find.text('fictional-resume.pdf'),
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('×'));
          await tester.pumpAndSettle();
          final deleted = await f.service.agent.submitDelete(
            session,
            current.id,
            current.version,
            fieldId: current.fields.last.id,
          );
          await mount(
            tester,
            ImportProposalsPage(
              key: UniqueKey(),
              owner: f.owner,
              initialProposalId: deleted,
            ),
          );
          expect(find.text('fictional-resume.pdf'), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('proposal-action-confirm')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('confirm-proposal-decision')),
          );
          await tester.pumpAndSettle();
          expect(
            f.owner.recycleEntries.single.snapshot!.fields.single.attachment,
            attachment,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.close();
        }
      });
    },
  );

  testWidgets(
    'credential approval also reviews an attached ordinary file and rejects replacement while the confirmation is open',
    (tester) async {
      await tester.runAsync(() async {
        viewport(tester);
        final f = await AttachmentUiFixture.create(
          executableInspector: (path, receiver) async =>
              ExecutableIdentity(path, 1, 1, 'sha256:synthetic'),
        );
        try {
          var credential = await f.owner.createStringCredential(
            name: '发布凭据',
            publicPurpose: '发布',
            secret: 'synthetic-token',
          );
          credential = await f.owner.updateCredentialMetadata(
            credential.id,
            credential.revision,
            name: credential.name,
            publicPurpose: credential.publicPurpose,
            privateNote: '',
            suggestedBinding: 'GH_TOKEN',
            discoverable: true,
          );
          final session = f.service.agent.openSession('同时申请文件与凭据');
          final ref = FieldRef(f.item.id, f.item.fields.last.id);
          final request = await f.service.agent.requestCredentialUse(
            session,
            CredentialUseInput.fromJson({
              'command': 'request-use',
              'protocolVersion': 2,
              'purpose': '读取简历与发布资料',
              'credentials': [
                {
                  'alias': 'publish',
                  'credentialId': credential.id,
                  'version': 1,
                },
              ],
              'launch': {
                'receiver': 'gh_token',
                'executable': Platform.resolvedExecutable,
                'argv': ['repo', 'view', 'northstar/docs'],
                'cwd': Directory.current.path,
                'env': {
                  'GH_TOKEN': {'secret': 'publish'},
                },
              },
              'readFields': [ref.toJson()],
            }),
          );
          await mount(
            tester,
            CredentialUseApprovalPanel(
              owner: f.owner,
              request: request,
              draft: CredentialUseApprovalDraft([ref]),
              onChanged: () {},
            ),
          );
          await tester.tap(
            find.byKey(const ValueKey('credential-use-approve')),
          );
          await tester.pumpAndSettle();
          expect(find.text('简历 · 领取原文件'), findsOneWidget);
          expect(find.text('fictional-resume.pdf'), findsOneWidget);
          await f.replace([1, 2, 3, 4]);
          await tester.tap(find.text('确认批准'));
          await tester.pumpAndSettle();
          expect(
            f.owner.credentialUseState(f.owner.credentialUseRequests.single),
            'pending',
          );
          expect(find.textContaining('文件版本已变化'), findsWidgets);
          await tester.tap(find.text('返回核对'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('credential-use-approve')),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('application/pdf · 版本 2'), findsOneWidget);
          await tester.tap(find.text('确认批准'));
          await tester.pumpAndSettle();
          final approved = f.owner.credentialUseRequests.single;
          expect(approved.approvedFields, [ref]);
          expect(
            approved.fieldExpiresAt!.difference(approved.decidedAt!),
            const Duration(hours: 2),
          );
          await f.fetch(session, request.id, 'combined-file');
          expect(f.driver.bodies.values.single, [1, 2, 3, 4]);
          expect(find.textContaining('synthetic-token'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await f.close();
        }
      });
    },
  );
}
