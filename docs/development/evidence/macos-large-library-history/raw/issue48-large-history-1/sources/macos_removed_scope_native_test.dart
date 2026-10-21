import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/approvals.dart';
import 'package:info_desktop/history.dart';
import 'package:info_desktop/main.dart' show InformationApp;
import 'package:info_desktop/ui.dart';
import 'support/native_semantics_lifetime.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

// Real Mac Flutter/SQLCipher; mutations and owner approvals are controlled.
// A separate parent-owned AOT CLI performs reads through the actual HTTP server.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac encrypted removed-scope UI agrees with independent CLI',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      const ownerMarker = String.fromEnvironment('MAC_QA_OWNER');
      expect(ownerMarker, matches(RegExp(r'^[a-f0-9]{32}$')));
      final root = await Directory.systemTemp.createTemp('aim-mac-scope-ui-');
      await File('${root.path}/.qa-owner').writeAsString(ownerMarker);
      debugPrint('MAC_SCOPE_ROOT=${root.path}');
      final semantics = NativeSemanticsLifetime(tester);
      final previousShadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = previousShadows);
      final sourceKeys = _Keys(), targetKeys = _Keys();
      var repository = await EncryptedInformationRepository.open(
        '${root.path}/source',
        sourceKeys,
      );
      var service = InformationService(repository: repository);
      var server = await AgentServer.start(service.agent, port: 0);
      final boundary = GlobalKey();
      final captures = <Map<String, Object>>[];
      var step = 0;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await server.close();
        await service.close();
        await repository.close();
        semantics.finishAfterUnmount();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      Future<Map<String, dynamic>> exchange(
        String phase, [
        Map<String, Object?> extra = const {},
      ]) async {
        step++;
        await File('${root.path}/phase-$step.json').writeAsString(
          jsonEncode({'phase': phase, 'port': server.port, ...extra}),
          flush: true,
        );
        final reply = File('${root.path}/reply-$step.json');
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (!await reply.exists()) {
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'External CLI driver deadline',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final result =
            jsonDecode(await reply.readAsString()) as Map<String, dynamic>;
        expect(
          result['ok'],
          isTrue,
          reason: 'Independent CLI assertions failed',
        );
        return result;
      }

      Future<void> show(
        String label,
        Widget body,
        DesktopColorTheme theme,
        Size size,
        double scale,
        List<String> expected,
        List<String> ids,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              key: UniqueKey(),
              theme: informationTheme(theme),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(body: body),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final text in expected) {
          expect(find.text(text), findsWidgets);
        }
        final visible = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .join('\n');
        expect(visible, isNot(contains('synthetic-private-')));
        for (final id in ids) {
          expect(visible, isNot(contains(id)));
        }
        expect(
          find.textContaining('可读取'),
          findsNothing,
          reason: 'History must not claim expired or removed scope is readable',
        );
        expect(tester.takeException(), isNull);
        if (label == 'archived-history') {
          final count = find.text('11 次访问');
          expect(count, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(count);
          final boxes = paragraph.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 6),
          );
          expect(
            boxes.map((b) => b.top).toSet(),
            hasLength(1),
            reason: 'An ordinary access count must remain one readable phrase',
          );
        }
        Future<void> capture(String suffix) async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final name =
              '$label-${theme.name}-${size.width.toInt()}-${(scale * 100).toInt()}$suffix.png';
          await File(
            '${root.path}/$name',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          captures.add({
            'file': name,
            'width': size.width.toInt(),
            'height': size.height.toInt(),
            'textScale': scale,
          });
        }

        await capture('');
        // Reach the field labels by scrolling the real document, including 200%.
        final scopeNames = find.textContaining('服务器地址');
        await tester.ensureVisible(scopeNames);
        await tester.pumpAndSettle();
        expect(scopeNames.hitTestable(), findsWidgets);
        if (scale == 2) await capture('-scope-scrolled');
        final isPartial = label == 'partial-history';
        await tester.tap(find.byKey(const ValueKey('history-filter-1')));
        await tester.pumpAndSettle();
        expect(find.text('没有匹配的内容'), isPartial ? findsNothing : findsOneWidget);
        if (isPartial) {
          expect(find.text('部分字段已移除'), findsOneWidget);
        }
        await tester.tap(find.byKey(const ValueKey('history-filter-2')));
        await tester.pumpAndSettle();
        expect(find.text('没有匹配的内容'), isPartial ? findsOneWidget : findsNothing);
        expect(tester.takeException(), isNull);
      }

      final item = await service.owner
          .createInformation('合成服务器 · 授权范围核对', '公开说明', const [
            FieldInput('服务器地址', '连接目标', 'synthetic-private-address'),
            FieldInput('登录账号', '合成账户', 'synthetic-private-account'),
          ]);
      final old = FieldRef(item.id, item.fields.first.id),
          remaining = FieldRef(item.id, item.fields.last.id);
      final first = await exchange('request', {
        'itemId': item.id,
        'oldField': old.fieldId,
        'remainingField': remaining.fieldId,
      });
      final requestId = first['requestId'] as String;
      service.owner.approve(requestId, [old, remaining]);
      final record = (await service.owner.history()).grants.single;
      await exchange('approved');
      final recycled = await service.owner.deleteInformation(
        item.id,
        item.version,
        fieldId: old.fieldId,
      );
      await exchange('partial');
      for (final theme in DesktopColorTheme.values) {
        for (final view in [
          (const Size(1440, 900), 1.0),
          (const Size(1280, 800), 2.0),
        ]) {
          await show(
            'partial-history',
            AuthorizationHistory(
              owner: service.owner,
              initialRecordId: record.id,
            ),
            theme,
            view.$1,
            view.$2,
            ['部分字段已移除', '服务器地址（原字段已移除）、登录账号'],
            [old.itemId, old.fieldId],
          );
        }
      }
      final restored = await service.owner.restoreRecycled(recycled.id);
      final fresh = restored.fields.singleWhere(
        (f) => f.id != remaining.fieldId,
      );
      expect(fresh.id, isNot(old.fieldId));
      final freshReply = await exchange('restored', {'freshField': fresh.id});
      final freshRequestId = freshReply['requestId'] as String;
      service.owner.approve(freshRequestId, [FieldRef(item.id, fresh.id)]);
      await exchange('reapproved');
      // Inspect handled approval separately: its explanatory text says "不可读取".
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: Approvals(
              service: service,
              port: server.port,
              focusRequestId: requestId,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('原字段已移除，旧授权不可读取'), findsOneWidget);
      expect(find.text('服务器地址'), findsWidgets);
      expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .join('\n'),
        isNot(contains(old.fieldId)),
      );
      expect(tester.takeException(), isNull);
      await service.owner.deleteInformation(item.id, restored.version);
      await exchange('all-removed');
      await show(
        'all-removed-history',
        AuthorizationHistory(owner: service.owner, initialRecordId: record.id),
        DesktopColorTheme.purple,
        const Size(1440, 900),
        1,
        ['范围已失效', '原字段已移除'],
        [old.fieldId, remaining.fieldId],
      );
      final recovery = await repository.backups.enable();
      await repository.backups.saveRecoveryKeyTo(
        '${root.path}/synthetic-recovery.txt',
      );
      final backup = '${root.path}/synthetic.aimbackup';
      await service.owner.exportLibrary(
        () => repository.backups.exportTo(backup),
      );
      await tester.pumpWidget(const SizedBox());
      await server.close();
      await service.close();
      await repository.close();
      sourceKeys.value!.fillRange(0, sourceKeys.value!.length, 0);
      sourceKeys.value = null;
      repository = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        targetKeys,
      );
      service = InformationService(repository: repository);
      final preview = await repository.backups.inspect(backup, recovery);
      await service.owner.restoreLibrary(
        () => repository.backups.restore(preview),
      );
      server = await AgentServer.start(service.agent, port: 0);
      await exchange('archived');
      for (final theme in DesktopColorTheme.values) {
        await show(
          'archived-history',
          AuthorizationHistory(
            owner: service.owner,
            initialRecordId: record.id,
          ),
          theme,
          const Size(1280, 800),
          2,
          ['历史归档 · 未授权'],
          [old.fieldId, remaining.fieldId],
        );
      }
      await tester.pumpWidget(const SizedBox());
      await server.close();
      await service.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        targetKeys,
      );
      service = InformationService(repository: repository);
      server = await AgentServer.start(service.agent, port: 0);
      expect(repository.grantHistory, hasLength(2));
      expect(repository.grantHistory.every((g) => !g.active), isTrue);
      await exchange('repository-reopened');
      await show(
        'reopened-history',
        AuthorizationHistory(owner: service.owner, initialRecordId: record.id),
        DesktopColorTheme.green,
        const Size(1440, 900),
        1,
        ['历史归档 · 未授权'],
        [old.fieldId],
      );
      await tester.pumpWidget(const SizedBox());
      const large = bool.fromEnvironment('MAC_QA_LARGE');
      const fieldCount = large ? 200 : 24;
      const extraRecords = large ? 500 : 17;
      const recordCount = extraRecords + 2;
      final pageCount = (recordCount / 8).ceil();
      final seedTime = Stopwatch()..start();
      final many = await service.owner.createInformation(
        '多字段分页资料',
        '受控合成资料',
        List.generate(
          fieldCount,
          (i) => FieldInput('字段${i + 1}', '公开说明', 'synthetic-private-$i'),
        ),
      );
      final pageSession = service.agent.openSession('分页与长记录合成会话');
      String? largeRequest;
      for (var i = 0; i < extraRecords; i++) {
        final refs = (large && i != 8 ? many.fields.take(1) : many.fields)
            .map((f) => FieldRef(many.id, f.id))
            .toList();
        final request = service.agent.request(
          pageSession,
          '分页合成${i.toString().padLeft(large ? 3 : 2, '0')}：${List.filled(large ? 80 : 8, '核对多字段申请的完整范围与历史记录').join('；')}',
          refs,
        );
        if (large && i == 8) {
          largeRequest = request.id;
        } else {
          service.owner.approve(request.id, refs);
        }
      }
      seedTime.stop();
      if (large) {
        tester.view.physicalSize = const Size(1280, 800);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: InformationApp(
              key: UniqueKey(),
              service: service,
              port: server.port,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('inbox-filter-pending')));
        await tester.pumpAndSettle();
        final last = find.byKey(ValueKey('field-${many.fields.last.id}'));
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        final approval = find.byKey(const ValueKey('approve-selection'));
        await tester.ensureVisible(approval);
        await tester.pumpAndSettle();
        expect(approval.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${root.path}/large-request-200-percent.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        captures.add({
          'file': 'large-request-200-percent.png',
          'width': 1280,
          'height': 800,
          'textScale': 2.0,
        });
        await tester.tap(approval);
        await tester.pumpAndSettle();
        final decided = service.owner.requests.firstWhere(
          (r) => r.id == largeRequest,
        );
        expect(decided.approvedFields, hasLength(fieldCount));
        await exchange('large-approved', {
          'fieldCount': fieldCount,
          'approvedCount': decided.approvedFields!.length,
        });
        await tester.pumpWidget(const SizedBox());
      }
      await service.owner.setColorTheme(DesktopColorTheme.green);
      for (final view in [
        (const Size(1440, 900), 1.0),
        (const Size(1280, 800), 2.0),
      ]) {
        tester.view.physicalSize = view.$1;
        tester.platformDispatcher.textScaleFactorTestValue = view.$2;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: InformationApp(
              key: UniqueKey(),
              service: service,
              port: server.port,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('nav-3')));
        await tester.pumpAndSettle();
        expect(find.text('$recordCount 条记录'), findsOneWidget);
        for (var page = 1; page <= pageCount; page++) {
          expect(find.text('$page / $pageCount'), findsOneWidget);
          final next = tester.widget<TextButton>(
            find.ancestor(
              of: find.text('›'),
              matching: find.byType(TextButton),
            ),
          );
          expect(next.onPressed == null, page == pageCount);
          if (page < pageCount) {
            await tester.tap(find.text('›'));
            await tester.pumpAndSettle();
          }
        }
        await tester.enterText(
          find.byKey(const ValueKey('history-search')),
          large ? '分页合成008' : '分页合成08',
        );
        await tester.pumpAndSettle();
        expect(find.text('1 条记录'), findsOneWidget);
        expect(find.text('1 / 1'), findsOneWidget);
        expect(find.text('$fieldCount'), findsOneWidget);
        Future<void> captureFullApp(String suffix) async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final name =
              'full-app-history-search-${view.$1.width.toInt()}-${(view.$2 * 100).toInt()}$suffix.png';
          await File(
            '${root.path}/$name',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          captures.add({
            'file': name,
            'width': view.$1.width.toInt(),
            'height': view.$1.height.toInt(),
            'textScale': view.$2,
          });
        }

        expect(tester.takeException(), isNull);
        await captureFullApp('');
        final fields = find.textContaining('字段$fieldCount');
        await tester.ensureVisible(fields);
        await tester.pumpAndSettle();
        expect(fields.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureFullApp('-scope-scrolled');
        await tester.enterText(
          find.byKey(const ValueKey('history-search')),
          '',
        );
        await tester.pumpAndSettle();
        expect(find.text('$recordCount 条记录'), findsOneWidget);
        expect(find.text('1 / $pageCount'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      if (large) {
        await server.close();
        await service.close();
        await repository.close();
        repository = await EncryptedInformationRepository.open(
          '${root.path}/restored',
          targetKeys,
        );
        service = InformationService(repository: repository);
        server = await AgentServer.start(service.agent, port: 0);
        expect(repository.grantHistory, hasLength(recordCount));
        expect(repository.grantHistory.every((g) => !g.active), isTrue);
        expect(
          repository.grantHistory.where((g) => g.fields.length == fieldCount),
          hasLength(1),
        );
        await exchange('scale-reopened', {
          'records': recordCount,
          'fieldCount': fieldCount,
        });
      }
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'complete': true,
          'encryptedRepository': true,
          'backupRestoreAndRepositoryReopen': true,
          'controlledOwnerMutations': true,
          'simulatedViewportAndTextScale': true,
          'physicalUiAcceptance': false,
          'countPhraseSingleLineAt200Percent': true,
          'fullAppHistoryPagination': {
            'records': recordCount,
            'pages': pageCount,
            'fields': fieldCount,
            'seedWallMilliseconds': seedTime.elapsedMilliseconds,
            'longRequestApprovedThroughUi': large,
            'largeHistoryReopened': large,
            'searchAndClear': true,
            'globalNavigationIncluded': true,
          },
          'captures': captures,
        }),
        flush: true,
      );
      await exchange('complete');
    },
    // NativeSemanticsLifetime tracks only handles requested by the platform.
    // The framework's default test handle is disposed before addTearDown runs.
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
