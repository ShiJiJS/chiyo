// Synthetic native acceptance only. No production library, Keychain or hooks.
import 'dart:async';
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
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/desktop_controls.dart';
import 'package:info_desktop/mac_inline_password.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'support/native_semantics_lifetime.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.generate(32, (i) => i + 23);
  @override
  Future<void> create(List<int> _) async => throw StateError('Synthetic key');
}

class _Cli {
  _Cli(this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      errors = process.stderr.transform(utf8.decoder).join();
  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;
  Future<Map<String, dynamic>> call(Map<String, Object?> command) async {
    process.stdin.writeln(jsonEncode(command));
    await process.stdin.flush();
    expect(await lines.moveNext().timeout(const Duration(seconds: 20)), true);
    final result = jsonDecode(lines.current) as Map<String, dynamic>;
    expect(result.containsKey('sessionSecret'), false);
    expect(result.containsKey('token'), false);
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
    }
    await lines.cancel();
    expect(await errors, isEmpty);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'whole proposals in the native production shell with a compiled CLI',
    (t) async {
      expect(Platform.isMacOS, true);
      expect(const bool.fromEnvironment('OWNER_NATIVE_SYNTHETIC'), true);
      final semantics = NativeSemanticsLifetime(t);
      await loadDesktopFonts();
      final root = await Directory.systemTemp.createTemp('whole-native-');
      final checks = <String>[];
      final images = <String, String>{};
      final boundary = GlobalKey();
      EncryptedInformationRepository? repo;
      DesktopBootstrap? bootstrap;
      _Cli? cli;
      late ProposalsController model;
      var passed = false;
      Future<void> settle() async {
        for (var i = 0; i < 500; i++) {
          await t.pump(const Duration(milliseconds: 30));
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(t.takeException(), isNull);
          if (!model.loading &&
              !model.reading &&
              !model.busy &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              !binding.hasScheduledFrame) {
            return;
          }
        }
        fail('Native proposal did not settle');
      }

      Future<void> tap(String key) async {
        final target = find.byKey(ValueKey(key));
        await t.ensureVisible(target);
        await t.tap(target);
        await settle();
      }

      Future<String> picture() async {
        await binding.endOfFrame;
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          return base64Encode(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      }

      Future<void> close() async {
        await cli?.close();
        cli = null;
        await t.pumpWidget(const SizedBox());
        await t.pump();
        await bootstrap?.runtime?.stop();
        bootstrap?.runtime?.dispose();
        bootstrap?.dispose();
        bootstrap = null;
      }

      Future<void> open() async {
        repo = await EncryptedInformationRepository.open(
          '${root.path}/library',
          _Keys(),
        );
        final service = core.InformationService(repository: repo!);
        bootstrap = DesktopBootstrap(
          port: 0,
          platform: NativeDesktopPlatform(),
          openLibrary: () async => DesktopLibrary(
            service: service,
            close: repo!.close,
            backups: repo!.backups,
          ),
        );
        await bootstrap!.start();
        expect(bootstrap!.state, DesktopStartupState.ready);
        await t.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: DesktopLauncher(bootstrap: bootstrap!, useWorkspace: true),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('workspace-nav-proposals')));
        await t.pumpAndSettle();
        model = t.widget<ProposalsPage>(find.byType(ProposalsPage)).controller;
        cli = _Cli(
          await Process.start(
            '${File(Platform.resolvedExecutable).parent.path}/info-proposal-check',
            ['--port', '${bootstrap!.boundPort}'],
          ),
        );
        expect(
          (await cli!.call({
            'command': 'session',
            'chatLabel': '合成提案原生验收',
          }))['status'],
          'ok',
        );
      }

      Future<Map<String, dynamic>> example(String type) async {
        final response = await cli!.call({
          'command': 'template-read',
          'templateId': type,
        });
        expect(response['status'], 'ok');
        return Map<String, dynamic>.from(
          (response['template'] as Map)['submissionExample'] as Map,
        );
      }

      try {
        await open();
        final catalog = await cli!.call({'command': 'template-list'});
        expect(catalog['status'], 'ok');
        final fileExample = await example('file');
        final passwordExample = await example('credential.accountPassword');
        checks.add('native-shell-dynamic-template-query-aot-cli');
        final current = File('${root.path}/确认稿.txt');
        final old = File('${root.path}/旧稿.txt');
        await current.writeAsString('SYNTHETIC-CURRENT-ORIGINAL');
        await old.writeAsString('SYNTHETIC-OLDER-ORIGINAL');
        final fileItem =
            Map<String, dynamic>.from(
                (fileExample['items'] as List).single as Map,
              )
              ..['key'] = 'file'
              ..['name'] = '合成文件';
        fileItem['attachments'] = [
          {
            'key': 'primary',
            'name': '原文件',
            'templateField': 'file',
            'currentVersion': 1,
            'versions': [
              {'filePath': current.path, 'label': '确认稿'},
              {'filePath': old.path, 'label': '早期草稿'},
            ],
          },
        ];
        final passwordItem =
            Map<String, dynamic>.from(
                (passwordExample['items'] as List).single as Map,
              )
              ..['key'] = 'password'
              ..['name'] = '合成服务登录';
        final submitted = await cli!.call({
          'command': 'import-submit',
          'operationId': 'whole-native-import',
          'purpose': '合成完整提案验收',
          'items': [fileItem, passwordItem],
        });
        expect(submitted['status'], 'pending', reason: '$submitted');
        final id = submitted['proposalId'] as String;
        await model.open(id);
        await settle();
        expect(model.detail!.items, hasLength(2));
        expect(model.canConfirm, false);
        expect(repo!.items, isEmpty);
        expect(repo!.managedCredentials, isEmpty);
        checks.add('missing-password-blocks-whole-proposal');
        final fileId = model.detail!.items.first.id;
        final passwordId = model.detail!.items.last.id;
        await tap('proposal-tab-$passwordId');
        final input = find.byKey(
          ValueKey('proposal-owner-password-$passwordId'),
        );
        await t.ensureVisible(input);
        DesktopTextField field() => t.widget<DesktopTextField>(input);
        expect(field().obscureText, true);
        expect(find.byType(MacInlinePassword), findsOneWidget);
        expect(
          find.descendant(of: input, matching: find.byType(EditableText)),
          findsNothing,
        );
        const osInput = bool.fromEnvironment('OWNER_PROPOSALS_OS_INPUT');
        if (osInput) {
          debugPrint('WHOLE_NATIVE_PASSWORD_READY');
          final elapsed = Stopwatch()..start();
          while (field().controller!.text != 'SYNTHETIC-NATIVE-PASSWORD' &&
              elapsed.elapsed < const Duration(seconds: 150)) {
            await t.pump(const Duration(milliseconds: 50));
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(field().controller!.text, 'SYNTHETIC-NATIVE-PASSWORD');
        }
        await tap('proposal-password-visible-$passwordId');
        expect(field().obscureText, false);
        if (!osInput) {
          // This mode checks the native composition with an injected Host
          // draft. --proposals-os-input separately requires actual AppKit input.
          field().controller!.text = 'SYNTHETIC-NATIVE-PASSWORD';
          field().onChanged?.call('SYNTHETIC-NATIVE-PASSWORD');
        }
        await settle();
        await tap('proposal-password-visible-$passwordId');
        expect(field().obscureText, true);
        expect(find.byType(MacInlinePassword), findsOneWidget);
        expect(find.text('账号：sample-user'), findsOneWidget);
        images['password'] = await picture();
        await tap('proposal-tab-$fileId');
        expect(find.text('SYNTHETIC-CURRENT-ORIGINAL'), findsOneWidget);
        await t.ensureVisible(find.text('早期草稿'));
        await t.tap(find.text('早期草稿'));
        await settle();
        expect(find.text('SYNTHETIC-OLDER-ORIGINAL'), findsOneWidget);
        images['original'] = await picture();
        await tap('proposal-tab-$passwordId');
        expect(field().controller!.text, 'SYNTHETIC-NATIVE-PASSWORD');
        await tap('proposal-tab-$fileId');
        expect(find.text('SYNTHETIC-OLDER-ORIGINAL'), findsOneWidget);
        expect(find.text('返回录入提案'), findsNothing);
        expect(find.text('查看当前资料'), findsNothing);
        checks.add(
          osInput
              ? 'native-secure-keyboard-visibility-and-tab-retention'
              : 'inline-password-visibility-and-tab-retention',
        );
        checks.add('inline-original-version-retention-no-library-navigation');
        expect(model.canConfirm, true);
        await tap('proposal-confirm');
        expect(model.writeFailure, isNull, reason: model.writeFailure?.message);
        expect(model.detail!.summary.status, WorkspaceProposalStatus.completed);
        expect(repo!.items, hasLength(1));
        expect(repo!.managedCredentials, hasLength(1));
        expect(
          bootstrap!.runtime!.service.owner.credentialUseRequests,
          isEmpty,
        );
        final status = await cli!.call({
          'command': 'import-status',
          'proposalId': id,
        });
        expect(
          jsonEncode(status),
          isNot(contains('SYNTHETIC-NATIVE-PASSWORD')),
        );
        checks.add('one-save-admits-both-no-use-grant-no-cli-password');
        final originalItem = repo!.items.single;
        final originalField = originalItem.fields.firstWhere(
          (f) => f.attachment != null,
        );
        final next = File('${root.path}/修订稿.txt');
        await next.writeAsString('SYNTHETIC-REVISED-ORIGINAL');
        final changed = await cli!.call({
          'command': 'update-submit',
          'operationId': 'whole-native-update',
          'update': {
            'itemId': originalItem.id,
            'baseVersion': originalItem.version,
            'changes': [],
            'attachments': [
              {
                'key': 'revision',
                'name': originalField.name,
                'fieldId': originalField.id,
                'currentVersion': 1,
                'versions': [
                  {'filePath': next.path, 'label': '修订稿'},
                ],
              },
            ],
          },
        });
        expect(changed['status'], 'pending', reason: '$changed');
        await model.open(changed['proposalId'] as String);
        await settle();
        expect(find.text('修改前'), findsOneWidget);
        expect(find.text('修改后'), findsOneWidget);
        expect(find.text('SYNTHETIC-CURRENT-ORIGINAL'), findsOneWidget);
        expect(find.text('SYNTHETIC-REVISED-ORIGINAL'), findsOneWidget);
        images['modification'] = await picture();
        checks.add('shared-plugin-comparison-shows-both-originals-before-save');
        await tap('proposal-confirm');
        expect(model.writeFailure, isNull, reason: model.writeFailure?.message);
        expect(repo!.items.single.version, 2);
        final currentRef = repo!.items.single.fields
            .firstWhere((f) => f.attachment != null)
            .attachment!;
        expect(
          utf8.decode(
            (await bootstrap!.runtime!.service.owner.readInformationAttachment(
              currentRef,
            )).bytes,
          ),
          'SYNTHETIC-REVISED-ORIGINAL',
        );
        final credentialId = repo!.managedCredentials.single.id;
        final itemIdentity = repo!.items.single.id;
        checks.add('modification-saves-original-and-stable-record-identity');
        await close();
        await open();
        expect(repo!.items.single.id, itemIdentity);
        expect(repo!.items.single.version, 2);
        expect(repo!.managedCredentials.single.id, credentialId);
        expect(repo!.managedCredentials.single.account, 'sample-user');
        expect(
          utf8.decode(
            (await bootstrap!.runtime!.service.owner.readInformationAttachment(
              currentRef,
            )).bytes,
          ),
          'SYNTHETIC-REVISED-ORIGINAL',
        );
        checks.add('encrypted-library-reopen-retains-records-and-originals');
        await model.open(id);
        await settle();
        final stored = model.detail!.targets.firstWhere(
          (e) => e.record.kind == WorkspaceRecordKind.information,
        );
        final oldSnapshot = await model.source.snapshot(id, stored.record);
        expect(oldSnapshot.detail.version, 1);
        checks.add('saved-proposal-keeps-own-content-after-later-modification');
        final finalImage = await picture();
        await close();
        await root.delete(recursive: true);
        passed = true;
        binding.reportData = {
          'passed': true,
          'fixtureRemoved': !await root.exists(),
          'checks': checks,
          'runtime': {'platform': Platform.operatingSystem, 'debugMode': true},
          'nativePasswordInput': osInput,
          'semantics': semantics.finishAfterUnmount(),
          'scope':
              'Native Debug production shell, SQLCipher and compiled CLI over HTTP; synthetic key and materials; nativePasswordInput records whether secure typing was supplied externally; no production data',
          'imagePngBase64': finalImage,
          'imagesPngBase64': images,
        };
      } finally {
        if (!passed) {
          await close();
          if (await root.exists()) await root.delete(recursive: true);
        }
      }
    },
    semanticsEnabled: false,
  );
}
