// QA entry only: real host requests, synthetic library, owner widget controls.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 117);
  @override
  Future<void> create(List<int> key) async => throw StateError('QA key only');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const owner = String.fromEnvironment('OWNER_NATIVE_WORKFLOW_RUN');
  if (!Platform.isMacOS ||
      !const bool.fromEnvironment('OWNER_NATIVE_SYNTHETIC') ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(owner)) {
    throw StateError('Explicit isolated invocation required');
  }
  testWidgets('real Codex requests pass through native owner controls', (
    t,
  ) async {
    await loadDesktopFonts();
    final root = Directory(
      '${Directory.systemTemp.path}/owner-workflow-$owner',
    );
    if (await root.exists()) throw StateError('Refuse existing fixture');
    await root.create();
    await File(
      '${root.path}/fixture-marker',
    ).writeAsString('disposable-owner-ui-v1');
    await File('${root.path}/.qa-owner').writeAsString(owner);
    final repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      _Keys(),
    );
    final service = core.InformationService(repository: repo);
    final bootstrap = DesktopBootstrap(
      port: 47125,
      platform: NativeDesktopPlatform(),
      openLibrary: () async => DesktopLibrary(
        service: service,
        backups: repo.backups,
        close: repo.close,
      ),
    );
    final boundary = GlobalKey();
    final checks = <String>[];
    String? screenshot;
    var stopped = false;
    Future<void> settle() async {
      await t.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 15),
      );
      expect(t.takeException(), isNull);
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200; i++) {
        await t.pump(const Duration(milliseconds: 100));
        expect(t.takeException(), isNull);
        if (done()) {
          await settle();
          return;
        }
      }
      fail('Native owner UI did not reach expected state');
    }

    Future<void> tap(Finder f) async {
      await t.ensureVisible(f);
      await t.tap(f);
      await settle();
    }

    Future<void> enter(String key, String value) async {
      final f = find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
      await t.ensureVisible(f);
      await t.enterText(f, value);
      await settle();
    }

    Future<void> write(String name, Object value) async {
      final temporary = File('${root.path}/.$name.partial');
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename('${root.path}/$name');
    }

    try {
      await bootstrap.start();
      expect(bootstrap.state, DesktopStartupState.ready);
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: DesktopLauncher(bootstrap: bootstrap, useWorkspace: true),
        ),
      );
      await until(
        () =>
            find.byType(WorkspaceApp).evaluate().isNotEmpty &&
            find.byType(LibraryPage).evaluate().isNotEmpty &&
            t
                    .widget<LibraryPage>(find.byType(LibraryPage))
                    .controller
                    .loadState !=
                WorkspaceLoad.loading,
      );
      await tap(find.byTooltip('添加资料').first);
      await tap(find.text('服务器信息').last);
      await enter('library-edit-name', 'Synthetic Mac server');
      await enter('library-edit-host', 'synthetic-host.invalid');
      await enter('library-edit-user', 'synthetic-private-user');
      await tap(find.byKey(const ValueKey('library-edit-save')));
      await until(
        () =>
            repo.items.length == 1 &&
            t.widget<LibraryPage>(find.byType(LibraryPage)).controller.detail !=
                null &&
            find.byKey(const ValueKey('library-edit-save')).evaluate().isEmpty,
      );
      final detail = t
          .widget<LibraryPage>(find.byType(LibraryPage))
          .controller
          .detail!;
      final item = detail.record.ref.id,
          address = detail.fieldIds['host']!,
          username = detail.fieldIds['user']!;
      checks.add('native-owner-ui-saves-synthetic-record');
      Future<Map<String, Object?>> status() async {
        final history = await service.owner.history();
        return {
          'ready': true,
          'port': bootstrap.boundPort,
          'textItem': item,
          'addressField': address,
          'usernameField': username,
          'requests': [
            for (final r in service.owner.requests)
              {
                'id': r.id,
                'state': r.state.name,
                'chatLabel': r.chatLabel,
                'sessionEnded': r.sessionEnded,
                'approvedFields': [
                  for (final f in r.approvedFields ?? <core.FieldRef>[])
                    {'itemId': f.itemId, 'fieldId': f.fieldId},
                ],
              },
          ],
          'grants': [
            for (final g in history.grants)
              {
                'id': g.id,
                'requestId': g.requestId,
                'active': g.active,
                'expiresAt': g.expiresAt.toIso8601String(),
              },
          ],
          'accesses': [
            for (final a in history.accesses)
              {
                'outcome': a.outcome.name,
                'grantId': a.grantId,
                'fieldId': a.fieldId,
              },
          ],
          'uiChecks': checks,
        };
      }

      await write('ready.json', await status());
      debugPrint('MAC_CODEX_LIVE_ROOT=${root.path}');
      var index = 0;
      final deadline = DateTime.now().add(const Duration(minutes: 14));
      while (DateTime.now().isBefore(deadline)) {
        final command = File('${root.path}/command-${index + 1}.json');
        if (!await command.exists()) {
          await t.pump(const Duration(milliseconds: 100));
          continue;
        }
        final data = jsonDecode(await command.readAsString()) as Map;
        if (data['owner'] != owner) throw StateError('Foreign QA command');
        final action = data['action'];
        if (action == 'quit') {
          await write('reply-${index + 1}.json', {
            'quitting': true,
            'status': await status(),
          });
          await bootstrap.runtime!.stop();
          stopped = true;
          checks.add('native-runtime-closed');
          break;
        }
        if (action != 'status') {
          if (!['approve', 'deny', 'revoke'].contains(action)) {
            throw StateError('Unexpected owner action');
          }
          final id = data['requestId'] as String;
          await tap(find.byKey(const ValueKey('workspace-nav-approvals')));
          final model = t
              .widget<ApprovalsPage>(find.byType(ApprovalsPage))
              .controller;
          // The test uses the same all-filter and row controls as the owner.
          if (find.byKey(ValueKey('approval-select-$id')).evaluate().isEmpty) {
            await tap(find.text('全部').first);
          }
          await until(
            () => find
                .byKey(ValueKey('approval-select-$id'))
                .evaluate()
                .isNotEmpty,
          );
          await tap(find.byKey(ValueKey('approval-select-$id')));
          await until(() => model.detail?.request.id == id && !model.reading);
          expect(
            model.detail!.scopes.every(
              (s) =>
                  s.record.id == item &&
                  [address, username].contains(s.fieldId),
            ),
            isTrue,
          );
          if (action == 'approve') {
            final fields = (data['fields'] as List).cast<String>();
            if (fields.length != 1 || fields.single != address) {
              throw StateError('Unexpected QA approval range');
            }
            for (final scope in model.detail!.scopes) {
              if (model.draft!.selected.contains(scope.id) !=
                  fields.contains(scope.fieldId)) {
                await tap(find.byKey(ValueKey('approval-scope-${scope.id}')));
              }
            }
          }
          await tap(
            find.byKey(
              ValueKey(
                'approval-${action == 'approve'
                    ? 'approve'
                    : action == 'deny'
                    ? 'deny'
                    : 'revoke'}',
              ),
            ),
          );
          final expected = action == 'approve'
              ? WorkspaceApprovalState.approved
              : action == 'deny'
              ? WorkspaceApprovalState.denied
              : WorkspaceApprovalState.revoked;
          await until(
            () =>
                !model.busy &&
                !model.reading &&
                model.detail?.request.state == expected,
          );
          expect(model.writeFailure, isNull);
          checks.add('native-ui-$action');
          if (action == 'approve' && screenshot == null) {
            await binding.endOfFrame;
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            try {
              screenshot = base64Encode(
                (await image.toByteData(
                  format: ui.ImageByteFormat.png,
                ))!.buffer.asUint8List(),
              );
            } finally {
              image.dispose();
            }
          }
        }
        await write('reply-${index + 1}.json', await status());
        index++;
      }
      expect(stopped, isTrue, reason: 'Driver must close the owned fixture');
      binding.reportData = {
        'passed': true,
        'runtime': {'platform': 'macos', 'debugMode': true},
        'checks': checks,
        'pid': pid,
        'imagePngBase64': screenshot,
        'scope':
            'real Codex host + package info-codex + native Debug owner widgets; synthetic key and framework input, not normal Release/Keychain/physical acceptance',
      };
    } finally {
      await t.pumpWidget(const SizedBox());
      await settle();
      if (!stopped && bootstrap.runtime != null) {
        await bootstrap.runtime!.stop();
      }
      await root.delete(recursive: true);
      binding.reportData?['fixtureRemoved'] = !await root.exists();
    }
  }, timeout: const Timeout(Duration(minutes: 16)));
}
