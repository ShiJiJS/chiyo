import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'backup_setup.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  test(
    'a missing file reference rejects atomically while a file template uses backup8',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'attachment-legacy-db-',
      );
      final keys = _Keys();
      var repository = await EncryptedInformationRepository.open(
        root.path,
        keys,
      );
      addTearDown(() async {
        await repository.close();
        await root.delete(recursive: true);
      });
      final item = InformationItem('career', '求职资料', '', 1, [
        const InformationField('name', '姓名', '', '原内容', 1),
      ]);
      await repository.save(item);
      await expectLater(
        repository.save(
          InformationItem('career', '不应部分保存', '', 2, [
            ...item.fields,
            InformationField.file(
              'resume',
              '简历',
              '',
              InformationAttachmentRef('a', 1),
              1,
            ),
          ]),
        ),
        throwsA(isA<StorageFailure>()),
      );
      await repository.saveTemplate(
        InformationTemplate('file-template', '文件模板', '', 1, [
          const TemplateFieldDefinition('resume-def', '简历', '', FieldKind.file),
        ]),
      );
      expect(repository.items.single.name, '求职资料');
      expect(repository.items.single.version, 1);
      expect(repository.templates.single.fields.single.kind, FieldKind.file);
      final key = await enableTestBackups(repository.backups);
      final path = '${root.path}/file-template.aimbackup';
      await repository.backups.exportTo(path);
      expect((await repository.backups.inspect(path, key)).formatVersion, 8);
      await repository.close();
      repository = await EncryptedInformationRepository.open(root.path, keys);
      expect(repository.items.single.fields.single.value, '原内容');
      expect(repository.items.single.version, 1);
      expect(repository.templates.single.fields.single.kind, FieldKind.file);
    },
  );

  test(
    'authenticated format7 file-kind strings are rejected before inspection or restore, not downgraded',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'attachment-legacy-backup-',
      );
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
      );
      final target = await EncryptedInformationRepository.open(
        '${root.path}/target',
        _Keys(),
      );
      addTearDown(() async {
        await source.close();
        await target.close();
        await root.delete(recursive: true);
      });
      await source.save(
        InformationItem('career', '求职资料', '', 1, [
          const InformationField('resume', '说明', '', '原始文本', 1),
        ]),
      );
      await source.saveTemplate(
        InformationTemplate('template', '说明模板', '', 1, [
          const TemplateFieldDefinition(
            'definition',
            '说明',
            '',
            FieldKind.structured,
          ),
        ]),
      );
      final key = await enableTestBackups(source.backups);
      final path = '${root.path}/valid.aimbackup';
      await source.backups.exportTo(path);
      expect((await target.backups.inspect(path, key)).informationCount, 1);
      final hex = base64Url
          .decode(key.substring('aim-recovery-v1:'.length))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      for (final branch in ['field', 'template']) {
        final copy = '${root.path}/$branch.aimbackup';
        await File(path).copy(copy);
        final db = sqlite3.open(copy);
        try {
          db.execute('PRAGMA key = "x\'$hex\'"');
          final payload =
              jsonDecode(
                    db
                            .select('SELECT payload FROM backup_snapshot')
                            .single['payload']
                        as String,
                  )
                  as Map<String, dynamic>;
          expect(payload['version'], 7);
          final tables = payload['tables'] as Map<String, dynamic>;
          if (branch == 'field') {
            (tables['information_fields'] as List).single['kind'] = 'file';
          } else {
            final template = (tables['field_templates'] as List).single as Map;
            final fields =
                jsonDecode(template['fields_json'] as String) as List;
            fields.single['kind'] = 'file';
            template['fields_json'] = jsonEncode(fields);
          }
          db.execute('UPDATE backup_snapshot SET payload=?', [
            jsonEncode(payload),
          ]);
        } finally {
          db.close();
        }
        await expectLater(
          target.backups.inspect(copy, key),
          throwsA(isA<StorageFailure>()),
        );
        await expectLater(
          target.backups.restoreFrom(copy, key),
          throwsA(isA<StorageFailure>()),
        );
        expect(target.items, isEmpty);
        expect(target.templates, isEmpty);
      }
    },
  );
}
