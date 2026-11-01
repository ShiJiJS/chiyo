// Explicit three-process probe. Run with OWNER_BACKUP_ROOT and phase
// seed/verify/reopen; never part of the default suite or a personal library.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/workspace/backup_controller.dart';
import 'package:info_desktop/workspace/owner_workspace_backup_files.dart';
import 'package:info_desktop/workspace/owner_workspace_backups.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _SyntheticKeys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 81);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('fixture preprovisions only its own key');
}

class _Picker extends BackupFilePicker {
  _Picker(this.root);
  final String root;
  String? next;
  int preparations = 0;
  @override
  Future<String?> recoveryKeyOutput() async => next;
  @override
  Future<String?> backupOutput() async => next;
  @override
  Future<String?> backupInput() async => next;
  @override
  Future<String?> recoveryKeyInput() async => next;
  @override
  Future<BackupStaging?> prepareStaging(String output) async {
    preparations++;
    return BackupStaging(
      (await Directory(root).createTemp('material-')).path,
      'synthetic',
    );
  }

  @override
  Future<void> releaseRecordedStaging(Map<String, Object?> directory) async {
    expect(Directory(directory['path'] as String).existsSync(), isFalse);
  }
}

void main() {
  const root = String.fromEnvironment('OWNER_BACKUP_ROOT');
  const phase = String.fromEnvironment('OWNER_BACKUP_PHASE');
  if (!root.startsWith('/private/tmp/owner-backup-process-') ||
      !{'seed', 'verify', 'reopen'}.contains(phase)) {
    throw StateError('Explicit isolated synthetic root and phase required');
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Owner backup process $phase', () async {
    final picker = _Picker(root);
    for (final role in ['source', 'target']) {
      final repo = await EncryptedInformationRepository.open(
        '$root/$role',
        _SyntheticKeys(),
      );
      final service = core.InformationService(repository: repo);
      final files = OwnerWorkspaceBackupFiles(
        owner: service.owner,
        picker: picker,
      );
      final source = OwnerWorkspaceBackups(
        owner: service.owner,
        backups: repo.backups,
        files: files,
        picker: picker,
      );
      void sql(String statement) {
        final db = sqlite3.open('$root/$role/library.db');
        try {
          db.execute('PRAGMA key = "x\'${'51' * 32}\'"');
          db.execute(statement);
        } finally {
          db.close();
        }
      }

      Future<WorkspaceBackupResource> pick(
        WorkspaceBackupPick kind,
        String path,
      ) async {
        picker.next = path;
        return (await files.pick(kind))!;
      }

      Future<WorkspaceBackupChange> command(
        String id,
        WorkspaceBackupAction action, {
        WorkspaceBackupResource? selected,
        String? token,
      }) async => WorkspaceBackupChange(
        operationId: id,
        action: action,
        expectedVersion: (await source.status()).version,
        selection: selected,
        previewToken: token,
      );
      try {
        if (phase == 'seed') {
          if (role == 'source') {
            await service.owner.createInformation('独立进程合成资料', '', [
              const core.FieldInput('正文', '', 'independent-process-content'),
            ]);
            await source.change(
              await command('enable', WorkspaceBackupAction.enableKey),
            );
            await source.change(
              await command(
                'key',
                WorkspaceBackupAction.saveKey,
                selected: await pick(
                  WorkspaceBackupPick.keyOutput,
                  '$root/recovery.txt',
                ),
              ),
            );
            sql(
              "CREATE TRIGGER reject_ack BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='ownerIntent' AND json_extract(NEW.payload,'\$.pending')=0 BEGIN SELECT RAISE(ABORT,'injected'); END",
            );
            final r = await source.change(
              await command(
                'export',
                WorkspaceBackupAction.export,
                selected: await pick(
                  WorkspaceBackupPick.archiveOutput,
                  '$root/archive.aimbackup',
                ),
              ),
            );
            expect(r.counts![WorkspaceBackupCategory.information], 1);
          } else {
            final preview = await source.inspect(
              await pick(
                WorkspaceBackupPick.archiveInput,
                '$root/archive.aimbackup',
              ),
              await pick(WorkspaceBackupPick.keyInput, '$root/recovery.txt'),
            );
            sql(
              "CREATE TRIGGER reject_ack BEFORE UPDATE ON backup_operations WHEN json_extract(NEW.payload,'\$.action')='ownerIntent' AND json_extract(NEW.payload,'\$.pending')=0 BEGIN SELECT RAISE(ABORT,'injected'); END",
            );
            final r = await source.change(
              await command(
                'restore',
                WorkspaceBackupAction.restore,
                selected: preview.archive,
                token: preview.token,
              ),
            );
            expect(r.counts![WorkspaceBackupCategory.information], 1);
          }
          sql('DROP TRIGGER reject_ack');
          expect(
            (await repo.backups.pendingOwnerOperations()).single.operationId,
            role == 'source' ? 'export' : 'restore',
          );
        } else {
          if (phase == 'verify' && role == 'source') {
            await File('$root/archive.aimbackup').delete();
            await File('$root/recovery.txt').delete();
          }
          final session = service.agent.openSession(
            'new session after process restart',
          );
          final controller = BackupController(source, const Stream.empty());
          try {
            await controller.load();
            if (phase == 'verify') {
              expect(controller.uncertain, isTrue);
              await controller.reconcile();
              expect(
                controller.result!.operationId,
                role == 'source' ? 'export' : 'restore',
              );
            }
            expect(controller.frozen, isFalse);
            expect((await source.status()).pending, isNull);
            expect(
              (await source.receipt(
                role == 'source' ? 'export' : 'restore',
              ))!.counts![WorkspaceBackupCategory.information],
              1,
            );
            service.agent.validateSession(session);
            expect(
              service.owner.information.single.fields.single.value,
              'independent-process-content',
            );
            expect(picker.preparations, 0);
          } finally {
            controller.dispose();
          }
        }
      } finally {
        source.dispose();
        await service.close();
        await repo.close();
      }
    }
  });
}
