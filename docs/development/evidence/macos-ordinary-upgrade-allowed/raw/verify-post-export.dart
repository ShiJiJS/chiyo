// Independent validation of the installed app's synthetic pre-upgrade export.
// The original profile/Keychain is never opened. Keys and contents are not logged.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

class MemoryKeys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value == null ? null : List.of(value!);
  @override
  Future<void> create(List<int> key) async {
    if (value != null) throw StateError('Key replacement forbidden');
    value = List.of(key);
  }
}

void require(bool condition, String label) {
  if (!condition) throw StateError(label);
}

Future<void> main(List<String> args) async {
  require(Platform.isMacOS && args.length == 1, 'Mac private root required');
  final root = Directory(args.single);
  require(await root.resolveSymbolicLinks() == root.absolute.path &&
      root.path.endsWith('/local/private/mac-final-candidate-20261022'), 'Owned private root required');
  final target = Directory('${root.path}/validation-target');
  require(!await target.exists(), 'Fresh recipient required');
  final keyFile = File('${root.parent.path}/mac-upgrade-20261022/recovery-key/升级前 恢复密钥.txt');
  final backup = File('${root.path}/encrypted-backup/候选23升级后 完整备份.aimbackup');
  final before = sha256.convert(await backup.readAsBytes()).toString();
  final keys = MemoryKeys();
  EncryptedInformationRepository? repository;
  InformationService? service;
  try {
    repository = await EncryptedInformationRepository.open(target.path, keys);
    service = InformationService(repository: repository);
    final recovery = await repository.backups.readRecoveryKeyFrom(keyFile.path);
    final preview = await repository.backups.inspect(backup.path, recovery);
    final preBackup = File('${root.path}/encrypted-backup/候选23升级前 完整备份.aimbackup');
    final preDigest = sha256.convert(await preBackup.readAsBytes()).toString();
    final pre = await AttachmentBackupContainer.openValidated(preBackup.path, recovery);
    final post = await AttachmentBackupContainer.openValidated(backup.path, recovery);
    Object? canonical(Object? value) {
      if (value is Map) {
        final keys = value.keys.map((k) => k.toString()).toList()..sort();
        return {for (final k in keys) k: canonical(value[k])};
      }
      if (value is List) return [for (final v in value) canonical(v)];
      return value;
    }
    List<String> rows(List<Map<String,Object?>> values) =>
        values.map((r) => jsonEncode(canonical(r))).toList()..sort();
    final tableResults = <String, Object?>{};
    var allTablesMatch = true;
    try {
      require(pre.tables.keys.toSet().containsAll(post.tables.keys) &&
          post.tables.keys.toSet().containsAll(pre.tables.keys), 'Backup table sets differ');
      for (final name in pre.tables.keys) {
        final match = jsonEncode(rows(pre.tables[name]!)) == jsonEncode(rows(post.tables[name]!));
        tableResults[name] = {'before':pre.tables[name]!.length,
          'after':post.tables[name]!.length, 'allRowsExactlyMatch':match};
        allTablesMatch = allTablesMatch && match;
      }
      final beforeVersions = pre.versions.map((v) => jsonEncode(canonical(v.toPrivateJson()))).toList()..sort();
      final afterVersions = post.versions.map((v) => jsonEncode(canonical(v.toPrivateJson()))).toList()..sort();
      final versionsMatch = jsonEncode(beforeVersions) == jsonEncode(afterVersions);
      stdout.writeln(jsonEncode({'phase':'pre-post-authenticated-comparison',
        'tables':tableResults, 'allPortableRowsExactlyMatch':allTablesMatch,
        'allAttachmentVersionMetadataMatch':versionsMatch,
        'attachmentChunksAuthenticatedByBothReaders':true,
        'sourceProfileOrKeychainOpened':false, 'secretValuesReported':false}));
      require(allTablesMatch && versionsMatch, 'Pre/post portable data differ');
    } finally {pre.close(); post.close();}
    require(sha256.convert(await preBackup.readAsBytes()).toString() == preDigest,
        'Pre-upgrade backup changed');

    stdout.writeln(jsonEncode({'phase':'authenticated-preview',
      'informationCount':preview.informationCount,
      'currentAttachmentCount':preview.currentAttachmentCount,
      'attachmentCount':preview.attachmentCount,
      'attachmentBytes':preview.attachmentBytes,
      'fileDeliveryCount':preview.fileDeliveryCount}));
    require(preview.informationCount == 2 && preview.currentAttachmentCount == 2 &&
        preview.attachmentCount == 3 && preview.attachmentBytes > 0 &&
        preview.fileDeliveryCount == 6, 'Installed export counts differ');
    await service.owner.restoreLibrary(() => repository!.backups.restore(preview));
    require(service.owner.information.length == preview.informationCount &&
        repository.managedCredentials.length == preview.credentialCount &&
        repository.credentialMaterials.length == preview.credentialVersionCount &&
        repository.grantHistory.length == preview.grantHistoryCount &&
        repository.accessRecords.length == preview.accessRecordCount &&
        repository.credentialUseRequests.length == preview.credentialUseHistoryCount &&
        repository.credentialExecutions.length == preview.credentialExecutionCount &&
        repository.informationRevisions.length == preview.revisionCount &&
        repository.informationFileDeliveries.length == preview.fileDeliveryCount,
        'Restored relationships differ');
    require(repository.grantHistory.every((g) => !g.active) &&
        repository.informationFileDeliveries.every((d) =>
            d.lease == null && d.sessionBinding == null && !d.runtime && d.restoredAt != null),
        'Restored live authority found');
    var verifiedVersions = 0;
    for (final version in preview.attachments.where((v) => v.available)) {
      await repository.withInformationAttachment(version.reference, (actual, stream) async {
        final digest = await sha256.bind(stream).single;
        require(actual.byteLength == version.byteLength &&
            actual.sha256 == version.sha256 && digest.toString() == version.sha256,
            'Attachment bytes differ');
      });
      verifiedVersions++;
    }
    final report = <String,Object?>{
      'status':'ok', 'scope':'actual installed synthetic export; independent memory-key target; not native restore or Keychain upgrade',
      'cipherVersion':repository.cipherVersion, 'formatVersion':preview.formatVersion,
      'informationCount':preview.informationCount, 'credentialCount':preview.credentialCount,
      'credentialVersionCount':preview.credentialVersionCount,
      'grantHistoryCount':preview.grantHistoryCount, 'accessRecordCount':preview.accessRecordCount,
      'credentialUseHistoryCount':preview.credentialUseHistoryCount,
      'credentialExecutionCount':preview.credentialExecutionCount,
      'revisionCount':preview.revisionCount, 'fileDeliveryCount':preview.fileDeliveryCount,
      'verifiedAttachmentVersions':verifiedVersions, 'verifiedAttachmentBytes':preview.attachmentBytes,
      'liveAuthorityAbsent':true, 'originalProfileOpened':false, 'keychainAccessed':false,
    };
    await service.close(); service = null;
    await repository.close(); repository = null;
    repository = await EncryptedInformationRepository.open(target.path, keys);
    service = InformationService(repository: repository);
    require(service.owner.information.length == preview.informationCount &&
        repository.informationFileDeliveries.length == preview.fileDeliveryCount &&
        repository.grantHistory.every((g) => !g.active), 'Independent target reopen differs');
    require(sha256.convert(await backup.readAsBytes()).toString() == before, 'Backup changed');
    report.addAll({'targetReopened':true,'backupUnchanged':true});
    stdout.writeln(jsonEncode(report));
  } finally {
    await service?.close();
    await repository?.close();
    keys.value?.fillRange(0, keys.value!.length, 0);
    if (await target.exists()) await target.delete(recursive:true);
  }
}
