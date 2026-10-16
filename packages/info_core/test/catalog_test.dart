import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'catalog searches only saved public metadata and pages matching items',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final directory = await service.owner.createDirectory(
        'PRIVATE_DIRECTORY_MARKER',
      );
      final tag = await service.owner.createTag('PRIVATE_TAG_MARKER');
      final first = await service.owner.createInformation('One', 'Public', [
        const FieldInput('Host', 'Address', 'PRIVATE_VALUE_MARKER'),
      ]);
      await service.owner.organizeInformation(
        first.id,
        directoryId: directory.id,
        tagIds: [tag.id],
      );
      await service.owner.createInformation('Two', 'Public', [
        const FieldInput('Host', 'Address', 'second.invalid'),
      ]);
      await service.owner.updateCatalogMetadata(
        first.id,
        name: 'Reviewed name',
        description: 'Reviewed description',
        fieldDescriptions: {first.fields.single.id: 'Reviewed address'},
      );
      final page = service.agent.searchCatalog(
        query: 'reviewed address',
        directoryId: directory.id,
        tagId: tag.id,
        limit: 1,
      );
      expect(page.items.single['name'], 'Reviewed name');
      expect(page.total, 1);
      expect(service.agent.searchCatalog(limit: 1).nextOffset, 1);
      expect(
        service.agent.searchCatalog(offset: 1, limit: 1).items.single['name'],
        'Two',
      );
      expect(service.agent.searchCatalog(query: 'PRIVATE').total, 0);
      expect(
        service.agent.searchCatalog().items.toString(),
        isNot(contains('PRIVATE')),
      );
      expect(
        service.owner.information.first.fields.single.id,
        first.fields.single.id,
      );
      expect(
        service.owner.information.first.fields.single.value,
        'PRIVATE_VALUE_MARKER',
      );
      expect(
        () => service.agent.searchCatalog(limit: 101),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.searchCatalog(offset: -1),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.searchCatalog(query: 'a' * 201),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.owner.updateCatalogMetadata(
          first.id,
          name: 'Changed',
          description: '',
          fieldDescriptions: {'unknown': 'Oops'},
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        service.agent.searchCatalog().items.first['name'],
        'Reviewed name',
      );
    },
  );
  test(
    'directory selection stays fixed when another item is moved into it',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final project = await service.owner.createDirectory('Project');
      final servers = await service.owner.createDirectory(
        'Servers',
        parentId: project.id,
      );
      final tag = await service.owner.createTag('Work');
      final first = await service.owner.createInformation('First', 'Public', [
        const FieldInput('Host', 'Address', 'first.invalid'),
      ]);
      final second = await service.owner.createInformation('Second', 'Public', [
        const FieldInput('Host', 'Address', 'second.invalid'),
      ]);
      await service.owner.organizeInformation(
        first.id,
        directoryId: servers.id,
        tagIds: [tag.id],
      );
      final selected = service.owner.fieldsInDirectory(project.id);
      final session = service.agent.openSession('test');
      final request = service.agent.request(session, 'connect', selected);
      service.owner.approve(request.id, selected);
      final grant = service.agent.claim(session, request.id);
      await service.owner.organizeInformation(
        second.id,
        directoryId: servers.id,
        tagIds: [tag.id],
      );
      expect(service.owner.fieldsInDirectory(project.id), hasLength(2));
      expect(service.agent.read(grant.token, selected.single), 'first.invalid');
      expect(
        () => service.agent.read(
          grant.token,
          FieldRef(second.id, second.fields.single.id),
        ),
        throwsA(isA<AccessFailure>()),
      );
      final moved = service.owner.information.first;
      expect(moved.id, first.id);
      expect(moved.fields.single.id, first.fields.single.id);
      expect(moved.version, 2);
      expect(
        () => service.owner.updateDirectory(
          project.id,
          'Project',
          parentId: servers.id,
        ),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
