import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'memory repository observes legacy mutations and preserves original receipt',
    () async {
      final repo = MemoryInformationRepository();
      final service = InformationService(repository: repo);
      addTearDown(service.close);
      final initial = await service.owner.informationClassificationSnapshot();
      await service.owner.createTag('旧入口标签');
      final current = await service.owner.informationClassificationSnapshot();
      expect(current.version, greaterThan(initial.version));
      final command = InformationClassificationCommand(
        operationId: 'create',
        expectedVersion: current.version,
        kind: InformationClassificationKind.directory,
        action: InformationClassificationAction.create,
        name: '目录',
      );
      final receipt = await service.owner.changeInformationClassification(
        command,
      );
      expect(receipt.version, greaterThan(current.version));
      await service.owner.deleteDirectory(
        receipt.targetId,
        receipt.directory!.version,
      );
      expect(
        (await service.owner.changeInformationClassification(command)).toJson(),
        receipt.toJson(),
      );
      expect(repo.directories, isEmpty);
      expect(
        (await service.owner.informationClassificationSnapshot()).version,
        greaterThan(receipt.version),
      );
    },
  );

  test('receipt decoding rejects mismatched results and extra content', () {
    final receipt = InformationClassificationReceipt(
      operationId: 'op',
      commandDigest: 'a' * 64,
      expectedVersion: 1,
      version: 2,
      kind: InformationClassificationKind.directory,
      action: InformationClassificationAction.create,
      targetId: 'directory',
      directory: const InformationDirectory('directory', '目录', null, 1),
    );
    expect(
      InformationClassificationReceipt.fromJson(receipt.toJson()).toJson(),
      receipt.toJson(),
    );
    for (final modified in [
      {...receipt.toJson(), 'body': 'unexpected'},
      {...receipt.toJson(), 'targetId': 'other'},
      {...receipt.toJson(), 'action': 'delete'},
      {
        ...receipt.toJson(),
        'directory': ['directory', '目录'],
      },
      {...receipt.toJson(), 'version': 1},
    ]) {
      expect(
        () => InformationClassificationReceipt.fromJson(modified),
        throwsFormatException,
      );
    }
  });
}
