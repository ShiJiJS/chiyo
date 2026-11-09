@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/workspace/backup_controller.dart';
import 'package:info_desktop/workspace/remote_workspace_backups.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_storage/info_storage.dart';

class _Http extends HttpOverrides {
  bool dropConfirmation = false, offline = false;
  int exports = 0, lostReplies = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _Client(super.createHttpClient(context), this);
}

class _Client implements HttpClient {
  _Client(this.inner, this.observation);
  final HttpClient inner;
  final _Http observation;
  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (observation.offline) {
      throw const SocketException('Synthetic post-commit disconnect');
    }
    if (method == 'POST' && url.path == '/v1/owner/backups/exports') {
      observation.exports++;
    }
    return _Request(
      await inner.openUrl(method, url),
      observation,
      method == 'POST' && url.path == '/v1/owner/backups/outputs/confirm',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected HTTP operation');
}

class _Request implements HttpClientRequest {
  _Request(this.inner, this.observation, this.confirmation);
  final HttpClientRequest inner;
  final _Http observation;
  final bool confirmation;
  @override
  HttpHeaders get headers => inner.headers;
  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;
  @override
  void write(Object? value) => inner.write(value);
  @override
  void abort([Object? error, StackTrace? stack]) => inner.abort(error, stack);
  @override
  Future<HttpClientResponse> close() async {
    final response = await inner.close();
    if (confirmation &&
        observation.dropConfirmation &&
        response.statusCode == 200) {
      observation.dropConfirmation = false;
      observation.offline = true;
      observation.lostReplies++;
      await response.drain<void>();
      throw const SocketException(
        'Synthetic lost confirmation after NAS commit',
      );
    }
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected HTTP request operation');
}

// Only supply panel choices. Production Windows staging, ACLs, publisher,
// SQLCipher journal, original backup controller and existing NAS API all run.
class _Panels extends NativeBackupFilePicker {
  late String key, archive;
  @override
  Future<String?> recoveryKeyOutput() async => key;
  @override
  Future<String?> backupOutput() async => archive;
}

String digest(InformationItem item) =>
    sha256.convert(utf8.encode(jsonEncode(informationToJson(item)))).toString();

void main() {
  const profileDirectory = String.fromEnvironment(
    'CHIYO_NAS_PROFILE_DIRECTORY',
  );
  const privateDirectory = String.fromEnvironment('CHIYO_NAS_BACKUP_DIRECTORY');
  test(
    'existing NAS: Windows full export and independent empty-target restore preserve original data without live capabilities',
    () async {
      final observation = _Http();
      await HttpOverrides.runWithHttpOverrides(() async {
        final oldPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final parent = WindowsPrivateFiles.directory(
          Directory(privateDirectory).absolute,
        );
        final root = WindowsPrivateFiles.directory(
          await parent.createTemp('w114-backup-'),
        );
        final profile = (await PrivateConnectionProfileStore(
          profileDirectory,
        ).read())!;
        final client = await OwnerClient.connect(
          address: Uri.parse(profile.address),
          token: profile.token,
          expectedServerId: profile.serverId,
          trust: SecurityContext(withTrustedRoots: false)
            ..setTrustedCertificatesBytes(utf8.encode(profile.certificate)),
        );
        final panels = _Panels()
          ..key = '${root.path}/独立恢复材料.key'
          ..archive = '${root.path}/知予完整备份.aimbackup';
        RemoteWorkspaceBackups? source;
        OwnerClient? reopenedClient;
        BackupController? model;
        EncryptedInformationRepository? target;
        InformationService? restored;
        try {
          final original = {
            for (final item in await client.information())
              item.id: digest(item),
          };
          final trustBefore = jsonEncode(
            await client.request('GET', '/v1/owner/ssh-hosts'),
          );
          source = RemoteWorkspaceBackups(
            client,
            directory: '${root.path}/device',
            changed: () {},
            picker: panels,
          );
          model = BackupController(source, const Stream.empty());
          await model.load();
          expect(model.readFailure?.code, isNull);
          expect(
            model.value?.pending == null,
            true,
            reason: 'Do not consume another pending NAS operation',
          );
          if (!model.value!.keyCreated) {
            await model.write(WorkspaceBackupAction.enableKey);
            expect(model.failure?.code, isNull);
          }
          await model.pick(WorkspaceBackupPick.keyOutput, source.pick);
          await model.write(WorkspaceBackupAction.saveKey);
          expect(model.failure?.code, isNull);
          expect(model.value!.keySaved, true);
          final key = (await File(panels.key).readAsString()).trim();
          expect(key.startsWith('aim-recovery-v1:'), true);
          WindowsPrivateFiles.verify(panels.key);
          await model.pick(WorkspaceBackupPick.archiveOutput, source.pick);
          observation.dropConfirmation = true;
          await model.write(WorkspaceBackupAction.export);
          expect(model.failure?.code, 'unknown_outcome');
          expect(model.uncertain, true);
          expect(observation.lostReplies, 1);
          expect(observation.exports, 1);
          expect(await File(panels.archive).exists(), true);
          model.dispose();
          model = null;
          await source.dispose();
          source = null;
          client.close();
          observation.offline = false;
          reopenedClient = await OwnerClient.connect(
            address: Uri.parse(profile.address),
            token: profile.token,
            expectedServerId: profile.serverId,
            trust: SecurityContext(withTrustedRoots: false)
              ..setTrustedCertificatesBytes(utf8.encode(profile.certificate)),
          );
          source = RemoteWorkspaceBackups(
            reopenedClient,
            directory: '${root.path}/device',
            changed: () {},
            picker: panels,
          );
          model = BackupController(source, const Stream.empty());
          await model.load();
          expect(model.uncertain, true);
          await model.reconcile();
          expect(model.failure?.code, isNull);
          expect(
            observation.exports,
            1,
            reason: 'Reopen must query the original result, not export again',
          );
          final counts = model.result!.counts!;
          expect(counts[WorkspaceBackupCategory.information], original.length);
          expect(
            counts[WorkspaceBackupCategory.credentials],
            greaterThanOrEqualTo(15),
          );
          expect(counts[WorkspaceBackupCategory.files], greaterThan(0));
          final archive = File(panels.archive);
          WindowsPrivateFiles.verify(archive.path);
          final archiveHash = (await sha256.bind(archive.openRead()).first)
              .toString();
          final length = await archive.length();
          expect(length, greaterThanOrEqualTo(4096));
          expect(
            latin1
                .decode(await archive.openRead(0, 16).expand((b) => b).toList())
                .startsWith('SQLite format 3'),
            false,
          );
          model.dispose();
          model = null;
          await source.dispose();
          source = null;
          reopenedClient.close();
          reopenedClient = null;

          // A new device key and a separate empty target only. Never call the
          // NAS restore endpoint or open any old Windows library.
          final targetPath = '${root.path}/empty-target';
          target = await EncryptedInformationRepository.open(
            targetPath,
            WindowsDatabaseKeyStore(
              '${root.path}/target-key.dpapi',
              privateFile: true,
            ),
          );
          final wrong =
              'aim-recovery-v1:${base64UrlEncode(List.filled(32, 23))}';
          await expectLater(
            target.backups.inspect(archive.path, wrong),
            throwsA(
              isA<StorageFailure>().having(
                (e) => e.code,
                'code',
                'invalid_backup',
              ),
            ),
          );
          expect(target.managedCredentials.isEmpty, true);
          final snapshot = await target.backups.inspect(archive.path, key);
          expect(snapshot.informationCount, original.length);
          expect(
            snapshot.credentialCount,
            counts[WorkspaceBackupCategory.credentials],
          );
          expect(
            snapshot.attachmentCount,
            counts[WorkspaceBackupCategory.files],
          );
          await target.backups.restore(snapshot);
          restored = InformationService(repository: target);
          expect(restored.owner.information.length, original.length);
          expect(
            restored.owner.information.every(
              (item) => original[item.id] == digest(item),
            ),
            true,
            reason:
                'Information identities, versions, relations and fields must match',
          );
          for (final version in snapshot.attachments.where(
            (v) => v.available,
          )) {
            final observed = await target.withInformationAttachment(
              version.reference,
              (metadata, chunks) async =>
                  (await sha256.bind(chunks).first).toString(),
            );
            expect(
              observed == version.sha256,
              true,
              reason: 'Restored retained attachment bytes must match',
            );
          }
          final history = await restored.owner.history();
          expect(
            history.grants.every((g) => !g.active && g.restoredAt != null),
            true,
          );
          expect(restored.owner.requests.isEmpty, true);
          expect(
            target.credentialExecutions.every(
              (e) => e.materialLease == null && e.restoredAt != null,
            ),
            true,
          );
          await expectLater(
            target.backups.restoreFrom(archive.path, key),
            throwsA(
              isA<StorageFailure>().having(
                (e) => e.code,
                'code',
                'recipient_not_empty',
              ),
            ),
          );
          await restored.close();
          restored = null;
          await target.close();
          target = null;
          target = await EncryptedInformationRepository.open(
            targetPath,
            WindowsDatabaseKeyStore(
              '${root.path}/target-key.dpapi',
              privateFile: true,
            ),
          );
          restored = InformationService(repository: target);
          expect(
            restored.owner.information.every(
              (item) => original[item.id] == digest(item),
            ),
            true,
          );

          // Reopen the original App adapter/journal; saved files and receipts
          // remain, with no pending operation or staging cleanup.
          reopenedClient = await OwnerClient.connect(
            address: Uri.parse(profile.address),
            token: profile.token,
            expectedServerId: profile.serverId,
            trust: SecurityContext(withTrustedRoots: false)
              ..setTrustedCertificatesBytes(utf8.encode(profile.certificate)),
          );
          source = RemoteWorkspaceBackups(
            reopenedClient,
            directory: '${root.path}/device',
            changed: () {},
            picker: panels,
          );
          final status = await source.status();
          expect(status.pending == null && status.cleanupCount == 0, true);
          expect(
            (await sha256.bind(archive.openRead()).first).toString(),
            archiveHash,
          );
          final current = await reopenedClient.information();
          expect(
            current.length == original.length &&
                current.every((item) => original[item.id] == digest(item)),
            true,
          );
          expect(
            jsonEncode(
                  await reopenedClient.request('GET', '/v1/owner/ssh-hosts'),
                ) ==
                trustBefore,
            true,
          );
          await File('${root.path}/result.json').writeAsString(
            jsonEncode({
              'status': 'passed',
              'archiveSha256': archiveHash,
              'archiveBytes': length,
              'counts': counts.json,
              'independentEmptyTargetRestored': true,
              'originalNasRecordsUnchanged': true,
              'liveCapabilitiesRestored': false,
              'lostConfirmationRecoveredAfterReopen': true,
              'exportRequests': observation.exports,
            }),
            flush: true,
          );
        } finally {
          observation.offline = false;
          model?.dispose();
          await source?.dispose();
          client.close();
          reopenedClient?.close();
          await restored?.close();
          await target?.close();
          debugDefaultTargetPlatformOverride = oldPlatform;
          // Retain the one explicit encrypted backup, independent key and target
          // under the private workspace for inspection, never in test output/Git.
        }
      }, observation);
    },
    skip: profileDirectory.isEmpty || privateDirectory.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
