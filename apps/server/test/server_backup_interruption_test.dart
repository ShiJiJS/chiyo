import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_workspace/backup_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';
import 'support/tls_fixture.dart';

class _SyntheticKey implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  test(
    'real online server SIGKILL during uncommitted large restore rolls back data and original device identity, then restores once through the same HTTPS entry',
    () async {
      final created = await Directory.systemTemp.createTemp(
        'chiyo-server-restore-crash-',
      );
      final root = Directory(await created.resolveSymbolicLinks());
      addTearDown(() => root.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/single-machine',
        _SyntheticKey(),
      );
      final old = InformationService(repository: source);
      final originals = <InformationItem>[];
      String recovery;
      final archive = File('${root.path}/synthetic80.aimbackup');
      try {
        for (var i = 0; i < 10; i++) {
          final draft = await old.owner.beginInformationFileDraft();
          try {
            final stage = await old.owner.stageInformationBytes(
              draft,
              originalName: 'synthetic-$i.bin',
              bytes: Uint8List(8 * 1024 * 1024)
                ..fillRange(0, 8 * 1024 * 1024, i + 1),
            );
            originals.add(
              await old.owner.commitInformationDraft(
                draft,
                'large-$i',
                InformationDraftInput(
                  name: '合成中断测试 $i',
                  description: '',
                  fields: [
                    InformationDraftField.stagedFile('附件', '', stage.id),
                  ],
                ),
              ),
            );
          } finally {
            await old.owner.releaseInformationFileDraft(draft);
          }
        }
        recovery = await source.backups.enable();
        await source.backups.saveRecoveryKeyTo('${root.path}/independent.key');
        await old.owner.exportLibrary(
          () => source.backups.exportTo(archive.path),
        );
      } finally {
        await old.close();
        await source.close();
      }
      await initializeServerSecrets('${root.path}/secrets');
      final tls = await createTlsFixture(root);
      expect(
        (await Process.run('/bin/chmod', ['600', tls.privateKey])).exitCode,
        0,
      );
      final config = File('${root.path}/server.json');
      await config.writeAsString(
        jsonEncode({
          'dataDirectory': 'data',
          'secretsDirectory': 'secrets',
          'tlsCertificate': tls.certificate,
          'tlsPrivateKey': tls.privateKey,
          'port': 0,
        }),
      );
      final token = base64Url
          .encode(await File('${root.path}/secrets/owner.token').readAsBytes())
          .replaceAll('=', '');
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(tls.ca);
      Process? process;
      int? vmPid;
      OwnerClient? connection;
      var errors = <String>[];
      Future<void> start() async {
        errors = [];
        final p = await Process.start(Platform.resolvedExecutable, [
          'run',
          'test/support/server_backup_child.dart',
          config.path,
        ]);
        process = p;
        p.stderr.transform(utf8.decoder).listen(errors.add);
        final ready = Completer<Map<String, dynamic>>();
        p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            final value = jsonDecode(line) as Map<String, dynamic>;
            if (value['fixturePid'] is int) vmPid = value['fixturePid'] as int;
            if (value['state'] == 'ready' && !ready.isCompleted)
              ready.complete(value);
          },
        );
        unawaited(
          p.exitCode.then((code) {
            if (!ready.isCompleted)
              ready.completeError(
                StateError('Synthetic service exited $code: ${errors.join()}'),
              );
          }),
        );
        final identity = await ready.future.timeout(
          const Duration(seconds: 60),
        );
        connection = await OwnerClient.connect(
          address: Uri.parse('https://127.0.0.1:${identity['port']}'),
          token: token,
          trust: trust,
          expectedServerId: identity['serverId'] as String,
        );
      }

      addTearDown(() async {
        connection?.close();
        final p = process;
        if (p != null) {
          if (vmPid != null) Process.killPid(vmPid!, ProcessSignal.sigkill);
          await p.exitCode.timeout(const Duration(seconds: 15));
        }
      });
      await start();
      final originalServer = connection!.serverId;
      final device = await connection!.request('POST', '/v1/owner/devices', {
        'operationId': 'crash-device',
        'name': '合成中断设备',
      });
      final devices = await connection!.request('GET', '/v1/owner/devices');
      final database = File('${root.path}/data/library.db');
      final journal = File('${database.path}-journal');

      Future<WorkspaceBackupChange> inspect(String id) async {
        final o = connection!;
        final resource = WorkspaceBackupResource(
          id: id,
          name: 'synthetic80.aimbackup',
          kind: WorkspaceBackupPick.archiveInput,
        );
        final bytes = await archive.readAsBytes();
        await o.request('POST', '/v1/owner/backups/uploads', {
          'wireVersion': 1,
          'uploadId': id,
          'resource': resource.json,
          'byteLength': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        });
        for (var offset = 0; offset < bytes.length; offset += 512 * 1024) {
          final end = (offset + 512 * 1024).clamp(0, bytes.length);
          await o.request('POST', '/v1/owner/backups/uploads/$id/chunks', {
            'wireVersion': 1,
            'offset': offset,
            'bytes': base64Encode(bytes.sublist(offset, end)),
          });
        }
        final preview = backupPreviewFromJson(
          await o.request('POST', '/v1/owner/backups/inspect', {
            'wireVersion': 1,
            'uploadId': id,
            'archive': resource.json,
            'key': const WorkspaceBackupResource(
              id: 'independent_key',
              name: 'recovery.key',
              kind: WorkspaceBackupPick.keyInput,
            ).json,
            'recoveryKey': recovery,
          }),
        );
        expect(
          preview.counts[WorkspaceBackupCategory.fileBytes],
          80 * 1024 * 1024,
        );
        final status = backupStatusFromJson(
          await o.request('GET', '/v1/owner/backups'),
        );
        return WorkspaceBackupChange(
          operationId: id,
          action: WorkspaceBackupAction.restore,
          expectedVersion: status.version,
          selection: preview.archive,
          previewToken: preview.token,
        );
      }

      final interrupted = await inspect('interrupted_restore');
      final baseline = await database.length();
      expect(await journal.exists(), isFalse);
      var settled = false;
      final request = connection!
          .request(
            'POST',
            '/v1/owner/backups/changes',
            backupChangeToJson(interrupted),
          )
          .then<Object>(
            (r) {
              settled = true;
              return r;
            },
            onError: (Object e) {
              settled = true;
              return e;
            },
          );
      final end = DateTime.now().add(const Duration(seconds: 60));
      var killedDuringWrite = false;
      while (!settled && DateTime.now().isBefore(end)) {
        if (await journal.exists()) {
          try {
            final input = await journal.open();
            final header = await input.read(8);
            await input.close();
            if (header.any((b) => b != 0) &&
                await database.length() - baseline >= 4 * 1024 * 1024) {
              expect(Process.killPid(vmPid!, ProcessSignal.sigkill), isTrue);
              killedDuringWrite = true;
              break;
            }
          } on FileSystemException {
            /* A missed transaction is never accepted. */
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(
        killedDuringWrite,
        isTrue,
        reason:
            'Must interrupt actual uncommitted installation, not a preview or completed restore',
      );
      expect(
        await process!.exitCode.timeout(const Duration(seconds: 15)),
        isNot(0),
      );
      process = null;
      expect(await request, isA<RemoteFailure>());
      expect(await journal.exists(), isTrue);
      expect(errors.join(), isNot(contains(recovery)));
      connection!.close();
      await start();
      expect(connection!.serverId, originalServer);
      expect(await connection!.information(), isEmpty);
      expect(await connection!.request('GET', '/v1/owner/devices'), devices);
      final oldDevice = AgentConnection(
        AgentConnectionProfile(
          address: connection!.address,
          deviceToken: device['deviceToken'] as String,
          serverId: originalServer,
          certificate: await File(tls.ca).readAsString(),
        ),
      );
      try {
        expect(
          (await oldDevice.call('/session/lifecycle', {
            'chatLabel': '回退后仍有效',
          }))['status'],
          'ok',
        );
      } finally {
        oldDevice.close();
      }
      await expectLater(
        connection!.request(
          'GET',
          '/v1/owner/backups/operations/${interrupted.operationId}',
        ),
        throwsA(
          isA<RemoteFailure>().having(
            (e) => e.code,
            'code',
            'operation_not_found',
          ),
        ),
      );
      final retry = await inspect('retry_restore');
      final receipt = backupReceiptFromJson(
        await connection!.request(
          'POST',
          '/v1/owner/backups/changes',
          backupChangeToJson(retry),
        ),
      );
      expect(receipt.matches(retry), isTrue);
      expect(
        await connection!.request(
          'GET',
          '/v1/owner/backups/operations/${retry.operationId}',
        ),
        backupReceiptToJson(receipt),
      );
      final installed = await connection!.information();
      expect(
        installed.map(informationToJson),
        unorderedEquals(originals.map(informationToJson)),
      );
      expect(
        (await connection!.request('GET', '/v1/owner/devices'))['devices'],
        isEmpty,
      );
      expect(Process.killPid(vmPid!, ProcessSignal.sigterm), isTrue);
      expect(await process!.exitCode.timeout(const Duration(seconds: 15)), 0);
      process = null;
      connection!.close();
      await start();
      expect(
        (await connection!.information()).map(informationToJson),
        unorderedEquals(originals.map(informationToJson)),
      );
      expect(Process.killPid(vmPid!, ProcessSignal.sigterm), isTrue);
      expect(await process!.exitCode.timeout(const Duration(seconds: 15)), 0);
      process = null;
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
