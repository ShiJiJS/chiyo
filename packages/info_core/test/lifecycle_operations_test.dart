import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'memory lifecycle preserves original intent and rejects changed replay',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final item = await service.owner.createInformation('资料', '', [
        const FieldInput('字段', '', 'secret'),
      ]);
      final command = InformationLifecycleCommand(
        operationId: 'delete',
        itemId: item.id,
        action: InformationLifecycleAction.recycle,
        expectedVersion: 1,
      );
      final receipt = await service.owner.changeInformationLifecycle(command);
      expect(
        (await service.owner.changeInformationLifecycle(command)).toJson(),
        receipt.toJson(),
      );
      expect(service.owner.recycleEntries, hasLength(1));
      await expectLater(
        service.owner.changeInformationLifecycle(
          InformationLifecycleCommand(
            operationId: 'delete',
            itemId: item.id,
            action: InformationLifecycleAction.recycle,
            expectedVersion: 2,
          ),
        ),
        throwsA(isA<AccessFailure>()),
      );
      final restore = InformationLifecycleCommand(
        operationId: 'restore',
        itemId: item.id,
        action: InformationLifecycleAction.restoreRecycled,
        expectedVersion: receipt.version,
        entryId: receipt.entryId,
        expectedCatalogVersion:
            (await service.owner.informationClassificationSnapshot()).version,
      );
      await service.owner.changeInformationLifecycle(restore);
      expect(
        service.owner.information.single.fields.single.id,
        isNot(item.fields.single.id),
      );
      expect(
        service.owner.recycleFacts.where(
          (f) => f.kind == RecycleFactKind.restored,
        ),
        hasLength(1),
      );
    },
  );
  test(
    'strict persisted command and receipt cannot omit scope or introduce payload fields',
    () {
      final command = InformationLifecycleCommand(
        operationId: 'op',
        itemId: 'item',
        action: InformationLifecycleAction.recycle,
        expectedVersion: 1,
      );
      final receipt = InformationLifecycleReceipt(
        command: command,
        version: 2,
        entryId: 'entry',
      );
      expect(
        InformationLifecycleReceipt.fromJson(receipt.toJson()).toJson(),
        receipt.toJson(),
      );
      for (final invalid in [
        {...command.toJson(), 'body': 'unexpected'},
        {...command.toJson()}..remove('expectedCurrentVersion'),
        {...command.toJson(), 'action': 'purge'},
        {...command.toJson(), 'entryId': 'irrelevant'},
      ]) {
        expect(
          () => InformationLifecycleCommand.fromJson(invalid),
          throwsFormatException,
        );
      }
      expect(
        () => InformationLifecycleReceipt.fromJson({
          ...receipt.toJson(),
          'version': 3,
        }),
        throwsFormatException,
      );
      expect(
        () => InformationLifecycleReceipt.fromJson({
          ...receipt.toJson(),
          'entryId': null,
        }),
        throwsFormatException,
      );
      expect(
        () => InformationLifecycleCommand(
          operationId: 'op',
          itemId: 'item',
          action: InformationLifecycleAction.restoreRevision,
          expectedVersion: 2,
          revisionVersion: 1,
        ),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
