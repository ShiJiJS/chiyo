part of 'info_storage.dart';

LibraryOrderSnapshot? _libraryOrderFromRows(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return null;
  if (rows.length != 1 || rows.single['id'] != 'current') {
    throw const FormatException('Invalid library order rows');
  }
  return LibraryOrderSnapshot.fromJson(
    decodeProtocolObject(
      rows.single['payload'] as String,
      maxBytes: AttachmentBackupContainer.maxPayloadBytes,
    ),
  );
}

void _validateBackupLibraryOrder(
  Map<String, List<Map<String, Object?>>> tables,
) {
  try {
    _libraryOrderFromRows(tables['library_order_state'] ?? const []);
  } on Object {
    throw const StorageFailure('invalid_backup');
  }
}

extension _EncryptedLibraryOrder on EncryptedInformationRepository {
  Future<LibraryOrderSnapshot?> _storedLibraryOrder() async =>
      _libraryOrderFromRows([
        for (final row
            in await _db
                .customSelect(
                  'SELECT id,payload FROM library_order_state ORDER BY rowid',
                )
                .get())
          row.data,
      ]);
  Future<void> _loadLibraryOrder() async {
    try {
      final order = await _storedLibraryOrder();
      if (order != null &&
          (await _db
                      .customSelect(
                        'SELECT version FROM library_format WHERE singleton=1',
                      )
                      .getSingle())
                  .read<int>('version') <
              _libraryOrderLibraryFormat) {
        throw const StorageFailure('unsupported_schema');
      }
      _libraryOrder = order;
    } on StorageFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('invalid_library_order');
    }
  }

  Future<void> _writeLibraryOrder(LibraryOrderSnapshot order) async {
    await _requireAdmissionFormat(_libraryOrderLibraryFormat);
    await _db.customStatement(
      'INSERT INTO library_order_state(id,payload) VALUES(\'current\',?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
      [jsonEncode(order.toJson())],
    );
  }
}
