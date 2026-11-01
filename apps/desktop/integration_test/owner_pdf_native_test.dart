// Test entry only. No production bootstrap, Keychain, hooks or OS input.
import 'dart:convert';
import 'owner_file_approvals_native.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/library_file.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/workspace/owner_file_open_dispatcher.dart';
import 'package:info_desktop/workspace/owner_workspace_file_selections.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async =>
      List.generate(32, (i) => (i * 7 + 11) % 256);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Synthetic key already exists');
}

class _Picker implements InformationFilePicker {
  String? next;
  @override
  Future<String?> choose() async => next;
  @override
  Future<String?> saveAs(String name) async => null;
}

// Only the OS selection/allocation is supplied by this synthetic harness.
// Publication, SQLCipher journal and production source remain real.
class _OutputPicker extends BackupFilePicker {
  _OutputPicker(this.root);
  final Directory root;
  @override
  Future<String?> recoveryKeyOutput() async => null;
  @override
  Future<String?> backupOutput() async => null;
  @override
  Future<String?> backupInput() async => null;
  @override
  Future<String?> ownerFileOutput(String name) async =>
      '${root.path}/synthetic-saved.pdf';
  @override
  Future<BackupStaging?> prepareStaging(String path) async =>
      BackupStaging((await root.createTemp('output-stage-')).path, 'synthetic');
  @override
  Future<void> releaseRecordedStaging(Map<String, Object?> directory) async {}
}

// The document receiver is injected: no external app or user window is opened.
// The Owner copy, encrypted journal, native file driver and cleanup are real.
class _OpenReceiver implements OwnerFileOpenDispatcher {
  int calls = 0;
  core.InformationDeliveryLease? lease;
  @override
  Future<OwnerFileDispatchOutcome> open(
    String id,
    String digest,
    core.InformationDeliveryLease value,
    int length,
    String hash,
  ) async {
    calls++;
    lease = value;
    await core.NativeInformationDeliveryFiles().verify(value, length, hash);
    expect(await File(value.filePath).readAsBytes(), _pdf());
    return OwnerFileDispatchOutcome.opened;
  }

  @override
  Future<OwnerFileDispatchOutcome?> status(String id, String digest) async =>
      OwnerFileDispatchOutcome.opened;
}

List<int> _pdf({bool inverted = false}) {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 5 0 R >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 6 0 R >>',
  ];
  for (final color in (inverted ? ['0 0 1', '1 0 0'] : ['1 0 0', '0 0 1'])) {
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
  const fileChanges = bool.fromEnvironment('OWNER_PDF_FILE_CHANGES');
  const fileOutputs = bool.fromEnvironment('OWNER_FILE_OUTPUTS');
  const fileOpens = bool.fromEnvironment('OWNER_FILE_OPENS');
  const fileApprovals = bool.fromEnvironment('OWNER_FILE_APPROVALS');
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
    final picker = _Picker();
    final receiver = _OpenReceiver();
    WorkspaceFileChange? restoredCommand;
    NativeFileApprovalEvidence? approvalEvidence;
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
        service = core.InformationService(
          repository: repo!,
          informationDeliveryFiles: core.NativeInformationDeliveryFiles(),
        );
        source = OwnerWorkspaceSource(
          owner: service!.owner,
          fileOutputs: fileOutputs ? repo!.fileOutputs : null,
          fileOpens: fileOpens ? repo!.fileOpens : null,
          openDispatcher: receiver,
          outputPicker: _OutputPicker(root!),
          refreshInterval: Duration.zero,
          fileSelections: OwnerWorkspaceFileSelections(
            service!.owner,
            picker: picker,
          ),
        );
        final input = File('${root!.path}/synthetic.pdf');
        await input.writeAsBytes(_pdf());
        if (fileChanges) {
          picker.next = input.path;
          final selected = (await source!.selections.pick())!;
          final record = await source!.importFile(
            WorkspaceFileImport(
              operationId: 'native-import',
              selectionId: selected.selectionId,
              name: 'Synthetic PDF',
            ),
          );
          item = service!.owner.information.singleWhere(
            (i) => i.id == record.id,
          );
        } else {
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
        }
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
      if (fileChanges) {
        await tester.runAsync(() async {
          final input = File('${root!.path}/replacement.pdf');
          await input.writeAsBytes(_pdf(inverted: true));
          picker.next = input.path;
          final selected = (await source!.selections.pick())!;
          await input.delete();
          final ref = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            item.id,
          );
          final history = await source!.loadFileHistory(ref, field);
          final replacement = await source!.changeFile(
            WorkspaceFileChange(
              operationId: 'native-replace',
              record: ref,
              fieldKey: field,
              expectedRecordVersion: history.recordVersion,
              expectedFileVersion: history.current.ref.version,
              kind: WorkspaceFileChangeKind.replace,
              selectionId: selected.selectionId,
            ),
          );
          expect(replacement.version, 2);
          expect(
            (await source!.readFilePreview(ref, field, page: 1)).image,
            first.image,
          );
          checks.add(
            'actual source replacement promotes encrypted PDF and renders new bytes',
          );
          final updated = await source!.loadFileHistory(ref, field);
          restoredCommand = WorkspaceFileChange(
            operationId: 'native-restore',
            record: ref,
            fieldKey: field,
            expectedRecordVersion: updated.recordVersion,
            expectedFileVersion: updated.current.ref.version,
            kind: WorkspaceFileChangeKind.restore,
            restoreVersion: 1,
          );
          final restored = await source!.changeFile(restoredCommand!);
          expect(restored.version, 3);
          expect(restored.id, replacement.id);
          expect(
            (await source!.readFilePreview(ref, field, page: 1)).image,
            second.image,
          );
          checks.add(
            'retained PDF restore creates v3 and renders exact old bytes',
          );
          expect(
            (await source!.fileOperationReceipt(
              'native-restore',
            ))!.commandDigest,
            restoredCommand!.digest,
          );
          expect(await source!.changeFile(restoredCommand!), restored);
          expect(
            (await source!.loadFileHistory(ref, field)).versions.length,
            3,
          );
          checks.add(
            'persistent exact file receipt prevents duplicate restore',
          );
        });
      }
      if (fileOutputs) {
        await tester.runAsync(() async {
          final ref = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            item.id,
          );
          final history = await source!.loadFileHistory(ref, field);
          final saved = await source!.fileAction(
            ref,
            field,
            history.current.ref.version,
            WorkspaceFileAction.saveAs,
            operationId: 'native-save-as',
          );
          expect(saved.completed, true);
          expect(saved.cleanupPending, false);
          expect(
            await File('${root!.path}/synthetic-saved.pdf').readAsBytes(),
            _pdf(),
          );
          expect(
            (await source!.fileOperationReceipt(
              'native-save-as',
            ))!.actionCompleted,
            true,
          );
          expect((await source!.fileActionState(ref, field)).cleanupPending, 0);
          checks.add(
            'real sandbox no-overwrite Save As and durable receipt; synthetic OS selection only',
          );
        });
      }
      if (fileOpens) {
        await tester.runAsync(() async {
          expect(
            await const NativeOwnerFileOpenDispatcher().status(
              'native-absent',
              'a' * 64,
            ),
            null,
          );
          checks.add(
            'actual production Owner file-open channel reports native cache absence without opening a program',
          );
          final ref = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            item.id,
          );
          final h = await source!.loadFileHistory(ref, field);
          expect(
            (await source!.fileAction(
              ref,
              field,
              h.current.ref.version,
              WorkspaceFileAction.open,
              operationId: 'native-owner-open',
            )).completed,
            true,
          );
          expect(receiver.calls, 1);
          expect(receiver.lease!.filePath, contains('/Library/Containers/'));
          expect(
            (await source!.fileOperationReceipt(
              'native-owner-open',
            ))!.openCopyHeld,
            true,
          );
          checks.add(
            'real sandbox Owner temporary copy and persistent accepted dispatch; document receiver injected',
          );
        });
      }
      if (fileApprovals) {
        approvalEvidence = await checkNativeFileApprovals(
          tester,
          service!,
          source!,
          item,
          _pdf(),
          checks,
        );
      }
      await tester.runAsync(() async {
        await source!.dispose();
        await service!.close();
        await repo!.close();
        repo = await EncryptedInformationRepository.open(
          '${root!.path}/library',
          _Keys(),
        );
        service = core.InformationService(
          repository: repo!,
          informationDeliveryFiles: core.NativeInformationDeliveryFiles(),
        );
        source = OwnerWorkspaceSource(
          owner: service!.owner,
          fileOutputs: fileOutputs ? repo!.fileOutputs : null,
          fileOpens: fileOpens ? repo!.fileOpens : null,
          openDispatcher: receiver,
          outputPicker: _OutputPicker(root!),
          refreshInterval: Duration.zero,
        );
        final reopened = await source!.readFilePreview(
          WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
          field,
          page: 1,
        );
        expect(reopened.image, second.image);
        if (restoredCommand != null) {
          expect((await source!.changeFile(restoredCommand!)).version, 3);
          expect(
            (await source!.fileOperationReceipt(
              'native-restore',
            ))!.commandDigest,
            restoredCommand!.digest,
          );
        }
        if (fileOutputs) {
          final ref = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            item.id,
          );
          final current = await source!.loadFileHistory(ref, field);
          expect(
            (await source!.fileAction(
              ref,
              field,
              current.current.ref.version,
              WorkspaceFileAction.saveAs,
              operationId: 'native-save-as',
            )).completed,
            true,
          );
          expect(
            await File('${root!.path}/synthetic-saved.pdf').readAsBytes(),
            _pdf(),
          );
          checks.add(
            'reopened sandbox Save As reuses original receipt without another publication',
          );
        }
        if (fileOpens) {
          final ref = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            item.id,
          );
          await repo!.fileOpens.maintain(closePrevious: true);
          expect(await File(receiver.lease!.filePath).exists(), false);
          final h = await source!.loadFileHistory(ref, field);
          expect(
            (await source!.fileAction(
              ref,
              field,
              h.current.ref.version,
              WorkspaceFileAction.open,
              operationId: 'native-owner-open',
            )).completed,
            true,
          );
          expect(receiver.calls, 1);
          expect(
            (await source!.fileOperationReceipt(
              'native-owner-open',
            ))!.openCopyHeld,
            false,
          );
          checks.add(
            'reopened sandbox closes previous Owner copy without redispatch and preserves original outcome',
          );
        }
        if (approvalEvidence case final evidence?) {
          expect(
            (await source!.approvals.receipt(evidence.operationId))!.requestId,
            evidence.requestId,
          );
          final previous = await source!.approvals.read(evidence.requestId);
          expect(
            previous.request.state,
            isIn([
              WorkspaceApprovalState.revoked,
              WorkspaceApprovalState.sessionEnded,
            ]),
          );
          expect(previous.canApprove, false);
          expect(service!.owner.sessions, isEmpty);
          final oldHistory = await source!.grantHistory.read(
            'request:${evidence.requestId}',
          );
          final delivered = oldHistory.events.singleWhere(
            (e) => e.fileScopeId != null,
          );
          expect(oldHistory.summary.state.isActive, false);
          expect(
            (await source!.grantHistory.filePreview(
              oldHistory.summary.id,
              delivered.fileScopeId!,
              page: 1,
            )).image,
            second.image,
          );
          checks.add(
            'reopened history retains delivery facts and exact original native PDF preview without reviving capability',
          );
          checks.add(
            'reopened SQLCipher keeps original file approval receipt and terminal facts without reviving a session',
          );
        }
        checks.add('SQLCipher/service reopen returns identical native page');
      });
      binding.reportData!['passed'] = true;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await source?.dispose();
        await service?.close();
        await repo?.fileOpens.maintain(closeAll: true);
        await repo?.close();
        if (root != null) await root!.delete(recursive: true);
        binding.reportData!['fixtureRemoved'] =
            root == null || !await root!.exists();
      });
    }
  });
}
