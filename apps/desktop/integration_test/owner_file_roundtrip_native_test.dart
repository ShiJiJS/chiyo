// Four launches of one isolated native App. No production entry, Keychain,
// hooks, personal data, system input, or OS file panels are used here.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/owner_workspace_file_selections.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'owner_file_approvals_native.dart';
import 'synthetic_native_pdf.dart';

class _Keys implements DatabaseKeyStore {
  _Keys(this.salt);
  final int salt;
  @override
  Future<List<int>?> read() async =>
      List.generate(32, (i) => (i * 7 + salt) % 256);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Synthetic fixed key');
}

class _Picker implements InformationFilePicker {
  String? next;
  @override
  Future<String?> choose() async => next;
  @override
  Future<String?> saveAs(String name) async => null;
}

void _mode(String path, int mode) {
  final name = path.toNativeUtf8();
  try {
    final chmod = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint16),
          int Function(Pointer<Utf8>, int)
        >('chmod');
    if (chmod(name, mode) != 0) {
      throw StateError('Synthetic fixture permissions');
    }
  } finally {
    malloc.free(name);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const run = String.fromEnvironment('OWNER_FILE_ROUNDTRIP_RUN');
  if (!Platform.isMacOS || !RegExp(r'^[a-f0-9]{32}$').hasMatch(run)) {
    throw StateError('Explicit isolated file round-trip invocation required');
  }
  testWidgets('native file persistence, independent reopen and full backup restoration', (
    tester,
  ) async {
    final checks = <String>[];
    final root = Directory(
      '${Directory.systemTemp.path}/owner-file-roundtrip-$run',
    );
    var phase = 'initial';
    var state = <String, dynamic>{};
    EncryptedInformationRepository? repo;
    core.InformationService? service;
    OwnerWorkspaceSource? source;
    final picker = _Picker();
    final stateFile = File('${root.path}/private-state.json');
    var passed = false;
    binding.reportData = {
      'passed': false,
      'checks': checks,
      'pid': pid,
      'runtime': {'platform': 'macos'},
    };
    Future<void> io(Future<void> Function() action) async {
      final ok = await tester.runAsync(() async {
        await action();
        return true;
      });
      if (ok != true) throw StateError('Synthetic native operation failed');
    }

    try {
      await io(() async {
        expect(
          root.absolute.path,
          contains(
            '/Library/Containers/com.example.infoDesktop.zhiyuFileRoundTrip.$run/Data/',
          ),
        );
        if (!await root.exists()) {
          await root.create();
          _mode(root.path, 0x1c0);
          await File('${root.path}/fixture-marker').writeAsString(run);
          phase = 'live';
          state = {};
        } else {
          expect(await File('${root.path}/fixture-marker').readAsString(), run);
          phase = await File('${root.path}/next-phase').readAsString();
          state =
              jsonDecode(await stateFile.readAsString())
                  as Map<String, dynamic>;
        }
        expect(['live', 'reopen', 'restore', 'restored-read'], contains(phase));
        binding.reportData!.addAll({
          'phase': phase,
          'fixtureDirectory': root.path,
        });
        final restored = phase == 'restore' || phase == 'restored-read';
        final path = '${root.path}/${restored ? 'restored' : 'source'}';
        if (phase == 'reopen' || phase == 'restored-read') {
          expect(await File('$path/library.db').exists(), true);
        }
        repo = await EncryptedInformationRepository.open(
          path,
          _Keys(restored ? 91 : 17),
        );
        service = core.InformationService(
          repository: repo!,
          informationDeliveryFiles: core.NativeInformationDeliveryFiles(),
        );
        source = OwnerWorkspaceSource(
          owner: service!.owner,
          refreshInterval: Duration.zero,
          fileSelections: OwnerWorkspaceFileSelections(
            service!.owner,
            picker: picker,
          ),
        );
      });
      if (phase == 'live') {
        late core.InformationItem item;
        await io(() async {
          final input = File('${root.path}/synthetic.pdf');
          await input.writeAsBytes(syntheticNativePdf());
          picker.next = input.path;
          final selected = (await source!.selections.pick())!;
          final ref = await source!.importFile(
            WorkspaceFileImport(
              operationId: 'roundtrip-import',
              selectionId: selected.selectionId,
              name: 'Synthetic file round trip',
            ),
          );
          await input.delete();
          final fieldKey = (await source!.readDetail(ref)).fieldIds.keys.single;
          await input.writeAsBytes(syntheticNativePdf(inverted: true));
          final next = (await source!.selections.pick())!;
          await input.delete();
          await source!.changeFile(
            WorkspaceFileChange(
              operationId: 'roundtrip-replace',
              record: ref,
              fieldKey: fieldKey,
              expectedRecordVersion: 1,
              expectedFileVersion: 1,
              kind: WorkspaceFileChangeKind.replace,
              selectionId: next.selectionId,
            ),
          );
          item = service!.owner.information.single;
          expect(item.fields.single.attachment!.attachmentVersion, 2);
          state.addAll({
            'item': item.id,
            'field': item.fields.single.id,
            'fieldKey': fieldKey,
          });
          checks.add(
            'production import and replace persist both PDF originals; external inputs removed',
          );
        });
        final decision = await checkNativeFileApprovals(
          tester,
          service!,
          source!,
          item,
          syntheticNativePdf(inverted: true),
          checks,
        );
        await io(() async {
          state.addAll({
            'request': decision.requestId,
            'decision': decision.operationId,
          });
          // Leave one additional real grant active at export/shutdown. Its old
          // proofs are confined to this 0700 synthetic directory, never reports.
          final session = service!.agent.openSession('Synthetic restart proof');
          final ref = core.FieldRef(item.id, item.fields.single.id);
          final request = service!.agent.request(
            session,
            'Synthetic restart proof',
            [ref],
          );
          final review = await source!.approvals.read(request.id);
          await source!.approvals.change(
            WorkspaceApprovalChange(
              operationId: 'roundtrip-live-grant',
              requestId: request.id,
              reviewToken: review.reviewToken,
              action: WorkspaceApprovalAction.approve,
              selected: [review.scopes.single.id],
              fileVersions: {review.scopes.single.id: 2},
            ),
          );
          final token = service!.agent.claim(session, request.id).token;
          final copy = await service!.agent.fetchInformationFile(
            session,
            core.InformationFileFetchInput.fromJson({
              'protocolVersion': 2,
              'command': 'file-fetch',
              'requestId': request.id,
              'itemId': item.id,
              'fieldId': item.fields.single.id,
              'operationId': 'roundtrip-active-copy',
            }),
          );
          final path = (copy['delivery'] as Map)['path'] as String;
          expect(
            await File(path).readAsBytes(),
            syntheticNativePdf(inverted: true),
          );
          state.addAll({
            'oldSession': session,
            'oldToken': token,
            'liveRequest': request.id,
            'oldCopy': path,
          });
          final h = await source!.grantHistory.read(
            'request:${decision.requestId}',
          );
          final event = h.events.singleWhere((e) => e.fileScopeId != null);
          state['deliveryScope'] = event.fileScopeId;
          final original = await source!.grantHistory.filePreview(
            h.summary.id,
            event.fileScopeId!,
            page: 1,
          );
          state['pageSha256'] = sha256.convert(original.image!).toString();
          final recovery = await repo!.backups.enable();
          state['recovery'] = recovery;
          await repo!.backups.saveRecoveryKeyTo(
            '${root.path}/saved-recovery.txt',
          );
          await service!.owner.exportLibrary(
            () => repo!.backups.exportTo('${root.path}/full.aimbackup'),
          );
          expect(
            await File('${root.path}/full.aimbackup').length(),
            greaterThan(0),
          );
          await stateFile.writeAsString(jsonEncode(state));
          _mode(stateFile.path, 0x180);
          checks.add(
            'full encrypted backup includes retained originals and real delivery/grant facts while a separate grant is active',
          );
        });
      } else {
        await io(() async {
          if (phase == 'restore') {
            expect(service!.owner.information, isEmpty);
            await service!.owner.restoreLibrary(
              () => repo!.backups.restoreFrom(
                '${root.path}/full.aimbackup',
                state['recovery'] as String,
              ),
            );
            expect(source!.isCurrentLibrary, false);
            await source!.dispose();
            source = OwnerWorkspaceSource(
              owner: service!.owner,
              refreshInterval: Duration.zero,
            );
            checks.add(
              'full encrypted archive restores through Owner barrier into empty library with a different database key',
            );
          }
          final ref = WorkspaceRecordRef(
            WorkspaceRecordKind.information,
            state['item'] as String,
          );
          final history = await source!.loadFileHistory(
            ref,
            state['fieldKey'] as String,
          );
          expect(history.current.ref.version, 2);
          expect(history.versions.map((v) => v.ref.version).toSet(), {1, 2});
          for (final version in history.versions) {
            final original = await service!.owner.readInformationAttachment(
              core.InformationAttachmentRef(
                version.ref.id,
                version.ref.version,
              ),
            );
            expect(
              original.bytes,
              syntheticNativePdf(inverted: version.ref.version == 2),
            );
          }
          checks.add(
            'independent App process reads current and retained originals byte-for-byte',
          );
          final hid = 'request:${state['request']}';
          final h = await source!.grantHistory.read(hid);
          expect(h.summary.state.isActive, false);
          expect(
            h.scopes
                .singleWhere((s) => s.kind == WorkspaceApprovalScopeKind.file)
                .fileVersion,
            2,
          );
          final event = h.events.singleWhere((e) => e.fileScopeId != null);
          expect(event.fileScopeId, state['deliveryScope']);
          final rendered = await source!.grantHistory.filePreview(
            hid,
            event.fileScopeId!,
            page: 1,
          );
          expect(
            sha256.convert(rendered.image!).toString(),
            state['pageSha256'],
          );
          checks.add(
            'original approval/delivery identity and native PDF page survive independent reopen or restore',
          );
          expect(service!.owner.sessions, isEmpty);
          final oldField = core.FieldRef(
            state['item'] as String,
            state['field'] as String,
          );
          await expectLater(
            service!.agent.read(state['oldToken'] as String, oldField),
            throwsA(isA<core.AccessFailure>()),
          );
          expect(
            () => service!.agent.claim(
              state['oldSession'] as String,
              state['liveRequest'] as String,
            ),
            throwsA(isA<core.AccessFailure>()),
          );
          final old = await source!.approvals.read(
            state['liveRequest'] as String,
          );
          expect(old.canApprove, false);
          expect(
            (await source!.grantHistory.read(
              'request:${state['liveRequest']}',
            )).summary.state.isActive,
            false,
          );
          final copies = service!.owner.informationFileDeliveries;
          expect(copies, hasLength(2));
          expect(copies.every((d) => !d.holdsCopy && d.lease == null), true);
          expect(await File(state['oldCopy'] as String).exists(), false);
          checks.add(
            'previous active bearer and session are refused; neither history nor restore recreates a managed copy',
          );
          if (phase == 'reopen') {
            expect(
              (await source!.approvals.receipt(
                state['decision'] as String,
              ))!.requestId,
              state['request'],
            );
            expect(
              (await source!.fileOperationReceipt(
                'roundtrip-replace',
              ))!.file!.version,
              2,
            );
            checks.add(
              'local original approval and replacement receipts remain available after App process restart',
            );
          } else {
            expect(
              await source!.approvals.receipt(state['decision'] as String),
              null,
            );
            expect(
              await source!.fileOperationReceipt('roundtrip-replace'),
              null,
            );
            expect(
              copies.every((d) => !d.runtime && d.restoredAt != null),
              true,
            );
            expect(h.legacyNotice, contains('恢复的历史事实'));
            checks.add(
              'portable restoration excludes local receipts/leases while preserving read-only delivery history',
            );
          }
        });
      }
      final error = tester.takeException();
      if (error != null) throw error;
      passed = true;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await io(() async {
        await source?.dispose();
        await service?.close();
        await repo?.close();
        if (passed && phase == 'live') {
          expect(await File(state['oldCopy'] as String).exists(), false);
          checks.add(
            'normal native process shutdown removes its registered active copy before close completes',
          );
        }
        if (!passed || phase == 'restored-read') {
          if (await root.exists()) await root.delete(recursive: true);
        } else {
          final next = {
            'live': 'reopen',
            'reopen': 'restore',
            'restore': 'restored-read',
          }[phase]!;
          await File('${root.path}/next-phase').writeAsString(next);
        }
        binding.reportData!.addAll({
          'passed': passed,
          'fixtureRemoved': !await root.exists(),
        });
      });
    }
  });
}
