import 'package:info_workspace/backup_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';

void main() {
  final counts = WorkspaceBackupCounts({
    for (final c in WorkspaceBackupCategory.values) c: 2,
  });
  final archive = const WorkspaceBackupResource(
    id: 'archive',
    name: 'synthetic.aimbackup',
    kind: WorkspaceBackupPick.archiveInput,
  );
  final key = const WorkspaceBackupResource(
    id: 'key',
    name: 'recovery.txt',
    kind: WorkspaceBackupPick.keyInput,
  );
  final change = WorkspaceBackupChange(
    operationId: 'restore',
    action: WorkspaceBackupAction.restore,
    expectedVersion: 1,
    selection: archive,
    previewToken: 'preview',
  );
  final preview = WorkspaceBackupPreview(
    token: 'preview',
    archive: archive,
    key: key,
    counts: counts,
    createdAt: DateTime.utc(2026, 11, 9),
    formatLabel: '加密备份 · 格式 21',
  );
  final receipt = WorkspaceBackupReceipt(
    operationId: 'restore',
    commandDigest: change.digest,
    action: change.action,
    expectedVersion: 1,
    version: 2,
    resource: archive,
    counts: counts,
  );
  test(
    'backup metadata keeps exact resources, counts, intent and acknowledgement',
    () {
      final decodedChange = backupChangeFromJson(backupChangeToJson(change));
      expect(decodedChange.digest, change.digest);
      expect(
        backupReceiptFromJson(backupReceiptToJson(receipt)).matches(change),
        isTrue,
      );
      final p = backupPreviewFromJson(backupPreviewToJson(preview));
      expect(p.archive.same(archive), isTrue);
      expect(p.key.same(key), isTrue);
      expect(p.counts.same(counts), isTrue);
      final status = WorkspaceBackupStatus(
        version: 1,
        keyCreated: true,
        keySaved: true,
        recipientEmpty: true,
        blockers: [],
        cleanupCount: 1,
        pending: WorkspaceBackupPending(change, restoreCounts: counts),
      );
      final s = backupStatusFromJson(backupStatusToJson(status));
      expect(s.pending!.command.digest, change.digest);
      expect(s.pending!.restoreCounts!.same(counts), isTrue);
    },
  );
  test(
    'backup wire rejects paths, raw keys, unknown fields, incomplete counts and mismatched action resources',
    () {
      for (final malformed in [
        {...backupChangeToJson(change), 'recoveryKey': 'SYNTHETIC_KEY'},
        {...backupChangeToJson(change), 'wireVersion': 2},
        {...backupChangeToJson(change), 'previewToken': null},
        {
          ...backupChangeToJson(change),
          'selection': {...archive.json, 'name': '../other'},
        },
        {...backupChangeToJson(change), 'selection': key.json},
        {...backupChangeToJson(change), 'operationId': 'one/two'},
      ]) {
        expect(() => backupChangeFromJson(malformed), throwsFormatException);
      }
      for (final malformed in [
        {...backupReceiptToJson(receipt), 'counts': <String, int>{}},
        {...backupReceiptToJson(receipt), 'version': 1},
        {
          ...backupReceiptToJson(receipt),
          'counts': {...counts.json, 'files': -1},
        },
        {
          ...backupReceiptToJson(receipt),
          'counts': {...counts.json, 'rawPassword': 1},
        },
        {...backupReceiptToJson(receipt), 'resource': key.json},
        {...backupReceiptToJson(receipt), 'sourcePath': '/private/synthetic'},
      ]) {
        expect(() => backupReceiptFromJson(malformed), throwsFormatException);
      }
    },
  );
}
