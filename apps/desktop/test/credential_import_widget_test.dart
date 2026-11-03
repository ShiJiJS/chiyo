import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_agent_templates.dart';
import 'package:info_desktop/workspace/owner_proposal_password_input.dart';
import 'package:info_desktop/workspace/owner_workspace_proposals.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'owner enters a password inside the real proposal, approves it, and CLI never receives its value',
    (t) async {
      t.view.physicalSize = const Size(1440, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late Directory root;
      late EncryptedInformationRepository repo;
      late core.InformationService service;
      late AgentServer server;
      late AgentClient cli;
      late OwnerWorkspaceSource library;
      late OwnerWorkspaceProposals source;
      late ProposalsController model;
      late String id;
      late OwnerProposalPasswords passwords;
      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('credential-owner-ui-');
        repo = await EncryptedInformationRepository.open(root.path, _Keys());
        service = core.InformationService(repository: repo);
        service.owner.configureInformationTemplates(
          () => currentAgentTemplates(service.owner),
        );
        server = await AgentServer.start(service.agent, port: 0);
        cli = HttpOverrides.runWithHttpOverrides(
          () => AgentClient(server.port),
          _RealHttp(),
        );
        await cli.execute({'command': 'session', 'chatLabel': '合成密码补填'});
        final template =
            (await cli.execute({
                  'command': 'template-read',
                  'templateId': 'credential.accountPassword',
                }))['template']
                as Map;
        final result = await cli.execute(
          Map<String, dynamic>.from(template['submissionExample'] as Map),
        );
        expect(result['status'], 'pending');
        id = result['proposalId'] as String;
        source = OwnerWorkspaceProposals(
          owner: service.owner,
          library: () => library,
          changed: () => library.notifyExternalChange(),
        );
        library = OwnerWorkspaceSource(
          owner: service.owner,
          proposals: source,
          refreshInterval: Duration.zero,
        );
        passwords = OwnerProposalPasswords(service.owner);
        model = ProposalsController(source, library.changes);
        await model.open(id);
      });
      Future<void> settle({bool dialog = false}) async {
        for (var i = 0; i < 150; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
          await t.pump(const Duration(milliseconds: 10));
          if (!model.busy &&
              !model.loading &&
              !model.reading &&
              (!dialog ||
                  find
                      .byKey(const ValueKey('proposal-owner-password'))
                      .evaluate()
                      .isEmpty)) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('Credential proposal UI did not settle');
      }

      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: ProposalsPage(
                controller: model,
                onRecord: (_) {},
                passwords: passwords,
              ),
            ),
          ),
        ),
      );
      await settle();
      final item = model.detail!.items.single;
      expect(item.proposed.record.ref.kind, WorkspaceRecordKind.credential);
      expect(item.proposed.values, isEmpty);
      expect(item.credential!.ready, false);
      expect(item.credential!.account, 'sample-user');
      expect(find.text('账号：sample-user'), findsOneWidget);
      expect(find.text('账号密码'), findsOneWidget);
      expect(model.canConfirm, false);
      expect(repo.managedCredentials, isEmpty);
      final originalReview = WorkspaceProposalItemReview.fromItem(item);
      expect(
        model.editItem(
          id,
          model.detail!.summary.version,
          WorkspaceProposalItemReview(
            itemId: item.id,
            name: '主人核对后的登录密码',
            description: originalReview.description,
            values: originalReview.values,
            directoryId: originalReview.directoryId,
            tagIds: originalReview.tagIds,
            relations: originalReview.relations,
          ),
        ),
        true,
      );
      final input = find.byKey(ValueKey('proposal-owner-password-${item.id}'));
      await t.ensureVisible(input);
      await t.enterText(input, 'PRIVATE-OWNER-WIDGET-PASSWORD');
      await t.pumpAndSettle();
      expect(model.detail!.items.single.credential!.ready, false);
      expect(model.canConfirm, true);
      expect(model.draft!.items[item.id]!.name, '主人核对后的登录密码');
      expect(repo.managedCredentials, isEmpty);
      expect(find.text('保存密码到提案'), findsNothing);
      expect(
        t
            .widget<TextField>(
              find.descendant(of: input, matching: find.byType(TextField)),
            )
            .obscureText,
        true,
      );
      final visibility = find.byKey(
        ValueKey('proposal-password-visible-${item.id}'),
      );
      await t.tap(visibility);
      await t.pumpAndSettle();
      expect(
        t
            .widget<TextField>(
              find.descendant(of: input, matching: find.byType(TextField)),
            )
            .obscureText,
        false,
      );
      await t.tap(visibility);
      await t.pumpAndSettle();
      final before = await t.runAsync(
        () => cli.execute({'command': 'import-status', 'proposalId': id}),
      );
      expect(jsonEncode(before), isNot(contains('PRIVATE-OWNER-WIDGET')));
      final approve = find.byKey(const ValueKey('proposal-confirm'));
      await t.ensureVisible(approve);
      await t.tap(approve);
      await settle();
      expect(model.writeFailure, isNull, reason: model.writeFailure?.message);
      expect(model.uncertain, false);
      expect(repo.managedCredentials.length, 1);
      expect(repo.managedCredentials.single.name, '主人核对后的登录密码');
      expect(repo.managedCredentials.single.account, 'sample-user');
      expect(repo.items, isEmpty);
      expect(
        utf8.decode(repo.credentialMaterials.single.bytes),
        'PRIVATE-OWNER-WIDGET-PASSWORD',
      );
      await t.runAsync(() async {
        final status = await cli.execute({
          'command': 'import-status',
          'proposalId': id,
        });
        expect(status['status'], 'confirmed');
        expect(jsonEncode(status), isNot(contains('PRIVATE-OWNER-WIDGET')));
        final saved = await source.read(id);
        expect(
          saved.targets.single.record.kind,
          WorkspaceRecordKind.credential,
        );
        expect(saved.targets.single.exists, true);
        expect(saved.targets.single.snapshotAvailable, false);
        final original = repo.managedCredentials.single;
        await service.owner.updateCredentialMetadata(
          original.id,
          original.revision,
          name: '后来改过的名称',
          publicPurpose: original.publicPurpose,
          privateNote: '后来添加的备注',
          suggestedBinding: original.suggestedBinding,
          discoverable: original.discoverable,
        );
        final preview = await source.savedPreview(
          id,
          saved.targets.single.record,
        );
        expect(preview.proposed.record.name, '主人核对后的登录密码');
        expect(preview.credential!.account, 'sample-user');
        expect(preview.proposed.values, isEmpty);
        final currentDetail = await library.readDetail(
          saved.targets.single.record,
        );
        expect(
          currentDetail.record.type.name,
          preview.proposed.record.type.name,
        );
        expect(
          (await library.credentials.read(saved.targets.single.record)).account,
          'sample-user',
        );
      });
      for (final kind in ['accountPassword', 'token', 'file']) {
        late String proposalId;
        await t.runAsync(() async {
          final template =
              (await cli.execute({
                    'command': 'template-read',
                    'templateId': 'credential.$kind',
                  }))['template']
                  as Map;
          final examples = template['submissionExamples'] as List;
          final input = Map<String, dynamic>.from(
            examples[kind == 'accountPassword' ? 1 : 0] as Map,
          );
          input['operationId'] = 'owner-widget-$kind';
          if (kind == 'file') {
            final file = File('${root.path}/synthetic-session.key');
            await file.writeAsString('FAKE-SYNTHETIC-FILE-CREDENTIAL');
            final item = Map<String, dynamic>.from(
              (input['items'] as List).single as Map,
            );
            item['credential'] = {
              'source': 'agentFile',
              'contextExposed': false,
              'filePath': file.path,
            };
            input['items'] = [item];
          }
          final result = await cli.execute(input);
          expect(result['status'], 'pending');
          proposalId = result['proposalId'] as String;
          await model.open(proposalId);
        });
        await settle();
        expect(model.canConfirm, true);
        expect(find.text('FAKE-EXAMPLE-ONLY'), findsNothing);
        if (kind == 'file') {
          expect(find.text('文件已提供'), findsOneWidget);
          expect(find.text('填写密码'), findsNothing);
        } else {
          expect(find.text('AI已提供此密码或凭证，内容可能已进入会话上下文。'), findsOneWidget);
        }
        await t.ensureVisible(approve);
        await t.tap(approve);
        await settle();
        expect(model.writeFailure, isNull, reason: model.writeFailure?.message);
        expect(model.uncertain, false);
        expect(
          model.detail!.targets.single.record.kind,
          WorkspaceRecordKind.credential,
        );
      }
      expect(repo.managedCredentials.length, 4);
      expect(repo.items, isEmpty);
      await t.pumpWidget(const SizedBox());
      model.dispose();
      passwords.dispose();
      await t.runAsync(() async {
        cli.close();
        await library.dispose();
        await server.close();
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
    },
  );
}
