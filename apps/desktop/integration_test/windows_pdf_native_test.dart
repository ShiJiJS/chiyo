import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_desktop/workspace/owner_pdf_preview.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'synthetic_native_pdf.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows real PDF channel returns original pages and bounded errors',
    (tester) async {
      expect(Platform.isWindows, isTrue);
      const project = String.fromEnvironment('CHIYO_TEST_REPO_ROOT');
      expect(project, isNotEmpty);
      const renderer = NativeOwnerPdfPreview();
      final bytes = Uint8List.fromList(syntheticNativePdf());
      final file = WorkspaceFileVersion(
        ref: const WorkspaceFileRef('windows-native-pdf', 1),
        filename: 'synthetic.pdf',
        mediaType: 'application/pdf',
        byteLength: bytes.length,
        createdAt: DateTime.utc(2026),
      );
      late WorkspaceFilePreview first, second;
      await tester.runAsync(() async {
        first = await renderer.render(file, bytes, 0);
        second = await renderer.render(file, bytes, 1);
        expect(first.pageCount, 2);
        expect(first.pixelWidth, inInclusiveRange(527, 534));
        expect(first.pixelHeight, inInclusiveRange(260, 267));
        expect(second.page, 1);
        expect(second.image, isNot(equals(first.image)));
        final failure = isA<WorkspaceFailure>();
        await expectLater(
          renderer.render(file, bytes, 2),
          throwsA(failure.having((e) => e.code, 'code', 'invalid_request')),
        );
        await expectLater(
          renderer.render(file, Uint8List.fromList([1, 2, 3]), 0),
          throwsA(failure.having((e) => e.code, 'code', 'invalid_pdf')),
        );
        final fixture = await File(
          '$project/apps/desktop/windows/runner/owner_pdf_locked_fixture.h',
        ).readAsString();
        final locked = Uint8List.fromList(
          RegExp(r'0x([0-9a-f]{2})')
              .allMatches(fixture)
              .map((match) => int.parse(match[1]!, radix: 16))
              .toList(),
        );
        expect(locked.length, 827);
        await expectLater(
          renderer.render(file, locked, 0),
          throwsA(failure.having((e) => e.code, 'code', 'pdf_locked')),
        );
      });
      int? requested;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryFilePreviewView(
              preview: first,
              onPage: (page) => requested = page,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-file-page-next')));
      expect(requested, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryFilePreviewView(
              preview: second,
              onPage: (page) => requested = page,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-file-page-back')));
      expect(requested, 0);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
