// Run through check-owner-legacy-export.py, only against the retained synthetic
// package23 export. Comparisons stay in memory; no body/key is written to logs.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import '../integration_test/support/macos_keychain_backup.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 123);
  @override
  Future<void> create(List<int> key) async => throw StateError('fixed QA key');
}

void check(bool condition, String reason) {
  if (!condition) throw StateError(reason);
}

Future<void> editLegacy(
  OwnerWorkspaceSource source,
  InformationService service,
) async {
  final item = service.owner.information.firstWhere(
    (i) => i.fields.any((f) => f.kind != FieldKind.file),
  );
  final field = item.fields.firstWhere((f) => f.kind != FieldKind.file);
  final detail = await source.readDetail(
    WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
  );
  final slot = detail.fieldIds.entries
      .singleWhere((e) => e.value == field.id)
      .key;
  final saved = await source.saveRecord(
    WorkspaceEdit(
      operationId: 'legacy-export-edit',
      expectedVersion: detail.version,
      record: detail.record,
      values: {...detail.values, slot: 'synthetic round09 correction'},
    ),
  );
  check(saved is WorkspaceSaved, 'Legacy edit did not save');
  final after = service.owner.information.singleWhere((i) => i.id == item.id);
  check(after.fields.length == item.fields.length, 'Legacy fields lost');
  for (final original in item.fields) {
    final current = after.fields.singleWhere((f) => f.id == original.id);
    check(
      current.kind == original.kind &&
          current.name == original.name &&
          current.description == original.description,
      'Legacy identity changed',
    );
    if (original.kind != FieldKind.file) {
      check(
        current.value ==
            (original.id == field.id
                ? 'synthetic round09 correction'
                : original.value),
        'Legacy value changed',
      );
    }
    check(
      current.attachment == original.attachment,
      'Legacy attachment replaced',
    );
  }
}

void main() {
  test('ordinary package23 export survives new owner source and restart', () async {
    final env = Platform.environment;
    final root = Directory(env['OWNER_LEGACY_ROOT']!);
    final phase = env['OWNER_LEGACY_PHASE']!;
    check(
      await File('${root.path}/fixture-marker').readAsString() ==
          'disposable-owner-legacy-v1',
      'Unowned fixture',
    );
    check({'restore', 'edit', 'reopen'}.contains(phase), 'Invalid phase');
    final path = '${root.path}/recipient';
    check(
      phase == 'restore' || await File('$path/library.db').exists(),
      'Missing existing recipient',
    );
    final repo = await EncryptedInformationRepository.open(path, _Keys());
    final service = InformationService(
      repository: repo,
      clock: () => DateTime.utc(2026, 10, 30, 12),
    );
    final reference = await EncryptedInformationRepository.open(
      '${root.path}/reference-$phase',
      _Keys(),
    );
    final referenceService = InformationService(
      repository: reference,
      clock: () => DateTime.utc(2026, 10, 30, 12),
    );
    OwnerWorkspaceSource? source, referenceSource;
    final report = <String, Object?>{
      'phase': phase,
      'pid': pid,
      'passed': false,
    };
    try {
      final key = await repo.backups.readRecoveryKeyFrom(
        env['OWNER_LEGACY_KEY']!,
      );
      final preview = await repo.backups.inspect(
        env['OWNER_LEGACY_BACKUP']!,
        key,
      );
      check(
        preview.formatVersion == 9 &&
            preview.informationCount == 2 &&
            preview.credentialCount == 5 &&
            preview.credentialVersionCount == 7 &&
            preview.attachmentCount == 3 &&
            preview.attachmentBytes == 3073,
        'Unexpected historical synthetic export',
      );
      if (phase == 'restore') {
        check(await repo.backups.recipientEmpty(), 'Nonempty target');
        await service.owner.restoreLibrary(() => repo.backups.restore(preview));
      }
      await referenceService.owner.restoreLibrary(() async {
        await reference.backups.restoreFrom(env['OWNER_LEGACY_BACKUP']!, key);
      });
      source = OwnerWorkspaceSource(
        owner: service.owner,
        refreshInterval: Duration.zero,
      );
      referenceSource = OwnerWorkspaceSource(
        owner: referenceService.owner,
        refreshInterval: Duration.zero,
      );
      if (phase == 'reopen') {
        await editLegacy(referenceSource, referenceService);
      }
      // Checks all content, credentials, histories and attachment bytes against
      // an independent authenticated restore; ignores only restoredAt timestamps.
      report['comparison'] = await compareMacBackupRecipients(
        service,
        repo,
        referenceService,
        reference,
        preview,
      );
      final raw = await AttachmentBackupContainer.openValidated(
        env['OWNER_LEGACY_BACKUP']!,
        key,
      );
      try {
        // Compare original authenticated rows directly, so two readers dropping
        // the same old field cannot pass the new workspace projection check.
        for (final item in service.owner.information) {
          final row = raw.tables['information_items']!.singleWhere(
            (r) => r['id'] == item.id,
          );
          check(
            item.name == row['name'] && item.description == row['description'],
            'Original information metadata differs',
          );
          final detail = await source.readDetail(
            WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
          );
          final rows = raw.tables['information_fields']!
              .where((r) => r['item_id'] == item.id)
              .toList();
          check(
            detail.fieldIds.length == rows.length &&
                item.fields.length == rows.length,
            'Original field count differs',
          );
          for (final row in rows) {
            final field = item.fields.singleWhere((f) => f.id == row['id']);
            final slot = detail.fieldIds.entries
                .singleWhere((e) => e.value == field.id)
                .key;
            check(
              field.name == row['name'] &&
                  field.description == row['description'] &&
                  field.kind.name == row['kind'],
              'Original field metadata differs',
            );
            if (field.kind != FieldKind.file) {
              check(
                detail.values[slot] == field.value,
                'Workspace field projection differs',
              );
              check(
                phase == 'reopen' || field.value == row['value'],
                'Original field value differs',
              );
            }
          }
        }
      } finally {
        raw.close();
      }
      report['actualRevisionCount'] = repo.informationRevisions.length;
      report['originalRowsAndWorkspaceFieldsChecked'] = true;
      if (phase == 'edit') {
        await editLegacy(source, service);
        report['legacyEditPreservesOtherFields'] = true;
      }
      if (phase == 'reopen') {
        final edited = service.owner.information.firstWhere(
          (i) => i.fields.any((f) => f.kind != FieldKind.file),
        );
        check(
          (await source.recordOperationReceipt(
                'legacy-export-edit',
              ))?.result.version ==
              edited.version,
          'Persistent edit receipt missing',
        );
        final recovery = await repo.backups.enable();
        await repo.backups.saveRecoveryKeyTo('${root.path}/roundtrip-key.txt');
        await service.owner.exportLibrary(
          () => repo.backups.exportTo('${root.path}/roundtrip.aimbackup'),
        );
        final target = await EncryptedInformationRepository.open(
          '${root.path}/roundtrip',
          _Keys(),
        );
        final targetService = InformationService(repository: target);
        try {
          final contents = await target.backups.inspect(
            '${root.path}/roundtrip.aimbackup',
            recovery,
          );
          await targetService.owner.restoreLibrary(
            () => target.backups.restore(contents),
          );
          report['newExportRoundtrip'] = await compareMacBackupRecipients(
            targetService,
            target,
            service,
            repo,
            contents,
          );
        } finally {
          await targetService.close();
          await target.close();
        }
      }
      report['passed'] = true;
    } finally {
      await source?.dispose();
      await referenceSource?.dispose();
      await service.close();
      await repo.close();
      await referenceService.close();
      await reference.close();
    }
    await File(
      '${root.path}/$phase-result.json',
    ).writeAsString(jsonEncode(report));
  });
}
