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
  testWidgets('Mac encrypted removed-scope UI agrees with independent CLI', (
    tester,
  ) async {
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
      expect(result['ok'], isTrue, reason: 'Independent CLI assertions failed');
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
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final name =
          '$label-${theme.name}-${size.width.toInt()}-${(scale * 100).toInt()}.png';
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
    final fresh = restored.fields.singleWhere((f) => f.id != remaining.fieldId);
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
        AuthorizationHistory(owner: service.owner, initialRecordId: record.id),
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
    await File('${root.path}/result.json').writeAsString(
      jsonEncode({
        'complete': true,
        'encryptedRepository': true,
        'backupRestoreAndRepositoryReopen': true,
        'controlledOwnerMutations': true,
        'simulatedViewportAndTextScale': true,
        'physicalUiAcceptance': false,
        'captures': captures,
      }),
      flush: true,
    );
    await exchange('complete');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
