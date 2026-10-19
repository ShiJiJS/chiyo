import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> bytes) async => key = List.of(bytes);
}

Matcher fails([String? code]) => throwsA(
  isA<StorageFailure>().having(
    (e) => e.code,
    'code',
    code == null ? anything : equals(code),
  ),
);
InformationAttachmentVersion version(
  String id,
  Uint8List bytes, {
  int number = 1,
  bool purged = false,
}) => InformationAttachmentVersion(
  reference: InformationAttachmentRef(id, number),
  originalName: '虚构简历.pdf',
  mediaType: 'application/pdf',
  byteLength: bytes.length,
  sha256: sha256.convert(bytes).toString(),
  createdAt: DateTime.utc(2026, 10, 19),
  retiredAt: purged ? DateTime.utc(2026, 10, 20) : null,
  purgedAt: purged ? DateTime.utc(2026, 11, 20) : null,
);
AttachmentBackupSource source(String id, Uint8List bytes, {int number = 1}) =>
    AttachmentBackupSource(
      version(id, bytes, number: number),
      read: (offset, length) async =>
          Uint8List.sublistView(bytes, offset, offset + length),
    );

void main() {
  late Directory root;
  late String path, key;
  final data = Uint8List.fromList(
    List.generate(
      AttachmentBackupContainer.chunkBytes * 2 + 17,
      (i) => i % 251,
    ),
  );
  final marker = utf8.encode('SYNTHETIC-ATTACHMENT-BYTES-481027');
  data.setRange(100, 100 + marker.length, marker);
  final tables = <String, List<Map<String, Object?>>>{
    'synthetic_records': [
      {
        'id': 'career',
        'nested': {
          'name': '虚构姓名',
          'tags': ['sample'],
        },
      },
    ],
  };
  final createdAt = DateTime.utc(2026, 10, 19);
  Future<void> write(List<AttachmentBackupSource> files, {String? output}) =>
      AttachmentBackupContainer.write(
        path: output ?? path,
        recoveryKey: key,
        createdAt: createdAt,
        tables: tables,
        attachments: files,
      );
  sqlite.Database open(String file) {
    final db = sqlite.sqlite3.open(file);
    final hex = base64Url
        .decode(key.substring('aim-recovery-v1:'.length))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    db.execute('PRAGMA key = "x\'$hex\'"');
    return db;
  }

  Future<Uint8List> read(
    AttachmentBackupReader reader,
    InformationAttachmentRef reference,
  ) async {
    final result = BytesBuilder(copy: false);
    await for (final chunk in reader.readAttachment(reference)) {
      result.add(chunk);
    }
    return result.takeBytes();
  }

  void expectBytes(List<int> actual, List<int> expected) {
    expect(actual.length, expected.length);
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i])
        fail('First differing synthetic byte at $i');
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('attachment-backup8-');
    path = '${root.path}/files.aimbackup';
    key =
        'aim-recovery-v1:${base64Url.encode(List.generate(32, (i) => i + 1))}';
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'real encrypted multichunk/empty/purged bytes round trip with a bounded source',
    () async {
      final lengths = <int>[];
      final nonempty = version('resume', data);
      final empty = version('empty', Uint8List(0));
      final purged = version(
        'purged',
        Uint8List.fromList([1, 2, 3]),
        purged: true,
      );
      await write([
        AttachmentBackupSource(
          nonempty,
          read: (offset, n) async {
            lengths.add(n);
            return Uint8List.sublistView(data, offset, offset + n);
          },
        ),
        AttachmentBackupSource(empty),
        AttachmentBackupSource(purged),
      ]);
      expect(lengths, [
        AttachmentBackupContainer.chunkBytes,
        AttachmentBackupContainer.chunkBytes,
        17,
      ]);
      final reader = await AttachmentBackupContainer.openValidated(path, key);
      try {
        expect(reader.createdAt, createdAt);
        expect(reader.versions, hasLength(3));
        expectBytes(await read(reader, nonempty.reference), data);
        expect(await read(reader, empty.reference), isEmpty);
        await expectLater(
          read(reader, purged.reference),
          fails('attachment_missing'),
        );
        expect(
          () => reader.tables['synthetic_records']!.single['id'] = 'changed',
          throwsUnsupportedError,
        );
        expect(
          () =>
              ((reader.tables['synthetic_records']!.single['nested']
                          as Map)['tags']
                      as List)
                  .add('changed'),
          throwsUnsupportedError,
        );
      } finally {
        reader.close();
        reader.close();
      }
      final db = open(path);
      try {
        final document =
            jsonDecode(
                  db
                          .select('SELECT payload FROM backup_snapshot')
                          .single
                          .values
                          .single
                      as String,
                )
                as Map;
        expect(document['version'], 8);
        expect(document.containsKey('body'), isFalse);
        expect(
          db
              .select('SELECT count(*) FROM attachment_chunks')
              .single
              .values
              .single,
          3,
        );
        expect(db.select('PRAGMA journal_mode').single.values.single, 'delete');
      } finally {
        db.close();
      }
      final bytes = latin1.decode(await File(path).readAsBytes());
      expect(bytes, isNot(contains(latin1.decode(utf8.encode('虚构简历.pdf')))));
      expect(bytes, isNot(contains('synthetic_records')));
      expect(bytes, isNot(contains('SYNTHETIC-ATTACHMENT-BYTES-481027')));
      expect((await File(path).length()) % 4096, 0);
    },
  );

  test(
    'source errors after a written chunk never publish or keep a plaintext temporary file',
    () async {
      var calls = 0;
      await expectLater(
        write([
          AttachmentBackupSource(
            version('resume', data),
            read: (offset, n) async {
              calls++;
              if (offset != 0)
                throw const FileSystemException('private source path');
              return Uint8List.sublistView(data, offset, offset + n);
            },
          ),
        ]),
        fails('backup_export_failed'),
      );
      expect(calls, 2);
      expect(await File(path).exists(), isFalse);
      expect(root.listSync(), isEmpty);
    },
  );

  for (final kind in ['short', 'long', 'digest']) {
    test('$kind source integrity failure leaves no final backup', () async {
      final v = version('resume', Uint8List.fromList([1, 2, 3]));
      await expectLater(
        write([
          AttachmentBackupSource(
            v,
            read: (o, n) async => Uint8List(
              kind == 'short'
                  ? n - 1
                  : kind == 'long'
                  ? n + 1
                  : n,
            ),
          ),
        ]),
        fails('attachment_integrity_failed'),
      );
      expect(await File(path).exists(), isFalse);
    });
  }
  test(
    'duplicate identities and over-capacity manifests are rejected before any source IO',
    () async {
      var calls = 0;
      final v = version('duplicate', Uint8List.fromList([1]));
      final s = AttachmentBackupSource(
        v,
        read: (o, n) async {
          calls++;
          return Uint8List(n);
        },
      );
      await expectLater(write([s, s]), fails('invalid_backup'));
      final large = List.generate(
        11,
        (i) => AttachmentBackupSource(
          InformationAttachmentVersion(
            reference: InformationAttachmentRef('large$i', 1),
            originalName: 'large.bin',
            mediaType: 'application/octet-stream',
            byteLength: informationFileByteLimit,
            sha256: 'a' * 64,
            createdAt: createdAt,
          ),
          read: (o, n) async {
            calls++;
            return Uint8List(n);
          },
        ),
      );
      await expectLater(write(large), fails('backup_too_large'));
      await expectLater(
        write(List.filled(AttachmentBackupContainer.maxVersions + 1, s)),
        fails('backup_too_large'),
      );
      expect(calls, 0);
      expect(root.listSync(), isEmpty);
    },
  );
  test(
    'existing destination and publication races never overwrite an owner file',
    () async {
      await File(path).writeAsString('keep-existing');
      await expectLater(
        write([source('resume', data)]),
        fails('output_exists'),
      );
      expect(await File(path).readAsString(), 'keep-existing');
      final race = '${root.path}/race.aimbackup';
      await expectLater(
        write([
          AttachmentBackupSource(
            version('resume', data),
            read: (o, n) async {
              if (o == 0) await File(race).writeAsString('keep-race');
              return Uint8List.sublistView(data, o, o + n);
            },
          ),
        ], output: race),
        fails('output_exists'),
      );
      expect(await File(race).readAsString(), 'keep-race');
    },
  );
  test(
    'wrong key, corrupted page and both truncated forms fail before returning a reader',
    () async {
      await write([source('resume', data)]);
      await expectLater(
        AttachmentBackupContainer.openValidated(
          path,
          'aim-recovery-v1:${base64Url.encode(List.filled(32, 99))}',
        ),
        fails(),
      );
      final original = await File(path).readAsBytes();
      for (final name in ['tag', 'trailing-byte', 'page']) {
        final target = '${root.path}/$name.aimbackup';
        final changed = Uint8List.fromList(
          name == 'tag'
              ? original
              : name == 'page'
              ? original.sublist(0, original.length - 4096)
              : original.sublist(0, original.length - 1),
        );
        if (name == 'tag') changed[5200] ^= 1;
        await File(target).writeAsBytes(changed);
        await expectLater(
          AttachmentBackupContainer.openValidated(target, key),
          fails(),
        );
      }
      expectBytes(await File(path).readAsBytes(), original);
    },
  );

  final changes = <String, void Function(sqlite.Database)>{
    'missing chunk': (db) =>
        db.execute('DELETE FROM attachment_chunks WHERE chunk_index=1'),
    'extra unknown chunk': (db) =>
        db.execute("INSERT INTO attachment_chunks VALUES('other',1,0,x'01')"),
    'gap in numbering': (db) => db.execute(
      'UPDATE attachment_chunks SET chunk_index=9 WHERE chunk_index=0',
    ),
    'short body': (db) => db.execute(
      "UPDATE attachment_chunks SET body=x'01' WHERE chunk_index=0",
    ),
    'same-length digest mismatch': (db) => db.execute(
      'UPDATE attachment_chunks SET body=zeroblob(length(body)) WHERE chunk_index=0',
    ),
    'text body': (db) => db.execute(
      "UPDATE attachment_chunks SET body='12345678901234567' WHERE chunk_index=2",
    ),
    'oversized body': (db) => db.execute(
      'UPDATE attachment_chunks SET body=zeroblob(?) WHERE chunk_index=0',
      [AttachmentBackupContainer.chunkBytes + 1],
    ),
    'unknown object': (db) =>
        db.execute('CREATE VIEW extra AS SELECT payload FROM backup_snapshot'),
    'double version': (db) {
      final doc =
          jsonDecode(
                db
                        .select('SELECT payload FROM backup_snapshot')
                        .single
                        .values
                        .single
                    as String,
              )
              as Map;
      doc['version'] = 8.0;
      db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(doc)]);
    },
    'duplicate JSON key': (db) {
      final text =
          db.select('SELECT payload FROM backup_snapshot').single.values.single
              as String;
      db.execute('UPDATE backup_snapshot SET payload=?', [
        text.replaceFirst('"version":8', '"version":8,"version":8'),
      ]);
    },
    'missing nullable metadata': (db) {
      final doc =
          jsonDecode(
                db
                        .select('SELECT payload FROM backup_snapshot')
                        .single
                        .values
                        .single
                    as String,
              )
              as Map;
      final row = (doc['attachments'] as List).single as Map;
      row['unknown'] = row.remove('retiredAt');
      db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(doc)]);
    },
    'wrong declared identity': (db) {
      final doc =
          jsonDecode(
                db
                        .select('SELECT payload FROM backup_snapshot')
                        .single
                        .values
                        .single
                    as String,
              )
              as Map;
      (doc['attachments'] as List).single['attachmentId'] = 'changed';
      db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(doc)]);
    },
    'noncanonical schema': (db) =>
        db.execute('ALTER TABLE attachment_chunks ADD COLUMN extra TEXT'),
    'WAL journal mode': (db) => db.execute('PRAGMA journal_mode=WAL'),
  };
  for (final change in changes.entries) {
    test(
      'authenticated but malformed ${change.key} is rejected as a whole',
      () async {
        await write([source('resume', data)]);
        final db = open(path);
        try {
          change.value(db);
        } finally {
          db.close();
        }
        await expectLater(
          AttachmentBackupContainer.openValidated(path, key),
          fails(),
        );
      },
    );
  }
  test(
    'validated reader holds its transaction and close invalidates a partial stream',
    () async {
      await write([source('resume', data)]);
      final reader = await AttachmentBackupContainer.openValidated(path, key);
      final writer = open(path);
      try {
        writer.execute('PRAGMA busy_timeout=0');
        expect(
          () => writer.execute(
            'UPDATE attachment_chunks SET body=zeroblob(length(body)) WHERE chunk_index=0',
          ),
          throwsA(
            isA<sqlite.SqliteException>().having(
              (e) => e.resultCode,
              'SQLITE_BUSY',
              5,
            ),
          ),
        );
        expectBytes(
          await read(reader, InformationAttachmentRef('resume', 1)),
          data,
        );
        final iterator = StreamIterator(
          reader.readAttachment(InformationAttachmentRef('resume', 1)),
        );
        expect(await iterator.moveNext(), isTrue);
        reader.close();
        await expectLater(iterator.moveNext(), fails('backup_closed'));
        await iterator.cancel();
      } finally {
        writer.close();
        reader.close();
      }
      await expectLater(
        read(reader, InformationAttachmentRef('resume', 1)),
        fails('backup_closed'),
      );
    },
  );
  test(
    'complete reader refuses codec-only snapshot without domain rows',
    () async {
      await write([source('resume', data)]);
      final repository = await EncryptedInformationRepository.open(
        '${root.path}/legacy-reader',
        _Keys(),
      );
      try {
        await expectLater(
          repository.backups.inspect(path, key),
          fails('invalid_backup'),
        );
      } finally {
        await repository.close();
      }
    },
  );
}
