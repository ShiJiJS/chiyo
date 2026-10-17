import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/credentials.dart';
import 'package:info_desktop/information_workspace.dart';
import 'package:info_desktop/credential_dialogs.dart';
import 'package:info_desktop/ui.dart';

class FailingCredentialRepository extends MemoryInformationRepository {
  int writes = 0;
  @override
  Future<void> commitCredentials(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) async {
    writes++;
    throw const AccessFailure('synthetic_write_failure');
  }
}

void main() {
  testWidgets(
    '1280 failure keeps complete save action reachable without shrinking the form',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FailingCredentialRepository();
      final service = InformationService(repository: repository);
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => CredentialEditor(owner: service.owner),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('credential-name')),
        'Synthetic',
      );
      await tester.enterText(
        find.byKey(const ValueKey('credential-secret')),
        'fictional',
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('save-credential'));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      final bottom = tester.getRect(save).bottomCenter - const Offset(0, 2);
      await tester.tapAt(bottom);
      await tester.pumpAndSettle();
      expect(repository.writes, 2);
      expect(service.owner.credentials, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
  testWidgets(
    '200 percent credential actions have a visible horizontal scrollbar and remain operable',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'fictional',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(body: CredentialLibrary(owner: service.owner)),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.widget<Scrollbar>(
        find.byKey(const ValueKey('credential-toolbar-scrollbar')),
      );
      expect(bar.thumbVisibility, isTrue);
      await tester.drag(
        find.byKey(const ValueKey('credential-toolbar-scroll')),
        const Offset(-1100, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除凭据'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(service.owner.credentials.length, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
  testWidgets(
    'workspace preserves routine filters and explicit current-ID navigation clears incompatible filters',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final first = await service.owner.createInformation(
        'Synthetic first',
        '',
        [const FieldInput('Host', '', 'first.invalid')],
      );
      final second = await service.owner.createInformation(
        'Synthetic second',
        '',
        [const FieldInput('Host', '', 'second.invalid')],
      );
      Future<void> show({String? id, int revision = 0}) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: informationTheme(),
            home: Scaffold(
              body: InformationWorkspace(
                owner: service.owner,
                focusItemId: id,
                focusRevision: revision,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(id: first.id);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'first',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-credentials-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('信息').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('library-search')))
            .controller!
            .text,
        'first',
      );
      await show(id: second.id, revision: 1);
      expect(find.byKey(ValueKey('information-${second.id}')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('library-search')))
            .controller!
            .text,
        isEmpty,
      );
      await show(id: 'missing-current-ID', revision: 2);
      expect(find.text('当前信息已不存在，请重新选择或检查回收站。'), findsOneWidget);
      expect(find.byKey(ValueKey('information-${second.id}')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
  );
  testWidgets('owner adds a hidden string then enables discovery explicitly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Scaffold(body: CredentialLibrary(owner: service.owner)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('new-credential')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('credential-name')),
      '虚构 Token',
    );
    await tester.enterText(
      find.byKey(const ValueKey('credential-secret')),
      'fictional-secret',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-credential')));
    await tester.pumpAndSettle();
    expect(service.owner.credentials.single.name, '虚构 Token');
    expect(service.owner.credentials.single.discoverable, isFalse);
    expect(find.text('fictional-secret'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('credential-metadata')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('credential-discoverable')));
    await tester.ensureVisible(
      find.byKey(const ValueKey('save-credential-management')),
    );
    await tester.tap(find.byKey(const ValueKey('save-credential-management')));
    await tester.pumpAndSettle();
    expect(
      service.agent.credentialCatalog().credentials.single['name'],
      '虚构 Token',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(service.close);
  });
}
