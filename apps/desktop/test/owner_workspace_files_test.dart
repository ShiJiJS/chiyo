@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceSource source;
  late _Keys keys;
  var now = DateTime.utc(2026, 11, 1);
  Future<void> open() async {
    repo = await EncryptedInformationRepository.open(
      '${root.path}/library',
      keys,
    );
    service = core.InformationService(repository: repo, clock: () => now);
    source = OwnerWorkspaceSource(
      owner: service.owner,
      refreshInterval: Duration.zero,
    );
  }

  Future<void> close() async {
    await source.dispose();
    await service.close();
    await repo.close();
  }

  setUp(() async {
    now = DateTime.utc(2026, 11, 1);
    root = await Directory.systemTemp.createTemp('owner-files-');
    keys = _Keys();
    await open();
  });
  tearDown(() async {
    await close();
    await root.delete(recursive: true);
  });
  Future<core.InformationItem> save(
    List<int> bytes, {
    String media = 'text/plain',
    core.InformationItem? old,
  }) async {
    final path = '${root.path}/synthetic-input';
    await File(path).writeAsBytes(bytes);
    final draft = await service.owner.beginInformationFileDraft();
    try {
      final stage = await service.owner.stageInformationFile(
        draft,
        path,
        mediaType: media,
      );
      return await service.owner.commitInformationDraft(
        draft,
        'save',
        core.InformationDraftInput(
          name: '合成附件',
          description: '',
          itemId: old?.id,
          baseVersion: old?.version,
          fields: [
            core.InformationDraftField.stagedFile(
              '原文',
              '',
              stage.id,
              fieldId: old?.fields.single.id,
            ),
          ],
        ),
      );
    } finally {
      await service.owner.releaseInformationFileDraft(draft);
    }
  }

  WorkspaceRecordRef ref(core.InformationItem item) =>
      WorkspaceRecordRef(WorkspaceRecordKind.information, item.id);
  Future<String> fieldKey(core.InformationItem item) async =>
      (await source.readDetail(ref(item))).fieldIds.keys.single;
  Matcher fails(String code) =>
      throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

  test(
    'real SQLCipher metadata/current/history/text survive source deletion and repository reopen',
    () async {
      final old = await save(utf8.encode('旧合成正文'));
      final current = await save(utf8.encode('<b>当前合成原文</b>'), old: old);
      final key = await fieldKey(current);
      await File('${root.path}/synthetic-input').delete();
      await close();
      await open();
      final history = await source.loadFileHistory(ref(current), key);
      expect(history.recordVersion, current.version);
      expect(history.current.ref.version, 2);
      expect(history.versions.map((v) => v.ref.version), [2, 1]);
      final preview = await source.readFilePreview(ref(current), key);
      expect(preview.kind, WorkspaceFilePreviewKind.text);
      expect(preview.text, '<b>当前合成原文</b>');
      expect(
        (await source.readFilePreview(ref(current), key, version: 1)).text,
        '旧合成正文',
      );
      await expectLater(
        source.readFilePreview(ref(current), key, page: 1),
        fails('invalid_request'),
      );
      await expectLater(
        source.readFilePreview(ref(current), 'forged'),
        fails('not_found'),
      );
      await expectLater(
        source.readFilePreview(ref(current), key, version: 999),
        fails('attachment_missing'),
      );
    },
  );
  test(
    'unsupported and invalid originals are explicit and remain stored',
    () async {
      final item = await save([0, 255, 7], media: 'application/octet-stream');
      final key = await fieldKey(item);
      expect(
        (await source.readFilePreview(ref(item), key)).kind,
        WorkspaceFilePreviewKind.unsupported,
      );
      expect(
        (await service.owner.readInformationAttachment(
          item.fields.single.attachment!,
        )).bytes,
        [0, 255, 7],
      );
      final broken = await save([255], old: item);
      await expectLater(
        source.readFilePreview(ref(broken), key),
        fails('preview_unavailable'),
      );
    },
  );
  test(
    'retention expiry keeps metadata but cannot return cleaned historical bytes',
    () async {
      final old = await save(utf8.encode('retired'));
      final current = await save(utf8.encode('current'), old: old);
      final key = await fieldKey(current);
      now = now.add(const Duration(days: 31));
      await expectLater(
        source.readFilePreview(ref(current), key, version: 1),
        fails('attachment_missing'),
      );
      final history = await source.loadFileHistory(ref(current), key);
      expect(
        history.versions.singleWhere((v) => v.ref.version == 1).available,
        isFalse,
      );
      expect(history.current.available, isTrue);
      expect((await source.readFilePreview(ref(current), key)).text, 'current');
    },
  );
  test(
    'SQLCipher PDF source passes verified bytes and exact page to native renderer',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      const channel = MethodChannel('agent_info_manage/owner_pdf_preview');
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawPaint(ui.Paint());
      final picture = recorder.endRecording();
      final image = await picture.toImage(2, 3);
      picture.dispose();
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      image.dispose();
      final raw = utf8.encode('%PDF synthetic channel input');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'renderPage');
            final args = call.arguments as Map;
            expect(args['bytes'], raw);
            final page = args['page'] as int;
            if (page > 1) {
              throw PlatformException(
                code: 'invalid_request',
                message: '/private/not-for-ui',
              );
            }
            return {
              'png': png.buffer.asUint8List(
                png.offsetInBytes,
                png.lengthInBytes,
              ),
              'width': 2,
              'height': 3,
              'page': page,
              'pageCount': 2,
            };
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final item = await save(raw, media: 'application/pdf');
      final key = await fieldKey(item);
      final preview = await source.readFilePreview(ref(item), key, page: 1);
      expect(preview.page, 1);
      expect(preview.pageCount, 2);
      expect(preview.pixelHeight, 3);
      await expectLater(
        source.readFilePreview(ref(item), key, page: 2),
        fails('invalid_request'),
      );
    },
  );
  test('image bytes decode to a real bounded PNG preview', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(
      recorder,
    ).drawPaint(ui.Paint()..color = const ui.Color(0xff123456));
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 3);
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    picture.dispose();
    final item = await save(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      media: 'image/png',
    );
    final preview = await source.readFilePreview(
      ref(item),
      await fieldKey(item),
    );
    expect(preview.kind, WorkspaceFilePreviewKind.image);
    expect(preview.pixelWidth, 2);
    expect(preview.pixelHeight, 3);
    expect(preview.image!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });
}
