import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/library_credential.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

void main() {
  testWidgets('owner reveals hides and copies saved string without approval', (
    t,
  ) async {
    await t.runAsync(() async {
      final service = core.InformationService(
        repository: core.MemoryInformationRepository(),
      );
      final c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'SYNTHETIC_OWNER_WIDGET',
      );
      final source = OwnerWorkspaceSource(
        owner: service.owner,
        refreshInterval: Duration.zero,
      );
      addTearDown(() async {
        await source.dispose();
        await service.close();
      });
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: LibraryCredential(
                ref: WorkspaceRecordRef(WorkspaceRecordKind.credential, c.id),
                revision: 1,
                source: source,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('SYNTHETIC_OWNER_WIDGET'), findsNothing);
      await t.tap(find.byKey(const ValueKey('credential-reveal')));
      await t.pumpAndSettle();
      expect(find.text('SYNTHETIC_OWNER_WIDGET'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('credential-reveal')));
      await t.pumpAndSettle();
      expect(find.text('SYNTHETIC_OWNER_WIDGET'), findsNothing);
      await t.tap(find.byKey(const ValueKey('credential-copy')));
      await t.pumpAndSettle();
      expect(copied, 'SYNTHETIC_OWNER_WIDGET');
      expect(service.owner.credentialUseRequests, isEmpty);
    });
  });
}
