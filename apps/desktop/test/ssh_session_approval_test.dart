import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/approvals_controller.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import '../../../packages/info_core/test/fixtures/ssh_session_fixture.dart'
    show SshSessionFixture;

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 15; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pumpAndSettle();
}

Future<T> drive<T>(WidgetTester t, Future<T> Function() action) async {
  var done = false;
  T? result;
  Object? error;
  StackTrace? trace;
  action().then(
    (v) {
      result = v;
      done = true;
    },
    onError: (Object e, StackTrace st) {
      error = e;
      trace = st;
      done = true;
    },
  );
  for (var i = 0; i < 100 && !done; i++) {
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump(const Duration(milliseconds: 20));
  }
  expect(done, isTrue, reason: 'Owner transaction did not settle');
  if (error != null) Error.throwWithStackTrace(error!, trace!);
  return result as T;
}

void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    await Directory(evidence).create(recursive: true);
    await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'real SSH approval can choose session validity, retains a matching receipt and displays it in every history projection',
    (t) async {
      t.view.physicalSize = const Size(1100, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 11, 7);
      final root = (await t.runAsync(
        () => Directory.systemTemp.createTemp('ssh-session-ui-'),
      ))!;
      final repo = (await t.runAsync(
        () => EncryptedInformationRepository.open(
          root.path,
          _Keys(),
          clock: () => now,
        ),
      ))!;
      final f = (await t.runAsync(
        () => SshSessionFixture.create(clock: () => now, repository: repo),
      ))!;
      final source = OwnerWorkspaceSource(
        owner: f.service.owner,
        refreshInterval: Duration.zero,
      );
      final model = ApprovalsController(source.approvals, const Stream.empty());
      try {
        await t.runAsync(model.load);
        expect(model.detail!.credential!.supportsSessionValidity, isTrue);
        await t.pumpWidget(
          MaterialApp(
            theme: zhiyuTheme(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.4)),
              child: child!,
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('ssh-approval-capture'),
                child: ApprovalsPage(controller: model, onRecord: (_) {}),
              ),
            ),
          ),
        );
        await settle(t);
        final duration = find.byKey(const ValueKey('approval-credential-ttl'));
        await t.ensureVisible(duration);
        await t.tap(duration);
        await t.pumpAndSettle();
        await t.tap(find.text('不限时（限本聊天）').last);
        await settle(t);
        expect(model.draft!.credentialMinutes, isNull);
        final approve = find.byKey(const ValueKey('approval-approve'));
        await t.ensureVisible(approve);
        await t.tap(approve);
        await settle(t);
        expect(model.writeFailure, isNull);
        final saved = f.service.owner.credentialUseRequests.single;
        expect(saved.credentialValidity, core.CredentialUseValidity.session);
        expect(saved.credentialExpiresAt, isNull);
        expect(model.detail!.credentialSessionBound, isTrue);
        expect(find.text('凭据：不限时（限本聊天）'), findsOneWidget);
        if (evidence.isNotEmpty) {
          final boundary = t.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('ssh-approval-capture')),
          );
          await t.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1),
                bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '$evidence/ssh-session-approved-dark-narrow.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(
          model.detail!
              .withExecution(
                WorkspaceApprovalExecution(
                  requestId: saved.id,
                  grantId: saved.id,
                  operationId: 'unused',
                  credential: model.detail!.credential!,
                  plan: model.detail!.credential!.receiver,
                  createdAt: now,
                  state: WorkspaceExecutionState.preparing,
                  processStarted: false,
                  processEnded: false,
                  cleanup: WorkspaceExecutionCleanup.notNeeded,
                  revision: 1,
                ),
              )
              .credentialSessionBound,
          isTrue,
        );
        now = now.add(const Duration(days: 2));
        final history = (await drive(
          t,
          () => source.grantHistory.read('request:${saved.id}'),
        ))!;
        expect(history.credentialSessionBound, isTrue);
        expect(history.credentialExpiresAt, isNull);
        expect(history.canRevoke, isTrue);
        final credentialHistory = (await drive(
          t,
          () => source.credentials.history(
            WorkspaceRecordRef(
              WorkspaceRecordKind.credential,
              saved.credentialId,
            ),
          ),
        ))!;
        expect(credentialHistory.single.expiresAt, isNull);
        final detail = (await drive(t, () => source.approvals.read(saved.id)))!;
        final revoke = WorkspaceApprovalChange(
          operationId: workspaceOperationId(),
          requestId: saved.id,
          reviewToken: detail.reviewToken,
          action: WorkspaceApprovalAction.revoke,
        );
        final receipt = await drive(t, () => source.approvals.change(revoke));
        expect(receipt.operationId, revoke.operationId);
        expect(
          f.service.owner.credentialGrantState(
            f.service.owner.credentialUseRequests.single,
          ),
          'revoked',
        );
        expect(
          (await drive(t, () => source.approvals.change(revoke))).operationId,
          receipt.operationId,
        );
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        model.dispose();
        await drive(t, source.dispose);
        var closed = false;
        final closing = f.service.close().then((_) => closed = true);
        for (var i = 0; i < 100 && !closed; i++) {
          await drive(t, () => Future<void>.delayed(Duration.zero));
          await t.pump(const Duration(milliseconds: 10));
        }
        expect(closed, isTrue);
        await closing;
        await drive(t, repo.close);
        await drive(t, () => root.delete(recursive: true));
      }
    },
  );
}
