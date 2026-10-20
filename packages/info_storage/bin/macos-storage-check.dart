import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

/// SDK-free payload smoke test. Uses a fresh synthetic database and memory key,
/// never the application's profile or Keychain. No key/body reaches stdout.
Future<void> main() async {
  if (!Platform.isMacOS) throw UnsupportedError('Mac diagnostic only');
  final root = await Directory.systemTemp.createTemp('aim-mac-package-check-');
  final keys = _Keys();
  EncryptedInformationRepository? repository;
  InformationService? service;
  try {
    repository = await EncryptedInformationRepository.open(
      '${root.path}/source',
      keys,
    );
    service = InformationService(repository: repository);
    const marker = 'SYNTHETIC-PACKAGED-MAC-CONTENT-ONLY';
    final item = await service.owner.createInformation('Synthetic', '', [
      const FieldInput('Text', '', marker),
    ]);
    final field = FieldRef(item.id, item.fields.single.id);
    final session = service.agent.openSession('synthetic package check');
    final request = service.agent.request(session, 'synthetic only', [field]);
    service.owner.approve(request.id, [field]);
    final token = service.agent.claim(session, request.id).token;
    final cipher = repository.cipherVersion;
    await service.close();
    service = null;
    await repository.close();
    repository = null;
    repository = await EncryptedInformationRepository.open(
      '${root.path}/source',
      keys,
    );
    service = InformationService(repository: repository);
    if (service.owner.information.single.fields.single.value != marker) {
      throw StateError('Reopen mismatch');
    }
    var refused = false;
    try {
      await service.agent.read(token, field);
    } on AccessFailure {
      refused = true;
    }
    if (!refused) throw StateError('Old authority revived');
    final recovery = await repository.backups.enable();
    await repository.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
    await service.owner.exportLibrary(
      () => repository!.backups.exportTo('${root.path}/backup.aimbackup'),
    );
    await service.close();
    service = null;
    await repository.close();
    repository = null;
    final oldKey = List.of(keys.value!);
    keys.value!.fillRange(0, keys.value!.length, 0);
    keys.value = null;
    final targetKeys = _Keys();
    repository = await EncryptedInformationRepository.open(
      '${root.path}/target',
      targetKeys,
    );
    service = InformationService(repository: repository);
    await service.owner.restoreLibrary(
      () => repository!.backups.restoreFrom(
        '${root.path}/backup.aimbackup',
        recovery,
      ),
    );
    if (service.owner.information.single.fields.single.value != marker ||
        repository.grantHistory.any((g) => g.active) ||
        oldKey.join(',') == targetKeys.value!.join(',')) {
      throw StateError('Recovery mismatch');
    }
    oldKey.fillRange(0, oldKey.length, 0);
    stdout.writeln(
      jsonEncode({
        'status': 'ok',
        'cipherVersion': cipher,
        'reopen': true,
        'independentRecovery': true,
        'oldAuthorityRefused': true,
        'scope': 'synthetic memory keys; not Keychain or desktop acceptance',
      }),
    );
  } finally {
    await service?.close();
    await repository?.close();
    final actual = await root.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (actual != root.absolute.path ||
        !actual.startsWith('$temp/aim-mac-package-check-')) {
      throw StateError('Refusing cleanup outside owned diagnostic directory');
    }
    await root.delete(recursive: true);
  }
}
