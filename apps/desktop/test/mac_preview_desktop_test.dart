import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/mac_preview_desktop.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  Future<void> nativeCommand(String method) async {
    final done = Completer<void>();
    await messenger.handlePlatformMessage(
      MacPreviewDesktop.channel.name,
      codec.encodeMethodCall(MethodCall(method)),
      (_) => done.complete(),
    );
    await done.future;
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, null);
  });

  test(
    'preview fails closed when the native mode is missing or incomplete',
    () async {
      final desktop = MacPreviewDesktop();
      addTearDown(desktop.dispose);
      await expectLater(
        desktop.initialize(),
        throwsA(isA<MissingPluginException>()),
      );
      messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, (_) async {
        return {
          'isolated': true,
          'productionServices': true,
          'savedDirectories': false,
        };
      });
      await expectLater(desktop.initialize(), throwsStateError);
    },
  );

  testWidgets(
    'Mac menu commands navigate the preview and modal gates navigation',
    (tester) async {
      final commands = <MethodCall>[];
      messenger.setMockMethodCallHandler(MacPreviewDesktop.channel, (
        call,
      ) async {
        commands.add(call);
        if (call.method == 'initialize') {
          return {
            'isolated': true,
            'productionServices': false,
            'savedDirectories': false,
            'title': MacPreviewDesktop.windowTitle,
          };
        }
        return null;
      });
      final desktop = MacPreviewDesktop();
      await desktop.initialize();
      WorkspacePage? current;
      await tester.pumpWidget(
        PreviewWorkspace(
          desktop: desktop,
          pageBuilder: (_, location) {
            current = location.page;
            return Text('destination:${location.page.name}');
          },
        ),
      );
      await tester.pumpAndSettle();
      await nativeCommand('openSettings');
      await tester.pumpAndSettle();
      expect(current, WorkspacePage.settings);
      await nativeCommand('searchApprovals');
      await tester.pumpAndSettle();
      expect(current, WorkspacePage.library);
      await tester.tap(find.byKey(const ValueKey('preview-guide')));
      await tester.pumpAndSettle();
      expect(commands.last.method, 'setNavigationEnabled');
      expect(commands.last.arguments, false);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(commands.last.arguments, true);
      await tester.pumpWidget(const SizedBox());
      await nativeCommand('openSettings');
      expect(current, WorkspacePage.library);
    },
  );
}
