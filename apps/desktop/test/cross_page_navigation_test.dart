import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/import_proposals.dart';

void viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

String search(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

void main() {
  testWidgets(
    'main shares current-ID navigation with proposal results and credential links while ordinary library jumps preserve state',
    (tester) async {
      viewport(tester);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      try {
        final kept = await service.owner.createInformation('Other kept', '', [
          const FieldInput('Host', '', 'kept.invalid'),
        ]);
        final inputs = [
          ImportItemInput('Imported target', '', [
            const FieldInput('Host', '', 'imported.invalid'),
          ]),
        ];
        final proposal = await service.agent.submitImport(
          service.agent.openSession('Import chat'),
          inputs,
        );
        await service.owner.confirmImport(proposal, 1, inputs);
        final target = service.owner.information.singleWhere(
          (i) => i.name == 'Imported target',
        );
        await service.owner.correctValue(
          FieldRef(target.id, target.fields.single.id),
          'current.invalid',
        );
        var credential = await service.owner.createStringCredential(
          name: 'Linked token',
          publicPurpose: 'API',
          secret: 'fictional',
        );
        await service.owner.setCredentialLinks(
          credential.id,
          credential.revision,
          [target.id],
        );
        await tester.pumpWidget(InformationApp(service: service, port: 0));
        await tester.pumpAndSettle();
        await tap(tester, find.byKey(const ValueKey('nav-1')));
        await tester.enterText(
          find.byKey(const ValueKey('library-search')),
          'Other kept',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('information-${kept.id}')), findsOneWidget);
        await tap(tester, find.byKey(const ValueKey('nav-2')));
        await tap(
          tester,
          find.byKey(const ValueKey('proposal-filter-handled')),
        );
        await tap(tester, find.text('前往信息库'));
        expect(search(tester, 'library-search'), 'Other kept');
        expect(find.byKey(ValueKey('information-${kept.id}')), findsOneWidget);
        Future<void> openCurrentTarget() async {
          await tap(tester, find.byKey(const ValueKey('nav-2')));
          await tap(tester, find.text('按信息身份查看当前内容 →'));
          expect(find.text('current.invalid'), findsOneWidget);
          expect(find.text('imported.invalid'), findsNothing);
          await tap(tester, find.text('在信息库打开 →'));
          expect(
            find.byKey(ValueKey('information-${target.id}')),
            findsOneWidget,
          );
          expect(search(tester, 'library-search'), isEmpty);
        }

        await openCurrentTarget();
        await tester.enterText(
          find.byKey(const ValueKey('library-search')),
          'Other kept',
        );
        await tester.pumpAndSettle();
        await openCurrentTarget();
        await tester.enterText(
          find.byKey(const ValueKey('library-search')),
          'Other kept',
        );
        await tester.pumpAndSettle();
        await tap(
          tester,
          find.byKey(const ValueKey('library-credentials-mode')),
        );
        await tap(tester, find.text('Imported target'));
        expect(
          find.byKey(ValueKey('information-${target.id}')),
          findsOneWidget,
        );
        expect(search(tester, 'library-search'), isEmpty);
        await tap(tester, find.byKey(const ValueKey('nav-2')));
        final page = tester.widget<ImportProposalsPage>(
          find.byType(ImportProposalsPage),
        );
        final current = service.owner.information.singleWhere(
          (i) => i.id == target.id,
        );
        await service.owner.deleteInformation(current.id, current.version);
        // A previously emitted ID may arrive after deletion; exercise the actual
        // parent callback rather than replacing it with a test navigation handler.
        page.onOpenInformation!(target.id);
        await tester.pumpAndSettle();
        expect(find.text('当前信息已不存在，请重新选择或检查回收站。'), findsOneWidget);
        expect(find.byKey(ValueKey('information-${kept.id}')), findsNothing);
        await tap(tester, find.byKey(const ValueKey('nav-0')));
        await tap(tester, find.byKey(const ValueKey('nav-1')));
        expect(find.text('当前信息已不存在，请重新选择或检查回收站。'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(service.close);
      }
    },
  );

  testWidgets(
    'main opens the actual organization task and preserves history search page and selection on ordinary returns',
    (tester) async {
      viewport(tester);
      var now = DateTime.utc(2026, 10, 1);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      try {
        final item = await service.owner.createInformation('Server', '', [
          const FieldInput('Host', '', 'synthetic.invalid'),
        ]);
        final session = service.agent.openSession('Organization chat');
        String? target;
        for (var i = 0; i < 10; i++) {
          final task = await service.agent.requestOrganization(
            session,
            'Task $i',
            [item.id],
          );
          await service.owner.approveOrganization(task.id, [item.id]);
          await service.agent.submitOrganization(session, task.id, []);
          target ??= task.id;
          now = now.add(const Duration(minutes: 1));
        }
        await tester.pumpWidget(InformationApp(service: service, port: 0));
        await tester.pumpAndSettle();
        await tap(tester, find.byKey(const ValueKey('nav-3')));
        await tester.enterText(
          find.byKey(const ValueKey('history-search')),
          'unrelated',
        );
        await tester.pumpAndSettle();
        await tap(tester, find.byKey(const ValueKey('nav-2')));
        await tap(
          tester,
          find.byKey(const ValueKey('proposal-filter-handled')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('proposal-search')),
          'Task 0',
        );
        await tester.pumpAndSettle();
        await tap(tester, find.text('查看本次整理授权 →'));
        expect(
          find.byKey(ValueKey('history-document-$target')),
          findsOneWidget,
        );
        expect(find.text('2 / 2'), findsOneWidget);
        expect(search(tester, 'history-search'), isEmpty);
        await tester.enterText(
          find.byKey(const ValueKey('history-search')),
          'Task',
        );
        await tester.pumpAndSettle();
        await tap(tester, find.text('›'));
        await tap(tester, find.byKey(ValueKey('history-entry-$target')));
        await tap(tester, find.byKey(const ValueKey('nav-0')));
        await tap(tester, find.byKey(const ValueKey('nav-3')));
        expect(search(tester, 'history-search'), 'Task');
        expect(find.text('2 / 2'), findsOneWidget);
        expect(
          find.byKey(ValueKey('history-document-$target')),
          findsOneWidget,
        );
        await tap(tester, find.byKey(const ValueKey('nav-2')));
        await tap(tester, find.text('查看本次整理授权 →'));
        expect(search(tester, 'history-search'), isEmpty);
        expect(
          find.byKey(ValueKey('history-document-$target')),
          findsOneWidget,
        );
        await tap(tester, find.byKey(const ValueKey('nav-2')));
        tester
            .widget<ImportProposalsPage>(find.byType(ImportProposalsPage))
            .onOpenOrganizationGrant!('missing-retained-task');
        await tester.pumpAndSettle();
        expect(find.text('这条记录不在当前保留范围内或未记录。'), findsOneWidget);
        expect(find.byKey(ValueKey('history-document-$target')), findsNothing);
        await tap(tester, find.byKey(const ValueKey('nav-0')));
        await tap(tester, find.byKey(const ValueKey('nav-3')));
        expect(find.text('这条记录不在当前保留范围内或未记录。'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(service.close);
      }
    },
  );
}
