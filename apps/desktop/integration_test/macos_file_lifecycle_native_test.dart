import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart' show InformationApp;
import 'support/native_semantics_lifetime.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

// Native Flutter and SQLCipher with controlled owner approvals/ephemeral key.
// The parent runs the independent shipped CLI outside the application sandbox.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac file replacement revision recycle revoke expiry and reopen',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      const marker = String.fromEnvironment('MAC_QA_OWNER');
      expect(marker, matches(RegExp(r'^[a-f0-9]{32}$')));
      final root = await Directory.systemTemp.createTemp(
        'aim-mac-file-lifecycle-ui-',
      );
      await File('${root.path}/.qa-owner').writeAsString(marker);
      debugPrint('MAC_FILE_LIFECYCLE_ROOT=${root.path}');
      final semantics = NativeSemanticsLifetime(tester);
      final shadows = debugDisableShadows;
      debugDisableShadows = false;
      final keys = _Keys();
      var repository = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      var service = InformationService(
        repository: repository,
        informationDeliveryFiles: NativeInformationDeliveryFiles(),
      );
      var server = await AgentServer.start(
        service.agent,
        port: 0,
        enableReusableCredentialUse: true,
        enableInformationFiles: true,
      );
      final boundary = GlobalKey();
      const pickerChannel = MethodChannel('agent_info_manage/backup_files');
      final pickerResults = <String?>[];
      var pickerCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pickerChannel, (call) async {
            expect(call.method, 'informationFileInput');
            expect(pickerResults, isNotEmpty);
            pickerCalls++;
            return pickerResults.removeAt(0);
          });
      final captures = <String>[];
      var step = 0;
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pickerChannel, null);
        await tester.pumpWidget(const SizedBox());
        await server.close();
        await service.close();
        await repository.close();
        semantics.finishAfterUnmount();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDisableShadows = shadows;
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
        final deadline = DateTime.now().add(const Duration(seconds: 120));
        while (!await reply.exists()) {
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'Independent CLI deadline',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final result =
            jsonDecode(await reply.readAsString()) as Map<String, dynamic>;
        expect(result['ok'], isTrue);
        return result;
      }

      Future<void> mount() async {
        tester.view.physicalSize = const Size(1440, 1000);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: InformationApp(service: service, port: server.port),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(target.hitTestable(), findsOneWidget);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${root.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        captures.add('$name.png');
      }

      // Only the initial item/key/approval and picker responses are fixtures.
      // Replacement, cancellation, revision/recycle and revocation use real UI.
      final bytes1 = List<int>.generate(1024, (i) => (i * 37 + 11) % 256);
      final bytes2 = List<int>.generate(2049, (i) => (i * 13 + 3) % 256);
      final source1 = File('${root.path}/original 中文 v1.bin');
      final source2 = File('${root.path}/replacement 中文 v2.bin');
      await source1.writeAsBytes(bytes1);
      await source2.writeAsBytes(bytes2);
      final draft = await service.owner.beginInformationFileDraft();
      final stage = await service.owner.stageInformationFile(
        draft,
        source1.path,
      );
      final initial = await service.owner.commitInformationDraft(
        draft,
        'initial',
        InformationDraftInput(
          name: 'Mac file lifecycle',
          description: 'Synthetic file lifecycle',
          fields: [
            const InformationDraftField.text(
              'Private text',
              'Separate scope',
              'not approved',
            ),
            InformationDraftField.stagedFile(
              'Binary file',
              'Public file',
              stage.id,
            ),
          ],
        ),
      );
      await service.owner.releaseInformationFileDraft(draft);
      final itemId = initial.id,
          oldFile = initial.fields.last.id,
          oldText = initial.fields.first.id;
      final ref1 = initial.fields.last.attachment!;
      InformationItem current() => service.owner.information.single;
      InformationField file() =>
          current().fields.singleWhere((f) => f.kind == FieldKind.file);
      Future<void> checkFile(
        int itemVersion,
        String fieldId,
        int attachmentVersion,
        List<int> bytes,
      ) async {
        expect(current().id, itemId);
        expect(current().version, itemVersion);
        expect(file().id, fieldId);
        expect(file().attachment!.attachmentId, ref1.attachmentId);
        expect(file().attachment!.attachmentVersion, attachmentVersion);
        expect(
          await repository.readInformationAttachmentChunk(
            file().attachment!,
            0,
            bytes.length,
          ),
          bytes,
        );
        expect(await source1.readAsBytes(), bytes1);
        expect(await source2.readAsBytes(), bytes2);
        expect((await repository.informationFileStagingUsage()).files, 0);
      }

      Future<void> library() async {
        await tap(find.byKey(const ValueKey('nav-1')));
        await tap(find.byKey(ValueKey('information-$itemId')));
      }

      Future<void> choose(String? path) async {
        pickerResults.add(path);
        await tap(find.byKey(const ValueKey('choose-file-1')));
        expect(pickerResults, isEmpty);
      }

      Future<void> waitFor(bool Function() ready) async {
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (!ready()) {
          expect(DateTime.now().isBefore(deadline), isTrue);
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await mount();
      await library();
      await checkFile(1, oldFile, 1, bytes1);
      final request = await exchange('request', {
        'itemId': itemId,
        'fileId': oldFile,
        'textId': oldText,
      });
      service.owner.approve(request['requestId'] as String, [
        FieldRef(itemId, oldFile),
      ]);
      await exchange('approved');

      await tap(find.text('更换文件'));
      await choose(null);
      await checkFile(1, oldFile, 1, bytes1);
      await tap(find.text('取消'));
      await tap(find.text('更换文件'));
      await choose(source2.path);
      expect((await repository.informationFileStagingUsage()).files, 1);
      await tap(find.text('取消'));
      await tap(find.text('放弃更改'));
      await waitFor(
        () => find.byKey(const ValueKey('save-information')).evaluate().isEmpty,
      );
      await checkFile(1, oldFile, 1, bytes1);
      await capture('01-cancelled-replacement');
      await exchange('cancelled');

      await tap(find.text('更换文件'));
      await choose(source2.path);
      await tap(find.byKey(const ValueKey('save-information')));
      await waitFor(
        () =>
            current().version == 2 &&
            find.byKey(const ValueKey('save-information')).evaluate().isEmpty,
      );
      await checkFile(2, oldFile, 2, bytes2);
      await capture('02-replaced-v2');
      await exchange('replaced');

      await tap(find.text('修改历史 ↗'));
      await waitFor(() => find.text('恢复为新版本').evaluate().isNotEmpty);
      await tap(find.text('恢复为新版本'));
      await capture('03-revision-preview');
      await tap(find.text('取消'));
      await checkFile(2, oldFile, 2, bytes2);
      await exchange('revision-cancelled');
      await tap(find.text('恢复为新版本'));
      await tap(find.text('确认恢复为新版本'));
      await waitFor(() => current().version == 3);
      await tap(find.text('×').last);
      await checkFile(3, oldFile, 1, bytes1);
      await capture('04-revision-restored');
      await exchange('revision-restored');

      await tap(find.text('移入回收站'));
      await tap(find.text('取消'));
      await checkFile(3, oldFile, 1, bytes1);
      await exchange('delete-cancelled');
      await tap(find.text('移入回收站'));
      await tap(find.text('确认删除'));
      await waitFor(() => service.owner.information.isEmpty);
      await service.owner.reconcileInformationFileDeliveries();
      await capture('05-deleted');
      await exchange('deleted');

      await tap(find.text('回收站'));
      await waitFor(() => find.text('恢复信息').evaluate().isNotEmpty);
      await tap(find.text('恢复信息'));
      await tap(find.text('确认恢复'));
      await waitFor(() => service.owner.information.length == 1);
      await tap(find.text('×').last);
      final freshFile = file().id;
      final freshText = current().fields
          .singleWhere((f) => f.kind != FieldKind.file)
          .id;
      expect(freshFile, isNot(oldFile));
      expect(freshText, isNot(oldText));
      await checkFile(5, freshFile, 1, bytes1);
      await library();
      await capture('06-recycled-restored');
      final restored = await exchange('restored', {
        'fileId': freshFile,
        'textId': freshText,
      });
      final freshRequest = restored['requestId'] as String;
      service.owner.approve(freshRequest, [FieldRef(itemId, freshFile)]);
      await exchange('reapproved');

      await tap(find.byKey(const ValueKey('nav-3')));
      final history = await service.owner.history();
      final grant = history.grants.singleWhere(
        (g) => g.requestId == freshRequest,
      );
      await tap(find.byKey(ValueKey('history-entry-${grant.id}')));
      await tap(find.text('撤销授权'));
      await tap(find.text('保留授权'));
      await exchange('revoke-cancelled');
      await tap(find.text('撤销授权'));
      await tap(find.text('确认撤销'));
      await service.owner.reconcileInformationFileDeliveries();
      await capture('07-revoked');
      final expires = await exchange('revoked');
      service.owner.approve(expires['requestId'] as String, [
        FieldRef(itemId, freshFile),
      ], lifetime: const Duration(minutes: 1));
      // The independent parent waits on the actual expiry from the CLI. No fake clock.
      await exchange('expiry-approved');
      await service.owner.reconcileInformationFileDeliveries();
      // Fixture approval happened while history was already mounted. Navigate
      // normally to reload its snapshot before checking the actual expiry row.
      final expiredHistory = await service.owner.history();
      expect(expiredHistory.grants, hasLength(3));
      final expiredGrant = expiredHistory.grants.singleWhere(
        (g) => g.requestId == expires['requestId'],
      );
      expect(expiredGrant.events.last.kind, GrantEventKind.expired);
      await tap(find.byKey(const ValueKey('nav-1')));
      await tap(find.byKey(const ValueKey('nav-3')));
      await tap(find.byKey(ValueKey('history-entry-${expiredGrant.id}')));
      expect(find.text('已到期'), findsWidgets);
      expect(find.text('未关联保留中授权的文件交付'), findsNothing);
      await capture('08-expired');
      await exchange('expired');

      await tester.pumpWidget(const SizedBox());
      await server.close();
      await service.close();
      await repository.close();
      repository = await EncryptedInformationRepository.open(
        '${root.path}/library',
        keys,
      );
      service = InformationService(
        repository: repository,
        informationDeliveryFiles: NativeInformationDeliveryFiles(),
      );
      server = await AgentServer.start(
        service.agent,
        port: 0,
        enableReusableCredentialUse: true,
        enableInformationFiles: true,
      );
      await checkFile(5, freshFile, 1, bytes1);
      expect(repository.grantHistory.every((g) => !g.active), isTrue);
      expect(repository.grantHistory, hasLength(3));
      expect(
        repository.informationFileDeliveries.every((d) => !d.holdsCopy),
        isTrue,
      );
      expect(repository.informationFileDeliveries, hasLength(5));
      expect(
        repository.informationFileDeliveries.every(
          (d) => repository.grantHistory.any((g) => g.id == d.grantId),
        ),
        isTrue,
      );
      await mount();
      await library();
      await capture('09-reopened');
      final reopened = await exchange('reopened');
      service.owner.approve(reopened['requestId'] as String, [
        FieldRef(itemId, freshFile),
      ]);
      await exchange('reopen-approved');
      await checkFile(5, freshFile, 1, bytes1);
      expect(repository.informationFileDeliveries, hasLength(6));
      expect(repository.grantHistory, hasLength(4));
      expect(
        repository.informationFileDeliveries.every((d) => !d.holdsCopy),
        isTrue,
      );
      expect(pickerCalls, 3);
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'complete': true,
          'phases': step + 1,
          'captures': captures,
          'pickerCalls': pickerCalls,
          'finalItemVersion': current().version,
          'currentAttachmentVersion': file().attachment!.attachmentVersion,
          'deliveryHistoryCount': repository.informationFileDeliveries.length,
          'grantHistoryCount': repository.grantHistory.length,
          'deliveryGrantRelationsPreserved': true,
          'expiredHistorySelectedAfterNormalNavigation': true,
          'scope':
              'Native tester replacement/cancel/revision/recycle/revoke, real SQLCipher/native files, actual one-minute expiry; fixture initial item/key/approvals and picker responses; same-process library reopen, not physical panels/keyboard/Keychain/sleep.',
        }),
        flush: true,
      );
      await exchange('complete');
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
