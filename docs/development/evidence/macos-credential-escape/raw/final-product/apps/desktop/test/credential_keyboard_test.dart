import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/credential_dialogs.dart';
import 'package:info_desktop/credential_management.dart';
import 'package:info_desktop/ui.dart';

class _HoldingRepository extends MemoryInformationRepository {
  Completer<void>? hold;
  @override
  Future<void> commitCredentials(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) async {
    await hold?.future;
    await super.commitCredentials(credentials, materials);
  }
}

void main() {
  const platforms = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
  });

  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> open(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => child,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> escape(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'credential Escape follows guarded cancellation and retains or discards the draft as chosen',
    (tester) async {
      viewport(tester);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      await open(tester, CredentialEditor(owner: service.owner));
      await tester.enterText(
        find.byKey(const ValueKey('credential-name')),
        'Unsaved synthetic name',
      );
      await escape(tester);
      expect(find.text('放弃未保存的凭据？'), findsOneWidget);
      await escape(tester);
      expect(find.text('放弃未保存的凭据？'), findsNothing);
      expect(find.byType(CredentialEditor), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('credential-name')))
            .controller!
            .text,
        'Unsaved synthetic name',
      );
      expect(service.owner.credentials, isEmpty);
      await escape(tester);
      await tester.tap(find.text('放弃更改'));
      await tester.pumpAndSettle();
      expect(find.byType(CredentialEditor), findsNothing);
      expect(service.owner.credentials, isEmpty);
      await open(tester, CredentialEditor(owner: service.owner));
      await escape(tester);
      expect(find.byType(CredentialEditor), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
    variant: platforms,
  );

  testWidgets(
    'management Escape uses existing cancel behavior without changing metadata versions or state',
    (tester) async {
      viewport(tester);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final original = await service.owner.createStringCredential(
        name: 'Synthetic credential',
        publicPurpose: 'test',
        secret: 'SyntheticSecret42',
      );
      for (final action in ['metadata', 'rotate', 'disable', 'delete']) {
        await open(
          tester,
          CredentialManagement(
            owner: service.owner,
            credential: original,
            action: action,
          ),
        );
        if (action == 'metadata') {
          final field = find
              .descendant(
                of: find.byType(CredentialManagement),
                matching: find.byType(TextField),
              )
              .first;
          await tester.enterText(field, 'Unsaved changed name');
        }
        await escape(tester);
        expect(find.byType(CredentialManagement), findsNothing);
        final current = service.owner.credentials.single;
        expect(current.name, original.name);
        expect(current.revision, original.revision);
        expect(current.version, original.version);
        expect(current.enabled, original.enabled);
        expect(current.deletedAt, isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
    variant: platforms,
  );

  testWidgets(
    'Escape cannot dismiss a management save while its actual repository commit is pending',
    (tester) async {
      viewport(tester);
      final repository = _HoldingRepository();
      final service = InformationService(repository: repository);
      final original = await service.owner.createStringCredential(
        name: 'Synthetic credential',
        publicPurpose: 'test',
        secret: 'SyntheticSecret42',
      );
      await open(
        tester,
        CredentialManagement(
          owner: service.owner,
          credential: original,
          action: 'metadata',
        ),
      );
      await tester.tap(find.text('编辑名称、用途与私有备注'));
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.controller?.text == original.name,
      );
      await tester.enterText(field, 'Committed synthetic name');
      repository.hold = Completer<void>();
      await tester.tap(
        find.byKey(const ValueKey('save-credential-management')),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(CredentialManagement), findsOneWidget);
      expect(service.owner.credentials.single.name, original.name);
      repository.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CredentialManagement), findsNothing);
      expect(service.owner.credentials.single.name, 'Committed synthetic name');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    },
    variant: platforms,
  );
}
