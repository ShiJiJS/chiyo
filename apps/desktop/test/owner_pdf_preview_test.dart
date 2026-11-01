import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/owner_pdf_preview.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('agent_info_manage/owner_pdf_preview');
  const renderer = NativeOwnerPdfPreview();
  final file = WorkspaceFileVersion(
    ref: const WorkspaceFileRef('synthetic', 1),
    filename: 'synthetic.pdf',
    mediaType: 'application/pdf',
    byteLength: 4,
    createdAt: DateTime.utc(2026),
  );
  late Uint8List png;
  late Object? reply;
  PlatformException? failure;
  var calls = 0;
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawPaint(ui.Paint());
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 3);
    picture.dispose();
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    reply = {'png': png, 'width': 2, 'height': 3, 'page': 1, 'pageCount': 2};
    failure = null;
    calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          expect(call.method, 'renderPage');
          expect((call.arguments as Map).keys.toSet(), {'bytes', 'page'});
          if (failure != null) throw failure!;
          return reply;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Matcher fails(String code) => throwsA(
    isA<WorkspaceFailure>()
        .having((e) => e.code, 'code', code)
        .having((e) => e.message, 'message', isNot(contains('/private/'))),
  );
  test(
    'exact native page and dimensions bind to original file metadata',
    () async {
      final preview = await renderer.render(
        file,
        Uint8List.fromList([1, 2, 3, 4]),
        1,
      );
      expect(preview.file, same(file));
      expect(preview.page, 1);
      expect(preview.pageCount, 2);
      expect(preview.pixelWidth, 2);
      expect(preview.pixelHeight, 3);
      expect(preview.image, png);
    },
  );
  for (final invalid in [
    'missing',
    'wrong-page',
    'wrong-size',
    'too-many-pages',
    'bad-png',
    'zero-pages',
  ]) {
    test('rejects $invalid native response', () async {
      final value = Map<String, Object?>.from(reply as Map);
      switch (invalid) {
        case 'missing':
          reply = null;
        case 'wrong-page':
          value['page'] = 0;
          reply = value;
        case 'wrong-size':
          value['width'] = 3;
          reply = value;
        case 'too-many-pages':
          value['pageCount'] = 4097;
          reply = value;
        case 'bad-png':
          value['png'] = Uint8List(40);
          reply = value;
        case 'zero-pages':
          value['pageCount'] = 0;
          reply = value;
      }
      await expectLater(
        renderer.render(file, Uint8List.fromList([1]), 1),
        fails('preview_unavailable'),
      );
    });
  }
  for (final code in [
    'invalid_request',
    'invalid_pdf',
    'pdf_locked',
    'pdf_unsupported',
    'preview_busy',
    'private_native_error',
  ]) {
    test('maps native $code without diagnostics', () async {
      failure = PlatformException(
        code: code,
        message: '/private/secret.pdf',
        details: {'path': '/private/secret.pdf'},
      );
      await expectLater(
        renderer.render(file, Uint8List.fromList([1]), 1),
        fails(code == 'private_native_error' ? 'preview_unavailable' : code),
      );
    });
  }
  test(
    'invalid input and unsupported platform do not call native renderer',
    () async {
      await expectLater(
        renderer.render(file, Uint8List(0), 0),
        fails('invalid_request'),
      );
      await expectLater(
        renderer.render(file, Uint8List.fromList([1]), -1),
        fails('invalid_request'),
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await expectLater(
        renderer.render(file, Uint8List.fromList([1]), 0),
        fails('pdf_unsupported'),
      );
      expect(calls, 0);
    },
  );
}
