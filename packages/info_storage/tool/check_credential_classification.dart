import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

// Public synthetic key, never the OS key store or an owner's library.
class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 73);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Fixture key exists');
}

Future<void> main(List<String> args) async {
  if (args.length != 2 ||
      !{'seed', 'read', 'restore', 'restored-read'}.contains(args[1]))
    throw StateError('Explicit phase required');
  final root = await Directory(args[0]).resolveSymbolicLinks();
  if (root != Directory(args[0]).absolute.path ||
      !root.startsWith(
        '${await Directory.systemTemp.resolveSymbolicLinks()}/',
      ) ||
      !root.split('/').last.startsWith('credential-classification-process-') ||
      await File('$root/fixture-marker').readAsString() !=
          'synthetic-classification-v1')
    throw StateError('Owned synthetic root required');
  final phase = args[1], checks = <String>[];
  void check(String name, bool pass) {
    if (!pass) throw StateError(name);
    checks.add(name);
  }

  const secret = 'SYNTHETIC-independent-string';
  const privateNote = 'SYNTHETIC-independent-owner-note';
  final restored = phase == 'restore' || phase == 'restored-read';
  final path = '$root/${restored ? 'target' : 'source'}';
  final repo = await EncryptedInformationRepository.open(path, _Keys());
  final service = InformationService(repository: repo);
  try {
    if (phase == 'seed') {
      final directory = await service.owner.createDirectory('合成独立凭据目录');
      final tag = await service.owner.createTag('合成独立凭据标签');
      for (final form in CredentialForm.values) {
        await service.owner.saveCredentialRecord(
          'create-${form.name}',
          CredentialRecordInput(
            action: CredentialRecordAction.create,
            commandDigest: 'a' * 64,
            name: '合成${form.name}凭据',
            publicPurpose: '合成用途',
            privateNote: privateNote,
            suggestedBinding: 'SYNTHETIC_TOKEN',
            form: form,
            fileName: form == CredentialForm.file
                ? 'synthetic-private.bin'
                : null,
            material: form == CredentialForm.file
                ? [0, 255, 3, 8]
                : utf8.encode(secret),
            discoverable: true,
            updateClassification: true,
            directoryId: directory.id,
            tagIds: [tag.id],
          ),
        );
      }
      await repo.backups.enable();
      await repo.backups.saveRecoveryKeyTo('$root/synthetic-recovery.txt');
      await repo.backups.exportTo('$root/synthetic.aimbackup');
      final key = (await File(
        '$root/synthetic-recovery.txt',
      ).readAsString()).trim();
      check(
        'source encrypted backup is format14',
        (await repo.backups.inspect(
              '$root/synthetic.aimbackup',
              key,
            )).formatVersion ==
            14,
      );
    }
    if (phase == 'restore') {
      final key = (await File(
        '$root/synthetic-recovery.txt',
      ).readAsString()).trim();
      await repo.backups.restore(
        await repo.backups.inspect('$root/synthetic.aimbackup', key),
      );
      check(
        'restored local operations do not import source receipts',
        await service.owner.credentialRecordReceipt('create-string') == null,
      );
    }
    check(
      'both credential forms present',
      service.owner.credentials.length == 2 &&
          service.owner.credentials.map((c) => c.form).toSet().length == 2,
    );
    for (final c in service.owner.credentials) {
      check(
        '${c.form.name} classification identities',
        c.directoryId == service.owner.directories.single.id &&
            c.tagIds.single == service.owner.tags.single.id,
      );
      check(
        '${c.form.name} owner metadata and versions',
        c.privateNote == privateNote &&
            c.revision == 1 &&
            c.version == 1 &&
            c.useGeneration == 1,
      );
      final bytes = repo.credentialMaterials
          .singleWhere((m) => m.credentialId == c.id)
          .bytes;
      check(
        '${c.form.name} exact material',
        jsonEncode(bytes) ==
            jsonEncode(
              c.form == CredentialForm.file
                  ? [0, 255, 3, 8]
                  : utf8.encode(secret),
            ),
      );
    }
    final catalog = jsonEncode(service.agent.credentialCatalog().toJson());
    check(
      'public tag metadata without secret note or directory tree',
      catalog.contains('合成独立凭据标签') &&
          !catalog.contains(secret) &&
          !catalog.contains(privateNote) &&
          !catalog.contains('合成独立凭据目录'),
    );
    if (!restored)
      check(
        'exact original receipt survives source reopen',
        (await service.owner.credentialRecordReceipt(
              'create-string',
            ))?.materialVersion ==
            1,
      );
  } finally {
    await service.close();
    await repo.close();
  }
  await File('$root/$phase-result.json').writeAsString(
    jsonEncode({'phase': phase, 'pid': pid, 'passed': true, 'checks': checks}),
  );
  stdout.writeln(
    jsonEncode({
      'phase': phase,
      'pid': pid,
      'passed': true,
      'checks': checks.length,
    }),
  );
}
