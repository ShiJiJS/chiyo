import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/tool_directory_access.dart';
import 'package:info_desktop/tool_directory_settings.dart';
import 'package:info_desktop/ui.dart';

const _original = ToolDirectorySnapshot([
  ToolDirectory('original', '工具 GH', '/目录 有空格/工具 GH', true),
]);
const _updated = ToolDirectorySnapshot([
  ToolDirectory('original', '新 GH', '/新目录/新 GH', true),
]);

class _Access implements ToolDirectoryAccess {
  ToolDirectorySnapshot snapshot = _original;
  Future<ToolDirectorySnapshot?> Function()? selection;
  bool failForget = false;
  int chooses = 0, forgets = 0;
  String? replacing;
  ToolDirectoryPermission? permission;

  @override
  Future<ToolDirectorySnapshot> read() async => snapshot;
  @override
  Future<ToolDirectorySnapshot?> choose({
    String? replacing,
    ToolDirectoryPermission permission = ToolDirectoryPermission.readOnly,
  }) async {
    chooses++;
    this.replacing = replacing;
    this.permission = permission;
    return selection?.call();
  }

  @override
  Future<ToolDirectorySnapshot> forget(String id) async {
    expect(id, 'original');
    forgets++;
    if (failForget) throw StateError('synthetic write failure');
    return snapshot = const ToolDirectorySnapshot([]);
  }
}

Future<void> _show(WidgetTester tester, _Access access) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: informationTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ToolDirectorySettings(access: access),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('choose cancellation and failure retain previous directory', (
    tester,
  ) async {
    final access = _Access();
    await _show(tester, access);
    await tester.tap(find.byKey(const ValueKey('choose-tool-directory')));
    await tester.pumpAndSettle();
    expect(find.text('工具 GH'), findsOneWidget);
    expect(find.text('目录访问未更新'), findsNothing);
    access.selection = () async => throw StateError('synthetic save failure');
    await tester.tap(find.byKey(const ValueKey('choose-tool-directory')));
    await tester.pumpAndSettle();
    expect(find.text('工具 GH'), findsOneWidget);
    expect(find.text('目录访问未更新'), findsOneWidget);
    expect(access.chooses, 2);
  });

  testWidgets(
    'unavailable directory is reselected by id and saves new status',
    (tester) async {
      final access = _Access()
        ..snapshot = const ToolDirectorySnapshot([
          ToolDirectory('original', '工具 GH', '/目录 有空格/工具 GH', false),
        ])
        ..selection = () async => _updated;
      await _show(tester, access);
      expect(find.textContaining('请重新选择。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reselect-tool-original')));
      await tester.pumpAndSettle();
      expect(access.replacing, 'original');
      expect(find.text('新 GH'), findsOneWidget);
      expect(find.text('目录访问已保存。使用凭据仍需另行申请并由你批准。'), findsOneWidget);
      expect(find.text('工具 GH'), findsNothing);
    },
  );

  testWidgets(
    'remove cancellation, failure and success preserve honest state',
    (tester) async {
      final access = _Access();
      await _show(tester, access);
      await tester.tap(find.byKey(const ValueKey('forget-tool-original')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(access.forgets, 0);
      access.failForget = true;
      await tester.tap(find.byKey(const ValueKey('forget-tool-original')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认移除'));
      await tester.pumpAndSettle();
      expect(find.text('工具 GH'), findsOneWidget);
      expect(find.text('目录访问未更新'), findsOneWidget);
      access.failForget = false;
      await tester.tap(find.byKey(const ValueKey('forget-tool-original')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认移除'));
      await tester.pumpAndSettle();
      expect(find.text('工具 GH'), findsNothing);
      expect(find.text('已移除保存的目录访问。'), findsOneWidget);
      expect(access.forgets, 2);
    },
  );

  testWidgets(
    'pending native panel disables concurrent changes and survives disposal',
    (tester) async {
      final pending = Completer<ToolDirectorySnapshot?>();
      final access = _Access()..selection = () => pending.future;
      await _show(tester, access);
      await tester.tap(find.byKey(const ValueKey('choose-tool-directory')));
      await tester.pump();
      for (final key in [
        'choose-tool-directory',
        'choose-working-directory',
        'change-tool-permission-original',
        'forget-tool-original',
        'reselect-tool-original',
      ]) {
        expect(
          tester.widget<TextButton>(find.byKey(ValueKey(key))).onPressed,
          isNull,
        );
      }
      expect(access.chooses, 1);
      await tester.pumpWidget(const SizedBox());
      pending.complete(_updated);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'corrupt archive disables writes and explains preserved storage',
    (tester) async {
      final access = _Access()
        ..snapshot = const ToolDirectorySnapshot([], storageUnavailable: true);
      await _show(tester, access);
      expect(find.text('目录设置无法读取'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('choose-tool-directory')),
            )
            .onPressed,
        isNull,
      );
      access.snapshot = _original;
      await tester.tap(find.text('刷新目录状态'));
      await tester.pumpAndSettle();
      expect(find.text('工具 GH'), findsOneWidget);
    },
  );

  testWidgets('narrow width and enlarged text show controls without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(380, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: informationTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.7)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: ToolDirectorySettings(access: _Access()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重新选择'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'native interface sends only entry ids; cancellation stays null',
    () async {
      const channel = MethodChannel('agent_info_manage/tool_directories');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'choose') return null;
        return {'storageUnavailable': false, 'directories': <Object>[]};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const access = NativeToolDirectoryAccess();
      expect((await access.read()).directories, isEmpty);
      expect(await access.choose(), isNull);
      expect(await access.choose(replacing: 'entry-id'), isNull);
      expect(
        await access.choose(permission: ToolDirectoryPermission.readWrite),
        isNull,
      );
      await access.forget('entry-id');
      expect(calls.map((call) => call.method), [
        'read',
        'choose',
        'choose',
        'choose',
        'forget',
      ]);
      expect(calls.map((call) => call.arguments), [
        null,
        {'permission': 'readOnly'},
        {'permission': 'readOnly', 'replacing': 'entry-id'},
        {'permission': 'readWrite'},
        'entry-id',
      ]);
    },
  );

  testWidgets(
    'owner explicitly selects read-write range and reselect retains it',
    (tester) async {
      final access = _Access()
        ..selection = () async => const ToolDirectorySnapshot([
          ToolDirectory(
            'original',
            '工作 项目',
            '/工作 项目',
            true,
            permission: ToolDirectoryPermission.readWrite,
          ),
        ]);
      await _show(tester, access);
      expect(find.textContaining('重开后恢复：读取。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('choose-working-directory')));
      await tester.pumpAndSettle();
      expect(access.permission, ToolDirectoryPermission.readWrite);
      expect(find.textContaining('重开后恢复：读取与写入。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reselect-tool-original')));
      await tester.pumpAndSettle();
      expect(access.permission, ToolDirectoryPermission.readWrite);
      expect(access.replacing, 'original');
      access.selection = () async => null;
      await tester.tap(
        find.byKey(const ValueKey('change-tool-permission-original')),
      );
      await tester.pumpAndSettle();
      expect(access.permission, ToolDirectoryPermission.readOnly);
      expect(find.textContaining('重开后恢复：读取与写入。'), findsOneWidget);
    },
  );

  test(
    'native ranges are explicit and unknown or absent modes fail closed',
    () {
      final row = <String, Object?>{
        'id': 'id',
        'name': 'folder',
        'path': '/folder',
        'available': true,
      };
      for (final permission in [null, 'readOnly', 'readWrite', 'unknown']) {
        final data = <Object?, Object?>{
          'storageUnavailable': false,
          'directories': [
            {...row, 'permission': ?permission},
          ],
        };
        if (permission == 'readOnly' || permission == 'readWrite') {
          expect(
            ToolDirectorySnapshot.fromNative(
              data,
            ).directories.single.permission.name,
            permission,
          );
        } else {
          expect(
            () => ToolDirectorySnapshot.fromNative(data),
            throwsFormatException,
          );
        }
      }
    },
  );

  test('malformed native state fails without presenting an empty success', () {
    for (final data in <Map<Object?, Object?>>[
      {},
      {'storageUnavailable': false, 'directories': null},
      {
        'storageUnavailable': false,
        'directories': [{}],
      },
      {'storageUnavailable': false, 'directories': List.filled(17, {})},
    ]) {
      expect(
        () => ToolDirectorySnapshot.fromNative(data),
        throwsFormatException,
      );
    }
  });
}
