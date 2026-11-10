import 'support/workspace_fixtures.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_credential.dart';
import 'package:info_desktop/workspace/library_widgets.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/preview_workspace.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const ssh = WorkspaceRecordRef(WorkspaceRecordKind.credential, 'sshkey');
const azure = WorkspaceRecordRef(WorkspaceRecordKind.information, 'azure');
const aliyun = WorkspaceRecordRef(WorkspaceRecordKind.information, 'aliyun');
void main() {
  const evidence = String.fromEnvironment('UI_EVIDENCE_DIR');
  setUpAll(() async {
    if (evidence.isEmpty) return;
    final fonts = await loadDesktopFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await Directory(evidence).create(recursive: true);
    await File('$evidence/fonts.json').writeAsString(jsonEncode(fonts));
  });
  void check(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (t) async {
        final shadows = debugDisableShadows;
        try {
          if (evidence.isNotEmpty) debugDisableShadows = false;
          await body(t);
        } finally {
          debugDisableShadows = shadows;
        }
      });
  Future<void> tap(WidgetTester t, Finder finder) async {
    if (await prepareFixtureAction(t, finder)) return;
    await t.ensureVisible(finder);
    await t.pumpAndSettle();
    await t.tap(finder);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }

  Future<void> enter(WidgetTester t, Finder finder, String value) async {
    await t.ensureVisible(finder);
    await t.pumpAndSettle();
    await t.enterText(finder, value);
    await t.pumpAndSettle();
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (evidence.isEmpty) return;
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('credential-capture')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<LibraryController> start(
    WidgetTester t,
    String name, {
    bool dark = false,
    double scale = 1,
    double width = 1440,
  }) async {
    t.view.physicalSize = Size(width, width == 1440 ? 900 : 800);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      const RepaintBoundary(
        key: ValueKey('credential-capture'),
        child: PreviewWorkspace(inputsBuilder: fixtureInputs),
      ),
    );
    await t.pumpAndSettle();
    if (dark) {
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-theme-dark')));
    }
    await tap(t, find.byKey(const ValueKey('library-directory-all')));
    await enter(t, find.byKey(const ValueKey('library-search')), name);
    final model = t.widget<LibraryPage>(find.byType(LibraryPage)).controller;
    final ref = model.results!.items.singleWhere((r) => r.name == name).ref;
    await tap(t, find.byKey(ValueKey('library-record-${ref.key}')));
    expect(find.byType(LibraryCredential), findsOneWidget);
    expect(t.takeException(), isNull);
    return model;
  }

  Finder textValue(String value) => find.byWidgetPredicate(
    (w) =>
        w is SelectableText &&
        (w.data ?? w.textSpan?.toPlainText() ?? '').contains(value),
  );

  check(
    'credential management reads Agent-origin requests without an owner request action',
    (t) async {
      final model = await start(t, 'Azure SSH 私钥');
      expect(textValue('••••••••'), findsOneWidget);
      expect(textValue('SSH_KEY_FILE'), findsNothing);
      await tap(t, find.byKey(const ValueKey('credential-advanced')));
      expect(textValue('SSH_KEY_FILE'), findsOneWidget);
      await capture(t, 'credential-1440-light-reading');
      await tap(t, find.byKey(const ValueKey('credential-history')));
      expect(find.text('核对连接状态'), findsOneWidget);
      expect(find.text('查询后续服务状态'), findsOneWidget);
      expect(find.textContaining('已到期'), findsOneWidget);
      await capture(t, 'credential-1440-light-history');
      await tap(t, find.text('关闭').last);
      expect(find.byKey(const ValueKey('credential-use')), findsNothing);
      await submitAgentCredentialRequest(t, ssh, '核对合成服务器的状态');
      expect((await model.source.loadSummary()).pending, 6);
      expect(
        (await model.source.credentials.requests(
          ref: ssh,
        )).singleWhere((r) => r.purpose == '核对合成服务器的状态').state,
        WorkspaceCredentialRequestState.pending,
      );
      expect((await model.source.readDetail(ssh)).values, isEmpty);
    },
  );

  check(
    'dark 200% credential create and rotation preserve uncertain draft, disable and re-enable explicitly',
    (t) async {
      final model = await start(
        t,
        'Blinko API Token',
        dark: true,
        scale: 2,
        width: 1280,
      );
      await tap(t, find.byKey(const ValueKey('library-create')));
      await tap(t, find.byKey(const ValueKey('library-new-type-credential')));
      await tap(t, find.byKey(const ValueKey('credential-edit-candidate')));
      await tap(t, find.text('取消').last);
      expect((await model.source.loadSummary()).records, 31);
      await tap(t, find.byKey(const ValueKey('credential-edit-candidate')));
      await tap(
        t,
        find.byKey(const ValueKey('credential-candidate-string-env')),
      );
      await enter(
        t,
        find.byKey(const ValueKey('credential-edit-name')),
        '独立的Token',
      );
      await enter(
        t,
        find.byKey(const ValueKey('credential-edit-note')),
        'Owner合成私有备注',
      );
      (model.source as SampleWorkspaceSource).nextSaveFailure =
          const WorkspaceFailure('unknown_outcome', '请先核对保存结果。');
      await tap(t, find.byKey(const ValueKey('credential-edit-save')));
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('credential-edit-save')),
            )
            .onPressed,
        isNull,
      );
      await capture(t, 'credential-1280-dark-200-create-unknown');
      await tap(t, find.text('核对此次保存'));
      await tap(t, find.byKey(const ValueKey('credential-edit-save')));
      expect(find.byType(DesktopDialog), findsNothing);
      final created = model.selection!;
      expect(
        (await model.source.credentials.read(created)).privateNote,
        'Owner合成私有备注',
      );
      expect((await model.source.readDetail(created)).values, isEmpty);
      await tap(t, find.byKey(const ValueKey('credential-replace')));
      await tap(t, find.byKey(const ValueKey('credential-edit-candidate')));
      await tap(
        t,
        find.byKey(const ValueKey('credential-candidate-string-env')),
      );
      await tap(t, find.byKey(const ValueKey('credential-edit-save')));
      expect((await model.source.credentials.read(created)).materialVersion, 2);
      await tap(t, find.byKey(const ValueKey('credential-toggle')));
      await capture(t, 'credential-1280-dark-200-disable-confirm');
      await tap(t, find.byKey(const ValueKey('credential-toggle-submit')));
      expect((await model.source.credentials.read(created)).enabled, isFalse);
      expect(find.byKey(const ValueKey('credential-use')), findsNothing);
      await capture(t, 'credential-1280-dark-200-disabled');
      await tap(t, find.byKey(const ValueKey('credential-toggle')));
      await tap(t, find.byKey(const ValueKey('credential-toggle-submit')));
      expect((await model.source.credentials.read(created)).enabled, isTrue);
      await tap(t, find.byKey(const ValueKey('credential-history')));
      expect(find.text('还没有使用记录。'), findsOneWidget);
    },
  );

  check(
    'focus unavailable, storage-only and a reachable read failure remain usable without secrets or execution',
    (t) async {
      final model = await start(t, 'Vikunja 登录密码', dark: true);
      expect(find.text('Mac本机焦点填充尚未启用。'), findsOneWidget);
      expect(find.byKey(const ValueKey('credential-use')), findsNothing);
      await capture(t, 'credential-1440-dark-focus-unavailable');
      await tap(t, find.byKey(const ValueKey('preview-guide')));
      await tap(t, find.byKey(const ValueKey('preview-credential-error')));
      await tap(t, find.byKey(const ValueKey('credential-refresh')));
      expect(find.text('凭据资料读取失败，请重试。'), findsOneWidget);
      await capture(t, 'credential-1440-dark-read-failure');
      await tap(t, find.byKey(const ValueKey('credential-retry')));
      expect(find.text('凭据资料读取失败，请重试。'), findsNothing);
      await enter(
        t,
        find.byKey(const ValueKey('library-search')),
        'Telethon 登录会话',
      );
      final target = model.results!.items
          .singleWhere((r) => r.name == 'Telethon 登录会话')
          .ref;
      await tap(t, find.byKey(ValueKey('library-record-${target.key}')));
      expect(find.text('此类文件当前仅保管，尚不支持运行时使用。'), findsOneWidget);
      expect(find.byKey(const ValueKey('credential-use')), findsNothing);
      await tap(t, find.byKey(const ValueKey('credential-history')));
      expect(find.text('还没有使用记录。'), findsOneWidget);
      expect((await model.source.loadSummary()).pending, 5);
    },
  );

  check(
    'credential editor retains a conflict draft and requires current metadata review before rebase',
    (t) async {
      final model = await start(t, 'Azure SSH 私钥', width: 1280);
      final before = await model.source.credentials.read(ssh);
      await tap(t, find.text('编辑信息'));
      await enter(
        t,
        find.byKey(const ValueKey('credential-edit-note')),
        '需要保留的本地草稿',
      );
      await model.source.credentials.save(
        WorkspaceCredentialWrite(
          operationId: 'concurrent-owner',
          ref: ssh,
          expectedRecordVersion: before.recordVersion,
          expectedMaterialVersion: before.materialVersion,
          name: before.record.name,
          purpose: before.record.description,
          privateNote: '另一窗口中的备注',
          binding: before.binding,
          directoryId: before.record.directoryId,
          tagIds: before.record.tags.map((t) => t.id),
          linkedInformation: [aliyun],
        ),
      );
      await t.pumpAndSettle();
      await tap(t, find.byKey(const ValueKey('credential-edit-save')));
      expect(find.text('凭据已变化，请重新读取并核对。'), findsOneWidget);
      expect(
        t
            .widget<DesktopButton>(
              find.byKey(const ValueKey('credential-edit-save')),
            )
            .onPressed,
        isNull,
      );
      await tap(t, find.text('读取当前资料'));
      expect(
        find.descendant(
          of: find.byType(DesktopDialog),
          matching: textValue('另一窗口中的备注'),
        ),
        findsOneWidget,
      );
      await capture(t, 'credential-1280-light-conflict-review');
      await tap(
        t,
        find.byKey(const ValueKey('credential-edit-accept-current')),
      );
      await tap(t, find.byKey(const ValueKey('credential-edit-save')));
      expect(find.byType(DesktopDialog), findsNothing);
      final saved = await model.source.credentials.read(ssh);
      expect(saved.privateNote, '需要保留的本地草稿');
      expect(saved.linkedInformation, [aliyun]);
      expect(
        (await model.source.readDetail(azure)).relations['credentials'],
        isNot(contains(ssh)),
      );
      expect(
        (await model.source.readDetail(aliyun)).relations['credentials'],
        contains(ssh),
      );
      await tap(t, find.text('编辑信息'));
      await tap(
        t,
        find.byKey(const ValueKey('library-relation-choose-related')),
      );
      await enter(
        t,
        find.byKey(const ValueKey('library-relation-search-related')),
        'Azure',
      );
      await tap(
        t,
        find.byKey(ValueKey('library-relation-option-related-${azure.key}')),
      );
      expect(
        find.byKey(ValueKey('library-relation-option-related-${ssh.key}')),
        findsNothing,
      );
      await tap(t, find.byKey(const ValueKey('library-relation-done-related')));
      await tap(
        t,
        find.byKey(ValueKey('library-relation-remove-related-${aliyun.key}')),
      );
      await tap(t, find.byKey(const ValueKey('credential-edit-save')));
      expect((await model.source.credentials.read(ssh)).linkedInformation, [
        azure,
      ]);
      await tap(t, find.text('Azure 日本服务器'));
      expect(model.selection, azure);
      expect(model.canGoBack, isTrue);
    },
  );
  for (final large in [false, true]) {
    check(
      'long private note preserves credential configuration and reachable actions/related return large=$large',
      (t) async {
        final model = await start(
          t,
          'Azure SSH 私钥',
          width: large ? 1280 : 1440,
          dark: large,
          scale: large ? 2 : 1,
        );
        final original = await model.source.credentials.read(ssh);
        final originalRequests = (await model.source.credentials.requests(
          ref: ssh,
        )).map((r) => (r.id, r.state, r.materialVersion, r.purpose)).toList();
        final note = List.filled(200, '合成私有备注，用于检查滚动。').join();
        expect(note.length, lessThan(4000));
        await tap(t, find.text('编辑信息'));
        await enter(
          t,
          find.byKey(const ValueKey('credential-edit-note')),
          note,
        );
        await tap(t, find.byKey(const ValueKey('credential-edit-save')));
        expect(find.byType(DesktopDialog), findsNothing);
        final current = await model.source.credentials.read(ssh);
        expect(current.privateNote, note);
        expect(current.materialVersion, original.materialVersion);
        expect(current.delivery, original.delivery);
        expect(current.binding, original.binding);
        expect(textValue(note), findsOneWidget);
        await tap(t, find.byKey(const ValueKey('credential-advanced')));
        expect(
          t
              .widget<LibraryReadingText>(
                find.byKey(const ValueKey('credential-binding-value')),
              )
              .span
              .toPlainText(),
          original.binding,
        );
        expect(find.byKey(const ValueKey('credential-use')), findsNothing);
        await capture(
          t,
          'credential-long-note-actions-${large ? '1280-dark-200' : '1440-light'}',
        );
        await tap(
          t,
          find.byKey(const ValueKey('library-relation-information:azure')),
        );
        expect(model.selection, azure);
        await tap(t, find.byKey(const ValueKey('library-back')));
        expect(model.selection, ssh);
        expect(model.query.keyword, 'Azure SSH 私钥');
        expect(textValue(note), findsOneWidget);
        expect(
          (await model.source.credentials.requests(
            ref: ssh,
          )).map((r) => (r.id, r.state, r.materialVersion, r.purpose)).toList(),
          originalRequests,
        );
        expect(t.takeException(), isNull);
      },
    );
  }
  for (final replace in [false, true]) {
    for (final (width, dark, scale) in [
      for (final width in [1440.0, 1280.0])
        for (final dark in [false, true])
          for (final scale in [1.0, 2.0]) (width, dark, scale),
    ]) {
      check(
        'material choice preserves custom reference draft replace=$replace width=$width dark=$dark scale=$scale',
        (t) async {
          final model = await start(
            t,
            'Azure SSH 私钥',
            width: width,
            dark: dark,
            scale: scale,
          );
          const custom = 'OWNER_CUSTOM_REFERENCE';
          if (replace) {
            await tap(t, find.text('编辑信息'));
            await enter(
              t,
              find.byKey(const ValueKey('credential-edit-binding')),
              custom,
            );
            await tap(t, find.byKey(const ValueKey('credential-edit-save')));
            expect((await model.source.credentials.read(ssh)).binding, custom);
            await tap(t, find.byKey(const ValueKey('credential-replace')));
          } else {
            await tap(t, find.byKey(const ValueKey('library-create')));
            await tap(
              t,
              find.byKey(const ValueKey('library-new-type-credential')),
            );
            await enter(
              t,
              find.byKey(const ValueKey('credential-edit-name')),
              '自定引用的凭据',
            );
            await enter(
              t,
              find.byKey(const ValueKey('credential-edit-binding')),
              custom,
            );
          }
          await tap(t, find.byKey(const ValueKey('credential-edit-candidate')));
          await tap(
            t,
            find.byKey(
              ValueKey(
                'credential-candidate-${replace ? 'ssh-file' : 'string-env'}',
              ),
            ),
          );
          expect(
            t
                .widget<DesktopTextField>(
                  find.byKey(const ValueKey('credential-edit-binding')),
                )
                .controller!
                .text,
            custom,
          );
          final nameOwner = find.byKey(const ValueKey('credential-edit-name'));
          final label = find.descendant(
            of: nameOwner,
            matching: find.text('凭据名称'),
          );
          final input = find.descendant(
            of: nameOwner,
            matching: find.byType(TextField),
          );
          expect(t.widget<Text>(label).style!.fontSize, 13);
          expect(t.widget<Text>(label).style!.fontWeight, FontWeight.w500);
          expect(t.getRect(input).top - t.getRect(label).bottom, 8);
          if (scale == 1) {
            expect(t.getSize(input).height, closeTo(44.4, .5));
          }
          final purpose = find.byKey(const ValueKey('credential-edit-purpose'));
          expect(t.getRect(purpose).top - t.getRect(input).bottom, 12);
          if (evidence.isNotEmpty) {
            await t.ensureVisible(
              find.byKey(const ValueKey('credential-edit-binding')),
            );
            await t.pumpAndSettle();
            final fields = <String, Object>{};
            for (final (id, label) in [
              ('name', '凭据名称'),
              ('binding', '建议引用名'),
            ]) {
              final owner = find.byKey(ValueKey('credential-edit-$id'));
              final input = find.descendant(
                of: owner,
                matching: find.byType(TextField),
              );
              final caption = find.descendant(
                of: owner,
                matching: find.text(label),
              );
              final lr = t.getRect(caption), ir = t.getRect(input);
              fields[id] = {
                'labelHeight': lr.height,
                'gap': ir.top - lr.bottom,
                'inputHeight': ir.height,
                'labelFontSize': t.widget<Text>(caption).style!.fontSize,
                'labelWeight': t.widget<Text>(caption).style!.fontWeight?.value,
              };
            }
            fields['name'] = {
              ...Map<String, Object?>.from(fields['name'] as Map),
              'nextFieldGap': t.getRect(purpose).top - t.getRect(input).bottom,
            };
            final stem =
                '${dark ? 'dark' : 'light'}-${width.toInt()}-${(scale * 100).toInt()}-replace-$replace';
            await t.runAsync(
              () => File('$evidence/field-$stem.json').writeAsString(
                jsonEncode({
                  'viewport': {
                    'width': width,
                    'height': width == 1440 ? 900 : 800,
                    'dpr': 1,
                  },
                  'theme': dark ? 'dark' : 'light',
                  'textScale': scale,
                  'replace': replace,
                  'fields': fields,
                }),
              ),
            );
            await capture(t, 'field-$stem');
          }

          await tap(t, find.byKey(const ValueKey('credential-edit-save')));
          expect(find.byType(DesktopDialog), findsNothing);
          final current = await model.source.credentials.read(model.selection!);
          expect(current.binding, custom);
          expect(current.materialVersion, replace ? 2 : 1);
        },
      );
    }
  }
  for (final large in [false, true]) {
    check(
      'new reference follows material suggestion until edited, including explicit empty large=$large',
      (t) async {
        final model = await start(
          t,
          'Azure SSH 私钥',
          width: large ? 1280 : 1440,
          dark: large,
          scale: large ? 2 : 1,
        );
        await tap(t, find.byKey(const ValueKey('library-create')));
        await tap(t, find.byKey(const ValueKey('library-new-type-credential')));
        await enter(
          t,
          find.byKey(const ValueKey('credential-edit-name')),
          '引用建议与手动清空',
        );
        String binding() => t
            .widget<DesktopTextField>(
              find.byKey(const ValueKey('credential-edit-binding')),
            )
            .controller!
            .text;
        Future<void> choose(String id) async {
          await tap(t, find.byKey(const ValueKey('credential-edit-candidate')));
          await tap(t, find.byKey(ValueKey('credential-candidate-$id')));
        }

        await choose('string-env');
        expect(binding(), 'API_TOKEN');
        await tap(t, find.byKey(const ValueKey('credential-edit-candidate')));
        await tap(t, find.text('取消').last);
        expect(binding(), 'API_TOKEN');
        await choose('ssh-file');
        expect(binding(), 'SSH_KEY_FILE');
        await enter(
          t,
          find.byKey(const ValueKey('credential-edit-binding')),
          '',
        );
        await choose('string-env');
        expect(binding(), '');
        expect((await model.source.loadSummary()).records, 31);
        await tap(t, find.byKey(const ValueKey('credential-edit-save')));
        expect(find.byType(DesktopDialog), findsNothing);
        expect(
          (await model.source.credentials.read(model.selection!)).binding,
          '',
        );
      },
    );
  }
}
