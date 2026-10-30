// Full owner UI + shipped CLI check, driven by scripts/qa/check-owner-ui.py.
// SQLCipher and HTTP are real; OS platform and widget input are test fixtures.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/workspace/approvals_page.dart';
import 'package:info_desktop/workspace/grant_history_page.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import '../test/support/desktop_platform_fixture.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.generate(32, (i) => i + 17);
  @override
  Future<void> create(List<int> _) async => throw StateError('test key only');
}

class _Cli {
  _Cli(this.process) {
    lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    errors = process.stderr.transform(utf8.decoder).join();
  }
  final Process process;
  late final StreamIterator<String> lines;
  late final Future<String> errors;
  Future<Map<String, dynamic>> command(Map<String, Object?> value) async {
    process.stdin.writeln(jsonEncode(value));
    await process.stdin.flush();
    expect(await lines.moveNext().timeout(const Duration(seconds: 15)), isTrue);
    final result = jsonDecode(lines.current) as Map<String, dynamic>;
    for (final key in ['token', 'sessionSecret', 'endCapability']) {
      expect(result.containsKey(key), isFalse);
    }
    return result;
  }

  Future<void> close() async {
    await process.stdin.close();
    try {
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      rethrow;
    } finally {
      await lines.cancel();
    }
    expect(await errors, isEmpty);
  }
}

void main() {
  testWidgets(
    'full owner shell shares actual requests and history with shipped CLI',
    (t) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      // Service audit work can be queued in the widget zone. Start I/O in
      // the real zone, then advance both clocks instead of blocking either.
      Future<T> real<T>(Future<T> Function() action) async {
        var complete = false;
        Object? result, error;
        StackTrace? trace;
        await t.runAsync(() async {
          unawaited(
            Future<T>.sync(action).then(
              (value) {
                result = value;
                complete = true;
              },
              onError: (Object e, StackTrace s) {
                error = e;
                trace = s;
                complete = true;
              },
            ),
          );
        });
        final elapsed = Stopwatch()..start();
        while (!complete && elapsed.elapsed < const Duration(seconds: 20)) {
          await t.pump(const Duration(milliseconds: 20));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        if (!complete) {
          throw TimeoutException('Owner UI test I/O did not settle');
        }
        if (error != null) Error.throwWithStackTrace(error!, trace!);
        return result as T;
      }

      final root = Directory(Platform.environment['OWNER_UI_ROOT']!);
      final phase = Platform.environment['OWNER_UI_PHASE']!;
      final executable = Platform.environment['OWNER_UI_CLI']!;
      expect(
        await real(() => File('${root.path}/fixture-marker').readAsString()),
        'disposable-owner-ui-v1',
      );
      expect(['live', 'reopen'], contains(phase));
      final metadata = File('${root.path}/identities.json');
      final state = phase == 'live'
          ? <String, dynamic>{}
          : jsonDecode(await real(metadata.readAsString))
                as Map<String, dynamic>;
      debugPrint('UI fixture: open encrypted repository');
      final repo = await real(
        () => EncryptedInformationRepository.open(
          '${root.path}/library',
          _Keys(),
        ),
      );
      final service = core.InformationService(repository: repo);
      final bootstrap = DesktopBootstrap(
        port: 0,
        platform: NativeDesktopFixture(),
        openLibrary: () async => DesktopLibrary(
          service: service,
          backups: repo.backups,
          close: repo.close,
        ),
      );
      final clients = <_Cli>[];
      final checks = <String>[];
      final clientPids = <int>[];
      Future<void> settleFrames() async {
        final elapsed = Stopwatch()..start();
        do {
          await t.pump(const Duration(milliseconds: 100));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          expect(t.takeException(), isNull);
          if (!t.binding.hasScheduledFrame) return;
        } while (elapsed.elapsed < const Duration(seconds: 15));
        fail('Owner UI frames did not settle while real I/O was allowed');
      }

      Future<void> until(bool Function() done, String description) async {
        debugPrint('UI step: $description');
        for (var i = 0; i < 200; i++) {
          await t.pump(const Duration(milliseconds: 100));
          await real(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          expect(t.takeException(), isNull);
          if (done()) {
            await settleFrames();
            expect(t.takeException(), isNull);
            return;
          }
        }
        fail('Owner UI did not reach: $description');
      }

      Future<void> tap(Finder target) async {
        await t.ensureVisible(target);
        await t.tap(target);
        await settleFrames();
        expect(t.takeException(), isNull);
      }

      Future<void> enter(String key, String value) async {
        final field = find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(TextField),
        );
        await t.ensureVisible(field);
        await t.enterText(field, value);
        await settleFrames();
      }

      Future<_Cli> startClient() async {
        final c = await real(
          () async => _Cli(
            await Process.start(executable, [
              '--port',
              '${bootstrap.boundPort}',
            ]),
          ),
        );
        clients.add(c);
        clientPids.add(c.process.pid);
        expect(
          (await real(
            () => c.command({'command': 'session', 'chatLabel': '合成界面聊天'}),
          ))['status'],
          'ok',
        );
        return c;
      }

      Future<Map<String, dynamic>> read(_Cli c, String request, String field) =>
          real(
            () => c.command({
              'command': 'read',
              'requestId': request,
              'itemId': state['item'],
              'fieldId': field,
            }),
          );
      Future<String> request(_Cli c, String operation) async {
        final r = await real(
          () => c.command({
            'command': 'request',
            'operationId': operation,
            'purpose': '合成界面验收',
            'fields': [
              for (final key in ['host', 'user'])
                {'itemId': state['item'], 'fieldId': state[key]},
            ],
          }),
        );
        expect(r['status'], 'pending');
        return r['requestId'] as String;
      }

      ApprovalsPage approvals() =>
          t.widget<ApprovalsPage>(find.byType(ApprovalsPage));
      GrantHistoryPage history() =>
          t.widget<GrantHistoryPage>(find.byType(GrantHistoryPage));
      Future<void> selectRequest(String id) async {
        await tap(find.byKey(const ValueKey('workspace-nav-approvals')));
        await until(
          () =>
              find.byKey(ValueKey('approval-select-$id')).evaluate().isNotEmpty,
          'requested inbox row',
        );
        await tap(find.byKey(ValueKey('approval-select-$id')));
        await until(
          () =>
              approvals().controller.detail?.request.id == id &&
              !approvals().controller.reading,
          'exact request detail',
        );
      }

      try {
        debugPrint('UI fixture: start real service');
        await real(bootstrap.start);
        expect(bootstrap.state, DesktopStartupState.ready);
        await t.pumpWidget(
          DesktopLauncher(bootstrap: bootstrap, useWorkspace: true),
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
          'formal library',
        );
        if (phase == 'live') {
          expect(repo.items, isEmpty);
          await tap(find.byTooltip('添加资料').first);
          await tap(find.text('服务器信息').last);
          await enter('library-edit-name', '界面合成服务器');
          await enter('library-edit-host', 'UI-HOST');
          await enter('library-edit-user', 'UI-USER');
          await tap(find.byKey(const ValueKey('library-edit-save')));
          await until(
            () =>
                repo.items.length == 1 &&
                t
                        .widget<LibraryPage>(find.byType(LibraryPage))
                        .controller
                        .detail !=
                    null &&
                find
                    .byKey(const ValueKey('library-edit-save'))
                    .evaluate()
                    .isEmpty,
            'saved real server',
          );
          final detail = t
              .widget<LibraryPage>(find.byType(LibraryPage))
              .controller
              .detail!;
          state.addAll({
            'item': detail.record.ref.id,
            'host': detail.fieldIds['host'],
            'user': detail.fieldIds['user'],
          });
          checks.add('formal-shell-creates-real-encrypted-record');
          final c = await startClient();
          final other = await startClient();
          final catalog = await real(
            () => c.command({'command': 'catalog', 'query': '界面合成服务器'}),
          );
          expect(catalog['total'], 1);
          expect(jsonEncode(catalog), isNot(contains('UI-HOST')));
          final r = await request(c, 'ui-partial');
          expect(
            (await read(c, r, state['host'] as String))['status'],
            'unauthorized',
          );
          await selectRequest(r);
          final model = approvals().controller;
          final excluded = model.detail!.scopes.singleWhere(
            (s) => s.fieldId == state['user'],
          );
          await tap(find.byKey(ValueKey('approval-scope-${excluded.id}')));
          expect(model.draft!.selected, hasLength(1));
          await tap(find.byKey(const ValueKey('approval-approve')));
          await until(
            () =>
                model.detail?.request.state ==
                    WorkspaceApprovalState.approved &&
                !model.frozen &&
                !model.reading &&
                !model.loading,
            'actual partial approval',
          );
          expect(model.writeFailure, isNull);
          expect(
            (await real(
              () => c.command({'command': 'claim', 'requestId': r}),
            ))['status'],
            'ok',
          );
          expect(
            (await read(c, r, state['host'] as String))['value'],
            'UI-HOST',
          );
          expect(
            (await read(c, r, state['user'] as String))['status'],
            'unauthorized',
          );
          expect(
            (await real(
              () => other.command({'command': 'claim', 'requestId': r}),
            ))['status'],
            'unauthorized',
          );
          checks.addAll([
            'external-cli-request-shows-in-full-inbox',
            'ui-partial-approval-and-cross-chat-denial',
          ]);
          final deadline = model.detail!.fieldExpiresAt;
          await tap(find.byKey(const ValueKey('workspace-nav-library')));
          await until(
            () =>
                t
                    .widget<LibraryPage>(find.byType(LibraryPage))
                    .controller
                    .detail
                    ?.record
                    .ref
                    .id ==
                state['item'],
            'return to original record',
          );
          await tap(find.text('编辑信息').first);
          await enter('library-edit-host', 'UI-CORRECTED-HOST');
          await tap(find.byKey(const ValueKey('library-edit-save')));
          await until(
            () =>
                find
                    .byKey(const ValueKey('library-edit-save'))
                    .evaluate()
                    .isEmpty &&
                t
                        .widget<LibraryPage>(find.byType(LibraryPage))
                        .controller
                        .detail
                        ?.values['host'] ==
                    'UI-CORRECTED-HOST',
            'UI correction persisted',
          );
          expect(
            t
                .widget<LibraryPage>(find.byType(LibraryPage))
                .controller
                .detail!
                .fieldIds['host'],
            state['host'],
          );
          expect(
            (await read(c, r, state['host'] as String))['value'],
            'UI-CORRECTED-HOST',
          );
          await selectRequest(r);
          expect(approvals().controller.detail!.fieldExpiresAt, deadline);
          checks.add('ui-edit-preserves-field-identity-and-fixed-grant');
          await tap(find.text('查看授权历史'));
          await until(
            () =>
                find.byType(GrantHistoryPage).evaluate().isNotEmpty &&
                history().controller.detail?.summary.requestId == r &&
                !history().controller.reading &&
                !history().controller.loading,
            'exact history navigation',
          );
          expect(history().controller.detail!.summary.operationCount, 3);
          await read(c, r, state['host'] as String);
          await until(
            () => history().controller.detail?.summary.operationCount == 4,
            'history refresh after actual second read',
          );
          expect(find.text('UI-HOST'), findsNothing);
          checks.add('history-target-and-live-access-count');
          final recordKey = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            state['item'] as String,
          ).key;
          await tap(find.byKey(ValueKey('grant-snapshot-$recordKey')));
          await until(
            () => find.text('UI-HOST').evaluate().isNotEmpty,
            'approval snapshot retains original value',
          );
          expect(find.text('UI-CORRECTED-HOST'), findsNothing);
          await tap(find.text('关闭').last);
          checks.add('history-snapshot-uses-approval-version-after-ui-edit');
          await tap(find.byKey(const ValueKey('grant-revoke')));
          await until(
            () =>
                history().controller.detail?.summary.state ==
                    WorkspaceGrantState.revoked &&
                !history().controller.frozen,
            'history revoke',
          );
          expect(history().controller.decisionFailure, isNull);
          expect(
            (await read(c, r, state['host'] as String))['status'],
            'unauthorized',
          );
          await tap(find.byKey(const ValueKey('grant-request')));
          await until(
            () =>
                find.byType(ApprovalsPage).evaluate().isNotEmpty &&
                approvals().controller.detail?.request.id == r &&
                approvals().controller.detail?.request.state ==
                    WorkspaceApprovalState.revoked,
            'original revoked approval',
          );
          checks.add('history-revoke-and-original-request-return');
          final denied = await request(c, 'ui-deny');
          await selectRequest(denied);
          await tap(find.byKey(const ValueKey('approval-deny')));
          await until(
            () =>
                approvals().controller.detail?.request.state ==
                    WorkspaceApprovalState.denied &&
                !approvals().controller.frozen,
            'deny from full shell',
          );
          expect(
            (await real(
              () => c.command({'command': 'claim', 'requestId': denied}),
            ))['status'],
            'denied',
          );
          checks.add('ui-denial-observed-by-external-cli');
          final live = await request(c, 'ui-left-active');
          await selectRequest(live);
          await tap(find.byKey(const ValueKey('approval-approve')));
          await until(
            () =>
                approvals().controller.detail?.request.state ==
                    WorkspaceApprovalState.approved &&
                !approvals().controller.frozen,
            'active grant before shutdown',
          );
          state['activeRequest'] = live;
          state['requestCount'] = 3;
          await real(() => metadata.writeAsString(jsonEncode(state)));
        } else {
          expect(repo.items.single.id, state['item']);
          expect(
            repo.items.single.fields
                .singleWhere((f) => f.id == state['host'])
                .value,
            'UI-CORRECTED-HOST',
          );
          expect(find.text('界面合成服务器'), findsWidgets);
          final recordKey = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            state['item'] as String,
          ).key;
          await tap(find.byKey(ValueKey('library-record-$recordKey')));
          await until(
            () =>
                t
                    .widget<LibraryPage>(find.byType(LibraryPage))
                    .controller
                    .detail
                    ?.values['host'] ==
                'UI-CORRECTED-HOST',
            'reopened UI displays corrected saved content',
          );
          expect(find.text('UI-CORRECTED-HOST'), findsWidgets);
          await tap(find.byKey(const ValueKey('workspace-nav-history')));
          await until(
            () =>
                find.byType(GrantHistoryPage).evaluate().isNotEmpty &&
                history().controller.results?.total == state['requestCount'] &&
                !history().controller.loading,
            'durable history in reopened UI',
          );
          final target = 'request:${state['activeRequest']}';
          await tap(find.byKey(ValueKey('grant-row-$target')));
          await until(
            () =>
                history().controller.detail?.summary.id == target &&
                !history().controller.reading,
            'exact ended history',
          );
          expect(
            history().controller.detail!.summary.state,
            WorkspaceGrantState.sessionEnded,
          );
          final c = await startClient();
          expect(
            (await real(
              () => c.command({
                'command': 'claim',
                'requestId': state['activeRequest'],
              }),
            ))['status'],
            'unauthorized',
          );
          checks.addAll([
            'independent-owner-process-renders-saved-data-and-history',
            'reopened-history-does-not-restore-old-grant',
          ]);
        }
        await t.pumpWidget(const SizedBox());
        await settleFrames();
        await real(() => bootstrap.runtime!.stop());
        expect(service.owner.serviceAvailable, isFalse);
        checks.add('formal-runtime-stops-service-and-closes-database');
        await real(
          () => File('${root.path}/$phase-result.json').writeAsString(
            jsonEncode({
              'passed': true,
              'phase': phase,
              'pid': pid,
              'cliPids': clientPids,
              'checks': checks,
              'scope':
                  'full Flutter shell/widget input + SQLCipher + shipped CLI; platform fixture, not native or AI host acceptance',
            }),
          ),
        );
      } finally {
        await t.pumpWidget(const SizedBox());
        await settleFrames();
        for (final c in clients) {
          await real(c.close);
        }
        await real(() => bootstrap.runtime?.stop() ?? Future<void>.value());
        bootstrap.runtime?.dispose();
        bootstrap.dispose();
      }
    },
  );
}
