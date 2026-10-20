import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/information_attachment_capacity.dart';
import 'support/native_semantics_lifetime.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac real attachment and managed-copy capacity boundaries',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      const marker = String.fromEnvironment('MAC_QA_OWNER');
      expect(marker, matches(RegExp(r'^[a-f0-9]{32}$')));
      final root = await Directory.systemTemp.createTemp(
        'aim-mac-file-capacity-',
      );
      await File('${root.path}/.qa-owner').writeAsString(marker);
      debugPrint('MAC_FILE_CAPACITY_ROOT=${root.path}');
      final semantics = NativeSemanticsLifetime(tester);
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
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await server.close();
        await service.close();
        await repository.close();
        semantics.finishAfterUnmount();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final observations = <Map<String, Object?>>[];
      final captures = <String>[];
      final boundary = GlobalKey();
      var step = 0;
      Future<Map<String, dynamic>> exchange(
        String phase, [
        Map<String, Object?> extra = const {},
      ]) async {
        step++;
        await File('${root.path}/phase-$step.json').writeAsString(
          jsonEncode({'phase': phase, 'port': server.port, ...extra}),
          flush: true,
        );
        final file = File('${root.path}/reply-$step.json');
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (!await file.exists()) {
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'Independent CLI deadline',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final reply =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        expect(reply['ok'], isTrue);
        return reply;
      }

      Future<void> usage(
        String name, {
        required int stored,
        required int staged,
        required int stages,
        required int copies,
        required int copyBytes,
      }) async {
        final value = await service.owner.informationAttachmentUsage();
        final held = repository.informationFileDeliveries
            .where((d) => d.holdsCopy)
            .toList();
        expect(value.storedBytes, stored);
        expect(value.stagedBytes, staged);
        expect(value.stagedFiles, stages);
        expect(held, hasLength(copies));
        expect(held.fold<int>(0, (n, d) => n + d.byteLength), copyBytes);
        observations.add({
          'name': name,
          'storedBytes': value.storedBytes,
          'stagedBytes': value.stagedBytes,
          'stagedFiles': value.stagedFiles,
          'availableVersions': value.availableVersions,
          'versionRecords': value.versionRecords,
          'heldCopies': held.length,
          'heldBytes': copyBytes,
          'deliveryRecords': repository.informationFileDeliveries.length,
          'currentRss': ProcessInfo.currentRss,
          'maxRss': ProcessInfo.maxRss,
        });
      }

      Future<void> capture(String name, String expectedCopies) async {
        tester.view.physicalSize = const Size(1100, 650);
        tester.view.devicePixelRatio = 1;
        // The production capacity component, with actual owner/repository data.
        // This focused harness does not claim full Settings navigation or CUA.
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: InformationAttachmentCapacity(
                    key: ValueKey(name),
                    owner: service.owner,
                  ),
                ),
              ),
            ),
          ),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (find.text('正在刷新…').evaluate().isNotEmpty) {
          expect(DateTime.now().isBefore(deadline), isTrue);
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pumpAndSettle();
        expect(
          find.textContaining('原件与草稿 100.0 MiB / 100.0 MiB'),
          findsOneWidget,
        );
        expect(find.textContaining(expectedCopies), findsOneWidget);
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${root.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        captures.add('$name.png');
      }

      Matcher fails(String code) =>
          throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));
      const limit = informationFileByteLimit,
          budget = informationFileStagingByteLimit;
      expect(limit, 10 * 1024 * 1024);
      expect(budget, 100 * 1024 * 1024);
      expect(informationDeliveryLimit, 32);
      expect(informationDeliveryByteLimit, budget);
      final bytes = Uint8List(limit);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = (i * 37 + 11) % 256;
      }
      final source = File('${root.path}/最大 中文 文件.bin');
      await source.writeAsBytes(bytes);
      final oversized = File('${root.path}/超限.bin');
      await oversized.writeAsBytes(bytes);
      final extra = await oversized.open(mode: FileMode.append);
      await extra.writeByte(42);
      await extra.close();
      final empty = File('${root.path}/空文件.bin');
      await empty.writeAsBytes([]);
      final small = File('${root.path}/一字节.bin');
      await small.writeAsBytes([7]);
      final draft = await service.owner.beginInformationFileDraft();
      await expectLater(
        service.owner.stageInformationFile(draft, oversized.path),
        fails('attachment_too_large'),
      );
      await usage(
        'oversize-rejected-no-reservation',
        stored: 0,
        staged: 0,
        stages: 0,
        copies: 0,
        copyBytes: 0,
      );
      final stages = <InformationFileStage>[];
      for (var i = 0; i < 9; i++) {
        stages.add(
          await service.owner.stageInformationFile(draft, source.path),
        );
      }
      final outcomes = await Future.wait([
        for (var i = 0; i < 2; i++)
          service.owner
              .stageInformationFile(draft, source.path)
              .then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(outcomes.whereType<InformationFileStage>(), hasLength(1));
      expect(
        outcomes.whereType<AccessFailure>().single.status,
        'attachment_capacity_exceeded',
      );
      stages.add(outcomes.whereType<InformationFileStage>().single);
      await usage(
        'concurrent-last-slot',
        stored: 0,
        staged: budget,
        stages: 10,
        copies: 0,
        copyBytes: 0,
      );
      await service.owner.releaseInformationStage(draft, stages.removeLast());
      await usage(
        'stage-released',
        stored: 0,
        staged: budget - limit,
        stages: 9,
        copies: 0,
        copyBytes: 0,
      );
      stages.add(await service.owner.stageInformationFile(draft, source.path));
      final item = await service.owner.commitInformationDraft(
        draft,
        'capacity-originals',
        InformationDraftInput(
          name: 'Synthetic 100 MiB originals',
          description: 'Capacity QA',
          fields: [
            for (var i = 0; i < stages.length; i++)
              InformationDraftField.stagedFile('File $i', '', stages[i].id),
          ],
        ),
      );
      await service.owner.releaseInformationFileDraft(draft);
      await usage(
        'promoted-without-double-count',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 0,
        copyBytes: 0,
      );
      final overflow = await service.owner.beginInformationFileDraft();
      await expectLater(
        service.owner.stageInformationFile(overflow, small.path),
        fails('attachment_capacity_exceeded'),
      );
      await service.owner.deleteInformation(item.id, item.version);
      await usage(
        'deleted-originals-still-retained',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 0,
        copyBytes: 0,
      );
      await expectLater(
        service.owner.stageInformationFile(overflow, small.path),
        fails('attachment_capacity_exceeded'),
      );
      final restored = await service.owner.restoreRecycled(
        service.owner.recycleEntries.single.id,
      );
      final zero = await service.owner.stageInformationFile(
        overflow,
        empty.path,
      );
      final zeroItem = await service.owner.commitInformationDraft(
        overflow,
        'empty-original',
        InformationDraftInput(
          name: 'Synthetic empty original',
          description: '',
          fields: [InformationDraftField.stagedFile('Empty', '', zero.id)],
        ),
      );
      await service.owner.releaseInformationFileDraft(overflow);
      await usage(
        'restored-and-empty-at-full-byte-budget',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 0,
        copyBytes: 0,
      );
      // Independent count bounds still apply to empty stages and empty forms.
      final emptyDraft = await service.owner.beginInformationFileDraft();
      final emptyStages = <InformationFileStage>[];
      for (var i = 0; i < informationFileStageLimit; i++) {
        emptyStages.add(
          await service.owner.stageInformationFile(emptyDraft, empty.path),
        );
      }
      expect(informationFileStageLimit, 200);
      await expectLater(
        service.owner.stageInformationFile(emptyDraft, empty.path),
        fails('attachment_capacity_exceeded'),
      );
      await usage(
        'two-hundred-empty-stages',
        stored: budget,
        staged: 0,
        stages: 200,
        copies: 0,
        copyBytes: 0,
      );
      await service.owner.releaseInformationStage(
        emptyDraft,
        emptyStages.first,
      );
      await service.owner.stageInformationFile(emptyDraft, empty.path);
      await usage(
        'stage-count-release-retry',
        stored: budget,
        staged: 0,
        stages: 200,
        copies: 0,
        copyBytes: 0,
      );
      await service.owner.releaseInformationFileDraft(emptyDraft);
      final forms = <InformationFileDraft>[];
      for (var i = 0; i < 32; i++) {
        forms.add(await service.owner.beginInformationFileDraft());
      }
      await expectLater(
        service.owner.beginInformationFileDraft(),
        fails('attachment_capacity_exceeded'),
      );
      await service.owner.releaseInformationFileDraft(forms.removeLast());
      forms.add(await service.owner.beginInformationFileDraft());
      for (final form in forms) {
        await service.owner.releaseInformationFileDraft(form);
      }
      await usage(
        'draft-count-release-retry-clean',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 0,
        copyBytes: 0,
      );
      final largeRef = FieldRef(restored.id, restored.fields.first.id);
      final emptyRef = FieldRef(zeroItem.id, zeroItem.fields.single.id);
      final requests = await exchange('request', {
        'largeItem': largeRef.itemId,
        'largeField': largeRef.fieldId,
        'emptyItem': emptyRef.itemId,
        'emptyField': emptyRef.fieldId,
      });
      for (final request in (requests['requests'] as List).cast<String>()) {
        service.owner.approve(request, [
          largeRef,
          emptyRef,
        ], lifetime: const Duration(hours: 1));
      }
      await exchange('approved');
      await usage(
        'ten-large-copies-byte-limit',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 10,
        copyBytes: budget,
      );
      expect(repository.informationFileDeliveries, hasLength(10));
      await capture('01-byte-limit', '10 / 32 份 · 100.0 MiB / 100.0 MiB');
      await exchange('byte-full');
      await usage(
        'byte-release-retry-other-session',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 10,
        copyBytes: budget,
      );
      expect(repository.informationFileDeliveries, hasLength(11));
      await exchange('byte-retried');
      await usage(
        'all-large-released',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 0,
        copyBytes: 0,
      );
      await capture('02-released', '0 / 32 份 · 0 B / 100.0 MiB');
      await exchange('byte-released');
      await usage(
        'thirty-two-empty-copies-count-limit',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 32,
        copyBytes: 0,
      );
      expect(repository.informationFileDeliveries, hasLength(43));
      await capture('03-count-limit', '32 / 32 份 · 0 B / 100.0 MiB');
      await exchange('count-full');
      await usage(
        'count-release-retry-other-session',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 32,
        copyBytes: 0,
      );
      expect(repository.informationFileDeliveries, hasLength(44));
      await exchange('count-retried');
      await usage(
        'all-copies-released',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 0,
        copyBytes: 0,
      );
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
      await usage(
        'reopened-history-no-live-quota',
        stored: budget,
        staged: 0,
        stages: 0,
        copies: 0,
        copyBytes: 0,
      );
      expect(repository.informationFileDeliveries, hasLength(44));
      expect(
        repository.informationFileDeliveries.every(
          (d) => d.state == 'released',
        ),
        isTrue,
      );
      expect(await source.readAsBytes(), bytes);
      expect(await oversized.length(), limit + 1);
      final oversizeReader = await oversized.open();
      try {
        expect(await oversizeReader.read(limit), bytes);
        expect(await oversizeReader.readByte(), 42);
        expect(await oversizeReader.readByte(), -1);
      } finally {
        await oversizeReader.close();
      }
      expect(repository.cipherVersion, startsWith('4.19.0'));
      expect(await empty.length(), 0);
      expect(await small.readAsBytes(), [7]);
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'complete': true,
          'observations': observations,
          'captures': captures,
          'sourceFilesUnchanged': true,
          'deliveryHistoryCount': 44,
          'cipherVersion': repository.cipherVersion,
          'stageLimit': informationFileStageLimit,
          'draftLimit': 32,
          'scope':
              'Real sandbox Debug Flutter/SQLCipher/native files; public owner fixture APIs and production capacity component; ephemeral key, same-process library reopen, no system panels/physical input/Keychain/30-day clock simulation.',
        }),
      );
      await exchange('complete');
    },
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
