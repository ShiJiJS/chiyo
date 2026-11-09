import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/information_files.dart';
import 'support/native_file_actions_fixture.dart';
import 'package:info_desktop/workspace/remote_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class _RealHttp extends HttpOverrides {}

class _Picker implements InformationFilePicker {
  String? path;
  int choices = 0;
  @override
  Future<String?> choose() async {
    choices++;
    return path;
  }

  @override
  Future<String?> saveAs(String name) async => null;
}

void main() {
  test(
    'remote originals use real local publication and managed opening with durable replay and cleanup',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        var root = await Directory.systemTemp.createTemp(
          'chiyo-file-response-loss-',
        );
        root = Directory(await root.resolveSymbolicLinks());
        await initializeServerSecrets('${root.path}/secrets');
        final fixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(fixture.ca);
        final token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        final repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        final runtime = await core.OnlineInformationRuntime.open(
          repository: repo,
        );
        const serverId = 'file-response-loss-synthetic';
        final server = await OnlineServer.start(
          runtime: runtime,
          devices: AgentDeviceRegistry(repo),
          tls: tls,
          ownerToken: token,
          serverId: serverId,
        );
        final direct = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${server.port}'),
          token: token,
          trust: trust,
        );
        final picker = _Picker();
        final output = SyntheticOutputPicker();
        final dispatcher = SyntheticOpenDispatcher();
        RemoteWorkspaceSource? source;
        Future<void> connect() async {
          source = RemoteWorkspaceSource(
            await OwnerClient.connect(
              address: direct.address,
              token: token,
              trust: trust,
            ),
            filePicker: picker,
            deviceFilesDirectory: '${root.path}/device-files',
            outputPicker: output,
            openDispatcher: dispatcher,
          );
        }

        Matcher fails(String code) => throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'code', code),
        );
        try {
          await connect();
          final original = File('${root.path}/first.md');
          final replacement = File('${root.path}/second.md');
          await original.writeAsString('## FIRST_SYNTHETIC_ORIGINAL');
          await replacement.writeAsString('## SECOND_SYNTHETIC_ORIGINAL');
          picker.path = original.path;
          final selected = (await source!.files.pick())!;
          final ref = await source!.importFile(
            WorkspaceFileImport(
              operationId: 'import-original',
              selectionId: selected.selectionId,
              name: 'Remote original',
            ),
          );
          picker.path = replacement.path;
          final second = (await source!.files.pick())!;
          await source!.changeFile(
            WorkspaceFileChange(
              operationId: 'replace-original',
              record: ref,
              fieldKey: 'file',
              expectedRecordVersion: 1,
              expectedFileVersion: 1,
              kind: WorkspaceFileChangeKind.replace,
              selectionId: second.selectionId,
            ),
          );
          final destination = File('${root.path}/user-saved.md');
          output.output = destination.path;
          final result = await source!.fileAction(
            ref,
            'file',
            2,
            WorkspaceFileAction.saveAs,
            operationId: 'save-remote',
          );
          expect(result.completed, true);
          expect(
            await destination.readAsBytes(),
            await replacement.readAsBytes(),
          );
          expect(
            (await source!.fileOperationReceipt(
              'save-remote',
            ))!.actionCompleted,
            true,
          );
          expect(
            (await source!.fileActionState(ref, 'file')).cleanupPending,
            0,
          );
          final panels = output.panels;
          await source!.dispose();
          source = null;
          await connect();
          // A durable success is a past action, never permission to overwrite it.
          await destination.writeAsString('USER_EDIT_AFTER_SAVE');
          expect(
            (await source!.fileAction(
              ref,
              'file',
              2,
              WorkspaceFileAction.saveAs,
              operationId: 'save-remote',
            )).completed,
            true,
          );
          expect(output.panels, panels);
          expect(await destination.readAsString(), 'USER_EDIT_AFTER_SAVE');
          await expectLater(
            source!.fileAction(
              ref,
              'file',
              2,
              WorkspaceFileAction.saveAs,
              operationId: 'no-overwrite',
            ),
            fails('not_saved'),
          );
          expect(await destination.readAsString(), 'USER_EDIT_AFTER_SAVE');
          await expectLater(
            source!.fileAction(
              ref,
              'file',
              1,
              WorkspaceFileAction.saveAs,
              operationId: 'stale-version',
            ),
            fails('conflict'),
          );
          final beforeOpen = dispatcher.launches;
          dispatcher.drop = true;
          expect(
            (await source!.fileAction(
              ref,
              'file',
              2,
              WorkspaceFileAction.open,
              operationId: 'open-remote',
            )).completed,
            true,
          );
          expect(dispatcher.launches, beforeOpen + 1);
          expect(
            await File(dispatcher.leases.last.filePath).readAsBytes(),
            await replacement.readAsBytes(),
          );
          dispatcher.loseStatus = true;
          await expectLater(
            source!.fileAction(
              ref,
              'file',
              2,
              WorkspaceFileAction.open,
              operationId: 'open-unknown',
            ),
            fails('unknown_outcome'),
          );
          expect(
            (await source!.fileActionState(ref, 'file')).pending!.operationId,
            'open-unknown',
          );
          await expectLater(
            source!.fileAction(
              ref,
              'file',
              2,
              WorkspaceFileAction.saveAs,
              operationId: 'must-not-save',
            ),
            fails('previous_pending'),
          );
          final launches = dispatcher.launches;
          dispatcher.loseStatus = false;
          expect(
            (await source!.fileOperationReceipt(
              'open-unknown',
            ))!.actionCompleted,
            true,
          );
          expect(dispatcher.launches, launches);
          await source!.closeOpenFileCopies(ref, 'file');
          expect((await source!.fileActionState(ref, 'file')).openCopies, 0);
          for (final lease in dispatcher.leases) {
            expect(await File(lease.filePath).exists(), false);
          }
          expect(await destination.readAsString(), 'USER_EDIT_AFTER_SAVE');
          dispatcher.drop = false;
          await source!.fileAction(
            ref,
            'file',
            2,
            WorkspaceFileAction.open,
            operationId: 'open-until-exit',
          );
          final copy = dispatcher.leases.last;
          expect(await File(copy.filePath).exists(), true);
          await source!.dispose();
          source = null;
          expect(await File(copy.filePath).exists(), false);
          expect(await destination.readAsString(), 'USER_EDIT_AFTER_SAVE');
          await connect();
          expect(
            (await source!.fileOperationReceipt(
              'open-until-exit',
            ))!.actionCompleted,
            true,
          );
          expect((await source!.fileActionState(ref, 'file')).openCopies, 0);
          await expectLater(
            source!.fileAction(
              ref,
              'file',
              2,
              WorkspaceFileAction.saveAs,
              operationId: 'replace-original',
            ),
            fails('operation_conflict'),
          );
          expect((await direct.information()).single.version, 2);
          expect(
            (await source!.readFilePreview(ref, 'file', version: 1)).text,
            '## FIRST_SYNTHETIC_ORIGINAL',
          );
          // A live panel is not a lock on the server record. If it changes,
          // the old original must not be published under the new binding.
          output.output = '${root.path}/must-not-save-after-change.md';
          output.panelStarted = Completer<void>();
          output.panelDone = Completer<void>();
          final pendingSave = source!.fileAction(
            ref,
            'file',
            2,
            WorkspaceFileAction.saveAs,
            operationId: 'changed-during-panel',
          );
          final rejectedSave = expectLater(pendingSave, fails('conflict'));
          await output.panelStarted!.future;
          picker.path = original.path;
          final changed = (await source!.files.pick())!;
          await source!.changeFile(
            WorkspaceFileChange(
              operationId: 'replace-during-panel',
              record: ref,
              fieldKey: 'file',
              expectedRecordVersion: 2,
              expectedFileVersion: 2,
              kind: WorkspaceFileChangeKind.replace,
              selectionId: changed.selectionId,
            ),
          );
          output.panelDone!.complete();
          await rejectedSave;
          expect(await File(output.output!).exists(), false);
          expect(await destination.readAsString(), 'USER_EDIT_AFTER_SAVE');
          expect((await direct.information()).single.version, 3);
        } finally {
          await source?.dispose();
          direct.close();
          await server.close();
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        }
      }, _RealHttp());
    },
  );
}
