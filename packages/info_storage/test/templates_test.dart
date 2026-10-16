import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

void main() {
  test(
    'encrypted v2 library upgrades and reopens extensible templates and controlled notes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'template-storage-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final keys = _Keys()..key = List.filled(32, 34);
      final fixture = sqlite3.open('${directory.path}/library.db');
      fixture.execute('PRAGMA key = "x\'${'22' * 32}\'"');
      fixture.execute(
        'CREATE TABLE information_items(id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL,version INTEGER NOT NULL)',
      );
      fixture.execute(
        'CREATE TABLE information_fields(id TEXT PRIMARY KEY,item_id TEXT NOT NULL,name TEXT NOT NULL,description TEXT NOT NULL,value TEXT NOT NULL,version INTEGER NOT NULL)',
      );
      fixture.execute(
        'CREATE TABLE settings(name TEXT PRIMARY KEY,value INTEGER NOT NULL)',
      );
      fixture.execute("INSERT INTO information_items VALUES('old','Old','',1)");
      fixture.execute(
        "INSERT INTO information_fields VALUES('old-field','old','Address','','old.invalid',1)",
      );
      fixture.execute('PRAGMA user_version = 2');
      fixture.close();
      var store = await EncryptedInformationRepository.open(
        directory.path,
        keys,
      );
      var service = InformationService(repository: store);
      expect(
        service.owner.information.single.fields.single.kind,
        FieldKind.structured,
      );
      var template = await service.owner.createTemplate(
        'ENCRYPTED-TEMPLATE-MARKER-9182',
        '',
        [const TemplateFieldInput('Notes', '', kind: FieldKind.textNote)],
      );
      template = await service.owner
          .updateTemplate(template.id, 1, template.name, 'Updated', [
            TemplateFieldInput(
              'Notes',
              '',
              kind: FieldKind.textNote,
              definitionId: template.fields.single.id,
            ),
            const TemplateFieldInput('Address', 'Host'),
          ]);
      final noteId = template.fields.first.id;
      await service.owner
          .createInformationFromTemplate(template.id, 2, 'New', '', {
            noteId: 'ENCRYPTED-NOTE-MARKER-9182',
            template.fields.last.id: 'new.invalid',
          });
      service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(directory.path, keys);
      service = InformationService(repository: store);
      expect(service.owner.templates.single.version, 2);
      expect(service.owner.templates.single.fields.first.id, noteId);
      expect(
        service.owner.templates.single.fields.first.kind,
        FieldKind.textNote,
      );
      expect(
        service.owner.information.last.fields.first.kind,
        FieldKind.textNote,
      );
      expect(
        service.owner.information.last.fields.first.value,
        'ENCRYPTED-NOTE-MARKER-9182',
      );
      service.close();
      await store.close();
      for (final file in directory.listSync().whereType<File>()) {
        final bytes = String.fromCharCodes(file.readAsBytesSync());
        expect(bytes, isNot(contains('ENCRYPTED-TEMPLATE-MARKER-9182')));
        expect(bytes, isNot(contains('ENCRYPTED-NOTE-MARKER-9182')));
      }
    },
  );
}
