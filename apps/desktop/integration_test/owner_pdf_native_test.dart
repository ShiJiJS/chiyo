// Test entry only. No production bootstrap, Keychain, hooks or OS input.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/library_file.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async =>
      List.generate(32, (i) => (i * 7 + 11) % 256);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Synthetic key already exists');
}

List<int> _pdf() {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 5 0 R >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 6 0 R >>',
  ];
  for (final color in ['1 0 0', '0 0 1']) {
    final stream = '$color rg 0 0 200 100 re f\n';
    objects.add(
      '<< /Length ${ascii.encode(stream).length} >>\nstream\n${stream}endstream',
    );
  }
  var text = '%PDF-1.4\n';
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(ascii.encode(text).length);
    text += '${i + 1} 0 obj\n${objects[i]}\nendobj\n';
  }
  final xref = ascii.encode(text).length;
  text += 'xref\n0 ${objects.length + 1}\n0000000000 65535 f \n';
  for (final offset in offsets) {
    text += '${offset.toString().padLeft(10, '0')} 00000 n \n';
  }
  text +=
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n';
  return ascii.encode(text);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const run = String.fromEnvironment('OWNER_PDF_NATIVE_RUN');
  if (!Platform.isMacOS || !RegExp(r'^[a-f0-9]{32}$').hasMatch(run)) {
    throw StateError('Explicit synthetic PDF native invocation required');
  }
  testWidgets('real sandbox Owner SQLCipher to PDF channel and page controls', (
    tester,
  ) async {
    final checks = <String>[];
    binding.reportData = {
      'passed': false,
      'runtime': {'platform': 'macos'},
      'checks': checks,
    };
    Directory? root;
    EncryptedInformationRepository? repo;
    core.InformationService? service;
    OwnerWorkspaceSource? source;
    late core.InformationItem item;
    late String field;
    late WorkspaceFilePreview first;
    try {
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('owner-pdf-$run-');
        expect(
          root!.resolveSymbolicLinksSync(),
          contains(
            '/Library/Containers/com.example.infoDesktop.zhiyuOwnerPdfCheck.$run/Data/',
          ),
        );
        repo = await EncryptedInformationRepository.open(
          '${root!.path}/library',
          _Keys(),
        );
        service = core.InformationService(repository: repo!);
        source = OwnerWorkspaceSource(
          owner: service!.owner,
          refreshInterval: Duration.zero,
        );
        final input = File('${root!.path}/synthetic.pdf');
        await input.writeAsBytes(_pdf());
        final draft = await service!.owner.beginInformationFileDraft();
        final stage = await service!.owner.stageInformationFile(
          draft,
          input.path,
          mediaType: 'application/pdf',
        );
        item = await service!.owner.commitInformationDraft(
          draft,
          'save',
          core.InformationDraftInput(
            name: 'Synthetic PDF',
            description: '',
            fields: [
              core.InformationDraftField.stagedFile('PDF', '', stage.id),
            ],
          ),
        );
        await service!.owner.releaseInformationFileDraft(draft);
        await input.delete();
        checks.add('real SQLCipher intake; external original deleted');
        final ref = WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          item.id,
        );
        field = (await source!.readDetail(ref)).fieldIds.keys.single;
        first = await source!.readFilePreview(ref, field);
        expect(first.kind, WorkspaceFilePreviewKind.image);
        expect(first.page, 0);
        expect(first.pageCount, 2);
        expect(first.pixelWidth, 400);
        expect(first.pixelHeight, 200);
        checks.add(
          'actual native channel returns first PDF page and exact metadata',
        );
      });
      int? next;
      Widget reader(WorkspaceFilePreview page) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LibraryFilePreviewView(
              preview: page,
              onPage: (value) => next = value,
            ),
          ),
        ),
      );
      await tester.pumpWidget(reader(first));
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-file-page-next')));
      await tester.pump();
      expect(next, 1);
      checks.add('production reader next-page control selects page1');
      late WorkspaceFilePreview second;
      await tester.runAsync(() async {
        final ref = WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          item.id,
        );
        second = await source!.readFilePreview(ref, field, page: next!);
        expect(second.page, 1);
        expect(second.pageCount, 2);
        expect(second.image, isNot(equals(first.image)));
        await expectLater(
          source!.readFilePreview(ref, field, page: 2),
          throwsA(
            isA<WorkspaceFailure>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        checks.add('second actual page differs; out-of-range error preserved');
      });
      await tester.pumpWidget(reader(second));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      next = null;
      await tester.tap(find.byKey(const ValueKey('library-file-page-back')));
      await tester.pump();
      expect(next, 0);
      checks.add('production reader previous-page control selects page0');
      await tester.runAsync(() async {
        await source!.dispose();
        await service!.close();
        await repo!.close();
        repo = await EncryptedInformationRepository.open(
          '${root!.path}/library',
          _Keys(),
        );
        service = core.InformationService(repository: repo!);
        source = OwnerWorkspaceSource(
          owner: service!.owner,
          refreshInterval: Duration.zero,
        );
        final reopened = await source!.readFilePreview(
          WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
          field,
          page: 1,
        );
        expect(reopened.image, second.image);
        checks.add('SQLCipher/service reopen returns identical native page');
      });
      binding.reportData!['passed'] = true;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await source?.dispose();
        await service?.close();
        await repo?.close();
        if (root != null) await root!.delete(recursive: true);
        binding.reportData!['fixtureRemoved'] =
            root == null || !await root!.exists();
      });
    }
  });
}
