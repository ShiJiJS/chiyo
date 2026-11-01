// One disposable real Cocoa/Flutter App for the remaining native file panels
// and current-version backup path. No production profile or Keychain access.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/desktop_fonts.dart';
import 'package:info_desktop/main.dart';
import 'support/macos_keychain_backup.dart';

class _Keys implements DatabaseKeyStore {
  _Keys(this.byte);
  final int byte;
  @override
  Future<List<int>?> read() async => List.filled(32, byte);
  @override
  Future<void> create(List<int> key) async => throw StateError('Synthetic key');
}

void check(bool condition, String code) {
  if (!condition) throw StateError(code);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment,
      run = Platform.environment['MAC_FINITE_RUN'];
  final phase = env['MAC_FINITE_PHASE'];
  check(
    Platform.isMacOS && run != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(run),
    'Explicit synthetic run required',
  );
  check(
    {'source', 'restore', 'reopen'}.contains(phase),
    'Explicit phase required',
  );
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  final root = phase == 'source'
      ? await Directory(temp).createTemp('aim-finite-delivery-')
      : Directory(env['MAC_FINITE_ROOT']!);
  final path = await root.resolveSymbolicLinks();
  check(
    path == root.path && path.startsWith('$temp/aim-finite-delivery-'),
    'Owned container root required',
  );
  final marker = File('$path/.qa-owner');
  if (phase == 'source') {
    await marker.writeAsString(run!);
  } else {
    check(await marker.readAsString() == run, 'Synthetic owner mismatch');
  }
  stdout.writeln('FINITE_DELIVERY_ROOT=$path');
  await loadDesktopFonts();
  final source = phase == 'source';
  final facts = <String, Object?>{
    'phase': phase,
    'complete': false,
    'systemKeychainUsed': false,
  };
  final report = File('$path/$phase.json');
  Future<void> save() => report.writeAsString(jsonEncode(facts), flush: true);
  late EncryptedInformationRepository repo;
  late InformationService service;
  var flutterErrors = 0;
  FlutterError.onError = (details) {
    flutterErrors++;
    FlutterError.presentError(details);
  };
  final bootstrap = DesktopBootstrap(
    port: 0,
    platform: NativeDesktopPlatform(),
    openLibrary: () async {
      repo = await EncryptedInformationRepository.open(
        '$path/${source ? 'source' : 'target'}',
        _Keys(source ? 73 : 74),
      );
      service = InformationService(
        repository: repo,
        informationDeliveryFiles: NativeInformationDeliveryFiles(),
      );
      if (source) {
        final directory = await service.owner.createDirectory('合成验收目录');
        final tag = await service.owner.createTag('合成验收标签');
        await service.owner.createInformation(
          '合成普通资料',
          '本轮隔离验收',
          const [
            FieldInput('正文', '', 'SYNTHETIC-current-macos-content'),
            FieldInput('额外字段', '', 'SYNTHETIC-partial-scope'),
          ],
          directoryId: directory.id,
          tagIds: [tag.id],
        );
        await service.owner.saveCredentialRecord(
          'synthetic-credential',
          CredentialRecordInput(
            action: CredentialRecordAction.create,
            commandDigest: 'a' * 64,
            form: CredentialForm.file,
            name: '合成文件凭据',
            publicPurpose: '仅合成资料',
            privateNote: 'SYNTHETIC-private-note',
            suggestedBinding: 'SYNTHETIC_FILE',
            material: const [0, 255, 8, 10],
            fileName: 'synthetic-private.bin',
            updateClassification: true,
            directoryId: directory.id,
            tagIds: [tag.id],
          ),
        );
      }
      return DesktopLibrary(
        service: service,
        backups: repo.backups,
        fileOutputs: repo.fileOutputs,
        fileOpens: repo.fileOpens,
        close: () async {
          facts['flutterErrors'] = flutterErrors;
          facts['normalClose'] = true;
          await save();
          await repo.close();
        },
      );
    },
  );
  await bootstrap.start();
  check(bootstrap.state == DesktopStartupState.ready, 'Bootstrap failed');
  facts['port'] = bootstrap.boundPort;
  if (phase == 'restore') {
    check(
      await repo.backups.recipientEmpty(),
      'Initial restore target nonempty',
    );
    facts['initialTargetEmpty'] = true;
  }
  await save();
  runApp(DesktopLauncher(bootstrap: bootstrap, useWorkspace: true));
  stdout.writeln('FINITE_DELIVERY_READY=$phase');
  // A bounded observer only checks committed state; it never clicks, injects a
  // dialog response, restores directly or resubmits an operation.
  final deadline = DateTime.now().add(const Duration(minutes: 25));
  while (true) {
    check(DateTime.now().isBefore(deadline), 'Manual native phase timeout');
    final ready = source
        ? await repo.backups.latestExportOperation() != null
        : service.owner.information.isNotEmpty;
    if (ready) break;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (source) {
    check(
      service.owner.information.length >= 2,
      'Real panel attachment import missing',
    );
    check(
      repo.managedCredentials.single.tagIds.isNotEmpty,
      'Credential classification missing',
    );
    facts['actualUiExportObserved'] = true;
    facts['keySaved'] = await repo.backups.recoveryKeySaved();
  } else {
    // The current-version export and key become readable through the actual
    // Open panels; their paths in the environment do not grant sandbox access.
    final archive = env['MAC_FINITE_BACKUP']!, keyFile = env['MAC_FINITE_KEY']!;
    final privateArchive = File('$path/selected.aimbackup');
    final privateKey = File('$path/selected-key.txt');
    if (phase == 'restore') {
      await File(archive).copy(privateArchive.path);
      await File(keyFile).copy(privateKey.path);
    }
    final recovery = await repo.backups.readRecoveryKeyFrom(privateKey.path);
    final preview = await repo.backups.inspect(privateArchive.path, recovery);
    check(
      preview.formatVersion == 14 &&
          preview.credentialCount == 1 &&
          preview.attachmentBytes > 0,
      'Current complete archive missing categories',
    );
    final reference = await EncryptedInformationRepository.open(
      '$path/reference-$phase',
      _Keys(75),
    );
    final comparison = InformationService(repository: reference);
    try {
      await comparison.owner.restoreLibrary(
        () => reference.backups.restore(preview),
      );
      facts['comparison'] = await compareMacBackupRecipients(
        service,
        repo,
        comparison,
        reference,
        preview,
      );
      final c = repo.managedCredentials.single;
      check(
        c.privateNote == 'SYNTHETIC-private-note' &&
            c.directoryId != null &&
            c.tagIds.isNotEmpty,
        'Credential metadata/classification changed',
      );
      check(
        repo.credentialMaterials.single.bytes.join(',') == '0,255,8,10',
        'Credential bytes changed',
      );
    } finally {
      await comparison.close();
      await reference.close();
      await Directory('$path/reference-$phase').delete(recursive: true);
    }
    facts['currentRestoreAndReopen'] = true;
  }
  facts['complete'] = true;
  await save();
  stdout.writeln('FINITE_DELIVERY_PASSED=$phase');
}
