import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'all directories are discoverable without a grant, including empty ones',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final a = await service.owner.createDirectory('A');
      final b = await service.owner.createDirectory('B');
      final first = await service.owner.createDirectory('同名', parentId: a.id);
      final second = await service.owner.createDirectory('同名', parentId: b.id);
      for (var n = 0; n < 250; n++) {
        await service.owner.createDirectory('空目录$n', parentId: a.id);
      }
      final item = await service.owner.createInformation('公开标题', '', [
        const FieldInput('字段', '', 'PRIVATE_CONTENT'),
      ]);
      await service.owner.organizeInformation(item.id, directoryId: first.id);
      final directories = service.agent.catalogDirectories();
      expect(directories.length, 254);
      expect(
        directories.singleWhere((d) => d['id'] == first.id)['path'],
        'A/同名',
      );
      expect(directories.singleWhere((d) => d['id'] == second.id)['pathIds'], [
        b.id,
        second.id,
      ]);
      expect(directories.singleWhere((d) => d['id'] == first.id)['order'], 0);
      expect(jsonEncode(directories), isNot(contains('PRIVATE_CONTENT')));
      expect(service.agent.catalog().single['directoryId'], first.id);
      await service.owner.updateDirectory(first.id, '已移动', parentId: b.id);
      expect(
        service.agent.catalogDirectories().singleWhere(
          (d) => d['id'] == first.id,
        )['path'],
        'B/已移动',
      );
    await service.owner.deleteDirectory(second.id, second.version);
      expect(service.agent.catalogDirectories().length, 253);
      await service.close();
      expect(
        () => service.agent.catalogDirectories(),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
