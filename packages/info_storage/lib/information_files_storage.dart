part of 'info_storage.dart';

extension _EncryptedInformationFileIntake on EncryptedInformationRepository {
  Future<InformationFileStagingUsage> _fileStagingUsage() async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      final row = await _db
          .customSelect(
            'SELECT count(*) AS files,coalesce(sum(byte_length),0) AS bytes '
            'FROM information_file_stages',
          )
          .getSingle();
      return InformationFileStagingUsage(
        row.read<int>('files'),
        row.read<int>('bytes'),
      );
    } on Object {
      throw const StorageFailure('attachment_stage_failed');
    }
  }

  Future<InformationFileStage> _stageInformationFileBytes({
    required String draftId,
    required String stageId,
    required String originalName,
    required String mediaType,
    required Uint8List bytes,
  }) async {
    if (_closed) throw const StorageFailure('library_closed');
    if (bytes.length > informationFileByteLimit) {
      throw const AccessFailure('attachment_too_large');
    }
    // Own bytes before the first await. Caller mutation cannot change a staged
    // BLOB after its immutable metadata/hash was computed.
    final ownedBytes = Uint8List.fromList(bytes);
    final stage = InformationFileStage.forBytes(
      id: stageId,
      draftId: draftId,
      originalName: originalName,
      mediaType: mediaType,
      bytes: ownedBytes,
    );
    try {
      return await _db.transaction(() async {
        final existing = await _db
            .customSelect(
              'SELECT draft_id,byte_length,metadata FROM information_file_stages '
              'WHERE id=?',
              variables: [Variable(stageId)],
            )
            .get();
        if (existing.isNotEmpty) {
          final row = existing.single;
          final previous = InformationFileStage.fromPrivateJson(
            jsonDecode(row.read<String>('metadata')) as Map<String, dynamic>,
          );
          if (previous.id != stageId ||
              previous.draftId != row.read<String>('draft_id') ||
              previous.byteLength != row.read<int>('byte_length')) {
            throw const AccessFailure('attachment_integrity_failed');
          }
          if (!previous.sameAs(stage)) {
            throw const AccessFailure('operation_conflict');
          }
          return previous;
        }
        final usage = await _fileStagingUsage();
        if (usage.files >= informationFileStageLimit ||
            usage.bytes + ownedBytes.length > informationFileStagingByteLimit) {
          throw const AccessFailure('attachment_capacity_exceeded');
        }
        await _db.customStatement(
          'INSERT INTO information_file_stages'
          '(id,draft_id,byte_length,metadata,body) VALUES(?,?,?,?,?)',
          [
            stage.id,
            stage.draftId,
            stage.byteLength,
            jsonEncode(stage.toPrivateJson()),
            ownedBytes,
          ],
        );
        return stage;
      });
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const StorageFailure('attachment_stage_failed');
    }
  }

  Future<void> _releaseInformationFileStage(
    String draftId,
    String? stageId,
  ) async {
    if (_closed) throw const StorageFailure('library_closed');
    try {
      await _db.transaction(
        () => _db.customStatement(
          'DELETE FROM information_file_stages WHERE draft_id=?'
          '${stageId == null ? '' : ' AND id=?'}',
          [draftId, if (stageId != null) stageId],
        ),
      );
    } on Object {
      throw const StorageFailure('attachment_stage_failed');
    }
  }
}
