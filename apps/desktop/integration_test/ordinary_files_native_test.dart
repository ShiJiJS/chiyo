import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'support/native_semantics_lifetime.dart';
import 'support/ordinary_file_native_fixture.dart';
import 'support/ordinary_file_browser_receiver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const syntheticPicker = bool.fromEnvironment('NATIVE_FILES_SYNTHETIC_PICKER');
  const browserConsumer = bool.fromEnvironment('NATIVE_FILES_BROWSER_CONSUMER');
  testWidgets(
    'Windows files, AOT CLI and backup recovery (synthetic picker: $syntheticPicker)',
    (tester) async {
      const cliExecutable = String.fromEnvironment('CLI_EXECUTABLE');
      const evidenceDirectory = String.fromEnvironment(
        'NATIVE_FILES_QA_DIRECTORY',
      );
      expect(cliExecutable, isNotEmpty);
      expect(evidenceDirectory, isNotEmpty);
      final output = Directory(evidenceDirectory);
      await output.create(recursive: true);
      final root = await Directory.systemTemp.createTemp(
        'aim-native-ordinary-files-',
      );
      final original = File('${root.path}/synthetic-简历-v1.pdf');
      final replacement = File('${root.path}/synthetic-简历-v2.pdf');
      await original.writeAsBytes([0, 255, 7]);
      await replacement.writeAsBytes([1, 2, 3, 4]);
      final source = NativeOrdinaryFileLibrary(
        Directory('${root.path}/source'),
      );
      final target = NativeOrdinaryFileLibrary(
        Directory('${root.path}/target'),
      );
      NativeOrdinaryFileCli? cli;
      NativeResumeUploadReceiver? receiver;
      final semantics = NativeSemanticsLifetime(tester);
      final boundary = GlobalKey();
      final checks = <String, Object?>{
        'syntheticPicker': syntheticPicker,
        'browserConsumer': browserConsumer,
        'completed': false,
      };
      String? activeStage, activePath;
      const pickerChannel = MethodChannel('agent_info_manage/backup_files');
      if (syntheticPicker) {
        // A rehearsal of the same flow catches widget-navigation mistakes
        // without repeated manual dialogs. It is explicitly not OS-picker QA.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pickerChannel, (call) async {
              if (call.method == 'informationFileInput' &&
                  activeStage == 'cancel-initial-picker') {
                return null;
              }
              const methods = {
                'choose-original': 'informationFileInput',
                'choose-replacement': 'informationFileInput',
                'choose-readable-resume': 'informationFileInput',
                'save-original-as': 'informationFileOutput',
                'export-backup': 'backupOutput',
                'restore-backup-file': 'backupInput',
                'restore-recovery-key': 'recoveryKeyInput',
              };
              expect(call.method, methods[activeStage]);
              expect(activePath, isNotNull);
              return activePath;
            });
      }
      Future<void> phase(
        String stage, {
        String? path,
        String? browserUrl,
      }) async {
        activeStage = stage;
        activePath = path;
        final record = jsonEncode({
          'stage': stage,
          'path': path,
          'browserUrl': browserUrl,
          'fixtureRoot': root.path,
          'at': DateTime.now().toUtc().toIso8601String(),
        });
        await File(
          '${output.path}/phases.jsonl',
        ).writeAsString('$record\n', mode: FileMode.append, flush: true);
        await File(
          '${output.path}/phase.json',
        ).writeAsString(record, flush: true);
      }

      Future<void> waitFor(
        bool Function() ready, {
        Duration timeout = const Duration(seconds: 20),
      }) async {
        final deadline = DateTime.now().add(timeout);
        do {
          await tester.pump(const Duration(milliseconds: 50));
          if (ready()) return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        } while (DateTime.now().isBefore(deadline));
        expect(
          ready(),
          isTrue,
          reason: 'Native GUI did not reach the expected observable state',
        );
      }

      Future<void> shown(Finder finder, {bool dialog = false}) => waitFor(
        () => finder.evaluate().isNotEmpty,
        timeout: dialog
            ? const Duration(minutes: 6)
            : const Duration(seconds: 20),
      );
      Future<void> tap(Finder finder, {bool settle = true}) async {
        await shown(finder);
        await tester.ensureVisible(finder);
        await waitFor(() {
          final element = finder.evaluate().single;
          ButtonStyleButton? button;
          if (element.widget case final ButtonStyleButton ownButton) {
            button = ownButton;
          } else {
            element.visitAncestorElements((parent) {
              if (parent.widget case final ButtonStyleButton ancestor) {
                button = ancestor;
                return false;
              }
              return true;
            });
          }
          return button == null || button!.onPressed != null;
        });
        // Native-height layouts can put a control behind a transient snackbar.
        // Wait for a real hit target, rather than silently missing the tap.
        await waitFor(() => finder.hitTestable().evaluate().length == 1);
        await tester.tap(finder);
        if (settle) {
          await tester.pumpAndSettle();
        } else {
          await tester.pump();
        }
      }

      Future<void> mount(NativeOrdinaryFileLibrary library) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: InformationApp(
              key: UniqueKey(),
              service: library.service,
              port: library.port,
              runtime: library.bootstrap.runtime,
              backups: library.backups,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('${output.path}/screens').create(recursive: true);
        await File(
          '${output.path}/screens/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      Future<void> selectFile(
        String stage,
        String path,
        Finder button,
        Finder completed,
      ) async {
        await phase(stage, path: path);
        await tap(button, settle: false);
        await shown(completed, dialog: true);
        await phase('$stage-returned');
      }

      Future<Map<String, dynamic>> fetch(
        String requestId,
        InformationItem item,
        String operation,
      ) async {
        final result = await cli!.command({
          'protocolVersion': 2,
          'command': 'file-fetch',
          'requestId': requestId,
          'itemId': item.id,
          'fieldId': item.fields
              .singleWhere((f) => f.kind == FieldKind.file)
              .id,
          'operationId': operation,
        });
        expect(
          result['status'],
          'ok',
          reason: 'Native file fetch failed: ${result['errorCode']}',
        );
        return Map<String, dynamic>.from(result['delivery'] as Map);
      }

      Future<void> release(Map<String, dynamic> delivery) async {
        final result = await cli!.command({
          'protocolVersion': 2,
          'command': 'file-release',
          'deliveryId': delivery['deliveryId'],
        });
        expect(result['status'], 'ok');
      }

      try {
        await phase('starting');
        await source.open();
        await mount(source);
        await tap(find.byKey(const ValueKey('nav-1')));
        await tap(find.byKey(const ValueKey('new-information')));
        await tester.enterText(find.byKey(const ValueKey('item-name')), '求职资料');
        await tester.enterText(
          find.byKey(const ValueKey('field-name-0')),
          '姓名',
        );
        await tester.enterText(
          find.byKey(const ValueKey('field-value-0')),
          '林予安（虚构）',
        );
        await tap(find.byKey(const ValueKey('add-field')));
        await tester.enterText(
          find.byKey(const ValueKey('field-name-1')),
          '求职说明',
        );
        await tap(find.byKey(const ValueKey('field-kind-1')));
        await tap(find.text('受控说明').last);
        await tester.enterText(
          find.byKey(const ValueKey('field-value-1')),
          '本次不批准的受控说明',
        );
        await tap(find.byKey(const ValueKey('add-field')));
        await tester.enterText(
          find.byKey(const ValueKey('field-name-2')),
          '简历',
        );
        await tap(find.byKey(const ValueKey('field-kind-2')));
        await tap(find.text('文件').last);
        await phase('cancel-initial-picker');
        await tap(find.byKey(const ValueKey('choose-file-2')), settle: false);
        await waitFor(
          () =>
              tester
                  .widget<TextButton>(
                    find.byKey(const ValueKey('choose-file-2')),
                  )
                  .onPressed !=
              null,
          timeout: const Duration(minutes: 6),
        );
        expect(find.text('林予安（虚构）'), findsOneWidget);
        checks['nativeInputCancelRetainsOtherFields'] = true;
        await selectFile(
          'choose-original',
          original.path,
          find.byKey(const ValueKey('choose-file-2')),
          find.text('synthetic-简历-v1.pdf'),
        );
        checks['nativeSemanticsAfterPicker'] =
            tester.platformDispatcher.semanticsEnabled;
        await phase('saving-original');
        await tap(find.byKey(const ValueKey('save-information')));
        await waitFor(
          () =>
              source.owner.information.length == 1 &&
              find.byKey(const ValueKey('save-information')).evaluate().isEmpty,
        );
        final first = source.owner.information.single;
        final originalRef = first.fields
            .singleWhere((f) => f.kind == FieldKind.file)
            .attachment!;
        expect(await source.read(originalRef, 3), [0, 255, 7]);
        await phase('original-saved');
        await capture('saved-native-information');
        await phase('reopening-source');
        await tester.pumpWidget(const SizedBox.shrink());
        await source.close();
        await source.open();
        expect(source.owner.information.single.id, first.id);
        expect(await source.read(originalRef, 3), [0, 255, 7]);
        checks['savedAndReopenedExactOriginal'] = true;
        await mount(source);
        cli = await NativeOrdinaryFileCli.start(
          cliExecutable,
          source.port,
          root.path,
        );
        expect(
          (await cli.command({
            'command': 'session',
            'chatLabel': '填写求职网站',
          }))['status'],
          'ok',
        );
        final catalog = await cli.command({
          'command': 'catalog',
          'protocolVersion': 2,
        });
        final publicJson = jsonEncode(catalog);
        expect(publicJson, isNot(contains('synthetic-简历-v1.pdf')));
        expect(publicJson, isNot(contains('originalName')));
        expect(publicJson, isNot(contains(root.path)));
        final item = source.owner.information.single;
        final requested = await cli.command({
          'command': 'request',
          'protocolVersion': 2,
          'purpose': '填写个人资料并读取简历原文件',
          'fields': [
            for (final field in item.fields)
              FieldRef(item.id, field.id).toJson(),
          ],
        });
        final requestId = requested['requestId'] as String;
        final note = item.fields.singleWhere((f) => f.name == '求职说明');
        final file = item.fields.singleWhere((f) => f.kind == FieldKind.file);
        await phase('partial-approval');
        final requestDocument = find.byKey(PageStorageKey('detail-$requestId'));
        await shown(requestDocument);
        final requestScroll = find
            .descendant(of: requestDocument, matching: find.byType(Scrollable))
            .first;
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('field-${note.id}')),
          240,
          scrollable: requestScroll,
        );
        await tap(find.byKey(ValueKey('field-${note.id}')));
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('approval-file-$requestId-${file.id}')),
          200,
          scrollable: requestScroll,
        );
        await tap(find.byKey(const ValueKey('approve-selection')));
        await waitFor(
          () => source.owner.requests.single.grantExpiresAt != null,
        );
        final delivery1 = await fetch(requestId, item, 'original-v1');
        expect(await File(delivery1['path'] as String).readAsBytes(), [
          0,
          255,
          7,
        ]);
        expect(
          (await cli.command({
            'command': 'claim',
            'requestId': requestId,
          }))['status'],
          'ok',
        );
        final name = item.fields.singleWhere((f) => f.name == '姓名');
        final approvedName = await cli.command({
          'command': 'read',
          'requestId': requestId,
          'itemId': item.id,
          'fieldId': name.id,
        });
        expect(approvedName['status'], 'ok');
        expect(approvedName['value'], '林予安（虚构）');
        expect(
          (await cli.command({
            'command': 'read',
            'requestId': requestId,
            'itemId': item.id,
            'fieldId': note.id,
          }))['status'],
          'unauthorized',
        );
        checks['partialScopeAndIndependentAotCli'] = true;
        await phase('partial-approved-and-fetched');
        await tap(find.byKey(const ValueKey('nav-1')));
        await tap(find.text('求职资料').first);
        await selectFile(
          'save-original-as',
          '${root.path}/owner-copy.pdf',
          find.text('另存'),
          find.text('文件已另存，副本由你自行保管，不随授权到期删除。'),
        );
        expect(await File('${root.path}/owner-copy.pdf').readAsBytes(), [
          0,
          255,
          7,
        ]);
        await tap(find.text('更换文件'));
        await selectFile(
          'choose-replacement',
          replacement.path,
          find.byKey(ValueKey('choose-file-${item.fields.indexOf(file)}')),
          find.text('synthetic-简历-v2.pdf'),
        );
        await tap(find.byKey(const ValueKey('save-information')));
        await waitFor(
          () =>
              source.owner.information.single.version == item.version + 1 &&
              find.byKey(const ValueKey('save-information')).evaluate().isEmpty,
        );
        final second = source.owner.information.single;
        expect(
          second.fields.singleWhere((f) => f.kind == FieldKind.file).id,
          file.id,
        );
        final delivery2 = await fetch(requestId, second, 'replacement-v2');
        expect(await File(delivery2['path'] as String).readAsBytes(), [
          1,
          2,
          3,
          4,
        ]);
        final retry1 = await fetch(requestId, second, 'original-v1');
        expect(retry1['path'], delivery1['path']);
        expect(await File(retry1['path'] as String).readAsBytes(), [0, 255, 7]);
        await release(delivery1);
        await release(delivery2);
        await tap(find.byKey(const ValueKey('nav-3')));
        await shown(find.textContaining('访问与交付'));
        await tap(find.textContaining('访问与交付'));
        await shown(find.text('简历 · 版本 1'));
        expect(find.text('简历 · 版本 2'), findsOneWidget);
        await capture('native-delivery-versions');
        checks['sameGrantVersionsAndOriginalOperationRetry'] = true;
        await phase('delivery-history-verified');
        await tap(find.byKey(const ValueKey('nav-1')));
        await tap(find.text('修改历史 ↗'));
        await tap(find.text('恢复为新版本'));
        await shown(find.text('确认恢复为新版本'));
        await tap(find.text('确认恢复为新版本'));
        await waitFor(
          () =>
              source.owner.information.single.fields
                  .singleWhere((f) => f.kind == FieldKind.file)
                  .attachment ==
              originalRef,
        );
        await tester.pumpAndSettle();
        await tap(find.text('×'));
        final delivery3 = await fetch(
          requestId,
          source.owner.information.single,
          'revision-v1',
        );
        expect(await File(delivery3['path'] as String).readAsBytes(), [
          0,
          255,
          7,
        ]);
        await release(delivery3);
        await tap(find.text('移入回收站'));
        await tap(find.text('确认删除'));
        await waitFor(() => source.owner.information.isEmpty);
        await tap(find.text('回收站'));
        await tap(find.text('恢复信息'));
        await tap(find.text('确认恢复'));
        await waitFor(() => source.owner.information.length == 1);
        await tester.pumpAndSettle();
        await tap(find.text('×'));
        final restored = source.owner.information.single;
        expect(
          restored.fields.singleWhere((f) => f.kind == FieldKind.file).id,
          isNot(file.id),
        );
        expect(
          restored.fields
              .singleWhere((f) => f.kind == FieldKind.file)
              .attachment,
          originalRef,
        );
        final stale = await cli.command({
          'protocolVersion': 2,
          'command': 'file-fetch',
          'requestId': requestId,
          'itemId': item.id,
          'fieldId': file.id,
          'operationId': 'after-recycle',
        });
        expect(stale['status'], isNot('ok'));
        checks['revisionAndRecycleRestoreNeverReviveRemovedGrant'] = true;
        await phase('revision-and-recycle-verified');
        await source.backups.enable();
        await source.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
        await tap(find.byKey(const ValueKey('nav-4')));
        await tap(find.byKey(const ValueKey('settings-section-backups')));
        await tap(find.text('查看恢复步骤'));
        await shown(find.text('恢复密钥已另存'));
        await selectFile(
          'export-backup',
          '${root.path}/files.aimbackup',
          find.text('导出加密备份').last,
          find.text('加密备份已导出。'),
        );
        expect(find.textContaining('可恢复原文版本 2 份（含保留版本）· 7 B'), findsOneWidget);
        await capture('native-backup-export');
        await cli.close();
        cli = null;
        await tester.pumpWidget(const SizedBox.shrink());
        await source.close();
        await target.open();
        await mount(target);
        await tap(find.byKey(const ValueKey('nav-4')));
        await tap(find.byKey(const ValueKey('settings-section-backups')));
        await tap(find.text('查看恢复步骤'));
        await shown(find.text('首次启用备份'));
        await selectFile(
          'restore-backup-file',
          '${root.path}/files.aimbackup',
          find.byKey(const ValueKey('backup-select-file')),
          find.text('files.aimbackup'),
        );
        await selectFile(
          'restore-recovery-key',
          '${root.path}/recovery.txt',
          find.byKey(const ValueKey('backup-select-key')),
          find.text('recovery.txt'),
        );
        await tap(find.text('检查备份与恢复密钥'));
        await shown(find.text('恢复预览'));
        expect(find.textContaining('可恢复原文版本 2 份（含保留版本）· 7 B'), findsOneWidget);
        await tap(find.text('确认恢复到空库'));
        await shown(find.text('资料已恢复，请到“信息库”查看。Agent 需要重新申请访问。'));
        expect(await target.read(originalRef, 3), [0, 255, 7]);
        expect(
          await target.read(
            second.fields
                .singleWhere((f) => f.kind == FieldKind.file)
                .attachment!,
            4,
          ),
          [1, 2, 3, 4],
        );
        expect(target.owner.requests, isEmpty);
        expect(
          (await target.owner.history()).grants.every((g) => !g.active),
          isTrue,
        );
        expect(
          target.owner.informationFileDeliveries.every(
            (r) => !r.runtime && r.lease == null,
          ),
          isTrue,
        );
        expect(
          (await target.owner.informationAttachmentUsage()).stagedFiles,
          0,
        );
        await capture('native-empty-library-restored');
        checks['nativeBackupDialogAndFreshDpapiRestoreExactVersionsWithoutAuthority'] =
            true;
        if (browserConsumer) {
          // After restore, a fresh GUI approval must authorize actual document
          // consumption. The prior 3/4-byte binary fixtures test byte integrity;
          // this additional UTF-8 resume is intentionally readable by tools.
          final resumeBytes = utf8.encode(
            '虚构简历\n姓名：林予安（虚构）\n求职方向：Windows 客户端开发\n'
            '项目经历：制作本机资料整理工具。\n'
            'WINDOWS-ATTACHMENT-CONSUMER-20261019\n',
          );
          final resume = File('${root.path}/fictional-resume.txt');
          await resume.writeAsBytes(resumeBytes);
          await tap(find.text('×'));
          await tap(find.byKey(const ValueKey('nav-1')));
          await tap(find.text('求职资料').first);
          await tap(find.text('更换文件'));
          final before = target.owner.information.single;
          final fieldIndex = before.fields.indexWhere(
            (f) => f.kind == FieldKind.file,
          );
          await selectFile(
            'choose-readable-resume',
            resume.path,
            find.byKey(ValueKey('choose-file-$fieldIndex')),
            find.text('fictional-resume.txt'),
          );
          await tap(find.byKey(const ValueKey('save-information')));
          await waitFor(
            () =>
                target.owner.information.single.version == before.version + 1 &&
                find
                    .byKey(const ValueKey('save-information'))
                    .evaluate()
                    .isEmpty,
          );
          final document = target.owner.information.single;
          final documentField = document.fields.singleWhere(
            (f) => f.kind == FieldKind.file,
          );
          cli = await NativeOrdinaryFileCli.start(
            cliExecutable,
            target.port,
            root.path,
          );
          expect(
            (await cli.command({
              'command': 'session',
              'chatLabel': '上传虚构简历',
            }))['status'],
            'ok',
          );
          final requested = await cli.command({
            'protocolVersion': 2,
            'command': 'request',
            'purpose': '读取虚构简历原文件，交给本机浏览器上传控件',
            'fields': [FieldRef(document.id, documentField.id).toJson()],
          });
          final newRequestId = requested['requestId'] as String;
          await tap(find.byKey(const ValueKey('nav-0')));
          final documentView = find.byKey(
            PageStorageKey('detail-$newRequestId'),
          );
          await shown(documentView);
          await tester.scrollUntilVisible(
            find.byKey(
              ValueKey('approval-file-$newRequestId-${documentField.id}'),
            ),
            240,
            scrollable: find
                .descendant(of: documentView, matching: find.byType(Scrollable))
                .first,
          );
          await tap(find.byKey(const ValueKey('approve-selection')));
          await waitFor(
            () => target.owner.requests.single.grantExpiresAt != null,
          );
          final copy = await fetch(newRequestId, document, 'readable-resume');
          expect(await File(copy['path'] as String).readAsBytes(), resumeBytes);
          receiver = await NativeResumeUploadReceiver.start(
            resumeBytes,
            File(copy['path'] as String).uri.pathSegments.last,
          );
          await phase(
            'browser-upload',
            path: copy['path'] as String,
            browserUrl: receiver.url,
          );
          await waitFor(
            () => receiver!.completed,
            timeout: const Duration(minutes: 6),
          );
          final received = await receiver.received;
          await File(
            '${output.path}/browser-received.json',
          ).writeAsString(jsonEncode(received), flush: true);
          expect(received['bytesMatched'], isTrue);
          expect(received['fileNameMatched'], isTrue);
          expect(received['byteLength'], resumeBytes.length);
          // Let the external consumer close its file input before releasing the
          // managed copy. A marker is QA control, never an application bypass.
          await phase('browser-upload-received');
          await waitFor(
            () => File('${output.path}/browser-closed').existsSync(),
            timeout: const Duration(minutes: 2),
          );
          await release(copy);
          checks['freshApprovalAfterRestoreAndBrowserConsumedOriginalBytes'] =
              received;
          await phase('browser-consumer-complete');
        }
        expect(await original.readAsBytes(), [0, 255, 7]);
        expect(await replacement.readAsBytes(), [1, 2, 3, 4]);
        checks['sourceFilesUnchanged'] = true;
        checks['completed'] = true;
        await phase('complete');
      } catch (_) {
        await phase('failed');
        rethrow;
      } finally {
        await receiver?.close();
        if (syntheticPicker) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(pickerChannel, null);
        }
        if (cli != null) await cli.close();
        await tester.pumpWidget(const SizedBox.shrink());
        await source.close();
        await target.close();
        checks['semantics'] = semantics.finishAfterUnmount();
        final parent = await Directory.systemTemp.resolveSymbolicLinks();
        final actual = await root.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '$parent${Platform.pathSeparator}'.toLowerCase(),
            ) ||
            !root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('aim-native-ordinary-files-')) {
          throw StateError(
            'Refusing cleanup outside the owned native file fixture',
          );
        }
        await root.delete(recursive: true);
        checks['ownedFixtureCleaned'] = true;
        await File(
          '${output.path}/result.json',
        ).writeAsString(jsonEncode(checks), flush: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
    // As in focused_fill_native_test, let Windows initialize its native bridge
    // before the framework produces semantics. Forcing framework semantics
    // first reproduces the SDK's late-UIA incremental-tree AV, independently of
    // this application's file editor. OS accessibility stays enabled.
    semanticsEnabled: false,
  );
}
