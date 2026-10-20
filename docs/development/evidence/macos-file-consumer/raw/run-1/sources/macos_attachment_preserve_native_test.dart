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
    'Mac native text edits and proposals preserve ordinary attachments',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      const marker = String.fromEnvironment('MAC_QA_OWNER');
      expect(marker, matches(RegExp(r'^[a-f0-9]{32}$')));
      final root = await Directory.systemTemp.createTemp(
        'aim-mac-attachment-preserve-ui-',
      );
      await File('${root.path}/.qa-owner').writeAsString(marker);
      debugPrint('MAC_ATTACHMENT_PRESERVE_ROOT=${root.path}');
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
      final captures = <String>[];
      var step = 0;
      addTearDown(() async {
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
        final deadline = DateTime.now().add(const Duration(seconds: 60));
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

      Future<void> input(String key, String value) async {
        final target = find.byKey(ValueKey(key));
        await tester.ensureVisible(target);
        await tester.enterText(target, value);
        await tester.pumpAndSettle();
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

      // Initial mixed information is fixture preparation, not a native picker.
      final bytes = List<int>.generate(1024, (i) => (i * 37 + 11) % 256);
      final source = File('${root.path}/synthetic 原文.bin');
      await source.writeAsBytes(bytes);
      final draft = await service.owner.beginInformationFileDraft();
      final staged = await service.owner.stageInformationFile(
        draft,
        source.path,
      );
      final initial = await service.owner.commitInformationDraft(
        draft,
        'initial',
        InformationDraftInput(
          name: 'Mac mixed attachment',
          description: 'Public mixed',
          fields: [
            const InformationDraftField.text(
              'Text note',
              'Public note',
              'before native edit',
            ),
            InformationDraftField.stagedFile(
              'Original binary',
              'Public file',
              staged.id,
            ),
          ],
        ),
      );
      await service.owner.releaseInformationFileDraft(draft);
      final itemId = initial.id,
          textId = initial.fields.first.id,
          fileId = initial.fields.last.id;
      final attachment = initial.fields.last.attachment!;
      InformationItem current() => service.owner.information.single;
      Future<void> filePreserved(int version) async {
        expect(current().id, itemId);
        expect(current().version, version);
        final file = current().fields.singleWhere(
          (f) => f.kind == FieldKind.file,
        );
        expect(file.id, fileId);
        expect(file.attachment, attachment);
        expect(file.attachment!.attachmentVersion, 1);
        expect(
          await repository.readInformationAttachmentChunk(
            attachment,
            0,
            bytes.length,
          ),
          bytes,
        );
        expect(await source.readAsBytes(), bytes);
        expect((await repository.informationFileStagingUsage()).files, 0);
      }

      Future<void> proposal(String id) async {
        await tap(find.byKey(const ValueKey('nav-2')));
        await tap(find.byKey(const ValueKey('proposal-filter-pending')));
        final target = find.byKey(ValueKey('proposal-entry-$id'));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (target.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tap(target);
      }

      await mount();
      await tap(find.byKey(const ValueKey('nav-1')));
      await tap(find.byKey(ValueKey('information-$itemId')));
      await filePreserved(1);
      await capture('01-mixed-item');
      final requested = await exchange('request', {
        'itemId': itemId,
        'textId': textId,
        'fileId': fileId,
      });
      final requestId = requested['requestId'] as String;
      // Separate explicit owner approval is controlled; file delivery is real.
      service.owner.approve(requestId, [
        FieldRef(itemId, textId),
        FieldRef(itemId, fileId),
      ]);
      await exchange('approved');
      await tap(find.byKey(const ValueKey('edit-information-description')));
      expect(find.text('选择或更换文件'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('choose-file-1')));
      await tester.pumpAndSettle();
      await capture('01-existing-file-editor');
      await input('field-value-0', 'edited native text');
      await input('item-description', 'Edited public description');
      await tap(find.byKey(const ValueKey('save-information')));
      await filePreserved(2);
      expect(current().fields.first.value, 'edited native text');
      await capture('02-text-edit-file-retained');
      final submitted = await exchange('edited');
      final updateId = submitted['proposalId'] as String;
      await proposal(updateId);
      expect(find.textContaining('proposed native text'), findsWidgets);
      await capture('03-update-review');
      await tap(find.byKey(const ValueKey('proposal-action-confirm')));
      await tap(find.byKey(const ValueKey('confirm-proposal-decision')));
      await filePreserved(3);
      expect(current().fields.first.id, textId);
      expect(current().fields.first.value, 'proposed native text');
      await capture('04-update-confirmed');
      await exchange('proposal-confirmed');
      await tap(find.byKey(const ValueKey('nav-1')));
      await tap(find.byKey(ValueKey('information-$itemId')));
      await tap(find.byKey(const ValueKey('edit-information-description')));
      await tap(find.text('移除字段').first);
      await tap(find.byKey(const ValueKey('save-information')));
      await tap(find.text('确认保存'));
      expect(current().fields.single.id, fileId);
      await filePreserved(4);
      await capture('05-text-removed-file-only');
      await exchange('text-removed');
      await tap(find.text('回收站'));
      await tap(find.text('恢复信息'));
      await tap(find.text('确认恢复'));
      final fresh = current().fields
          .singleWhere((f) => f.kind != FieldKind.file)
          .id;
      expect(fresh, isNot(textId));
      await filePreserved(5);
      expect(
        current().fields.singleWhere((f) => f.id == fresh).value,
        'proposed native text',
      );
      await tap(find.text('×').last);
      expect(find.text('proposed native text'), findsOneWidget);
      await capture('06-text-restored-file-retained');
      final regrant = await exchange('text-restored', {'freshId': fresh});
      final freshRequest = regrant['requestId'] as String;
      service.owner.approve(freshRequest, [FieldRef(itemId, fresh)]);
      await exchange('reapproved');
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
      await filePreserved(5);
      expect(
        current().fields.singleWhere((f) => f.id == fresh).value,
        'proposed native text',
      );
      expect(repository.grantHistory.every((g) => !g.active), isTrue);
      expect(
        service.owner.updateProposals.single.state,
        UpdateProposalState.confirmed,
      );
      await mount();
      await tap(find.byKey(const ValueKey('nav-1')));
      await tap(find.byKey(ValueKey('information-$itemId')));
      expect(find.text('proposed native text'), findsOneWidget);
      await capture('07-reopened-mixed-item');
      final reopened = await exchange('reopened');
      service.owner.approve(reopened['requestId'] as String, [
        FieldRef(itemId, fileId),
      ]);
      await exchange('reopen-approved');
      await filePreserved(5);
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'complete': true,
          'phases': step + 1,
          'captures': captures,
          'attachmentBytes': bytes.length,
          'finalItemVersion': 5,
          'attachmentVersion': 1,
          'scope':
              'Native tester text editing/update confirmation/deletion/recycle restore with real SQLCipher and native delivery; initial mixed item, key and owner approvals controlled; same-process service/repository reopen, no physical input or native file panels.',
        }),
        flush: true,
      );
      await exchange('complete');
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
