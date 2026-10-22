part of 'info_core.dart';

/// Opaque owner form lifetime. Staging does not create an information item.
final class InformationFileDraft {
  InformationFileDraft._(this._owner, this._generation, this.id);
  final OwnerAccess _owner;
  final int _generation;
  final String id;
  bool _active = true;
}

extension OwnerInformationFileIntake on OwnerAccess {
  InformationFileStagingRepository get _fileStages {
    if (_service._repository case final InformationFileStagingRepository repo) {
      return repo;
    }
    throw const AccessFailure('unsupported_capability');
  }

  Future<InformationFileDraft> beginInformationFileDraft() =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        // Check support before returning a form handle.
        _fileStages;
        // Restore invalidates old forms. Reclaim stale reservations before a
        // new form checks its quota, including synthetic repository fixtures.
        for (final old in _informationFileDrafts.values.toList()) {
          if (old._generation != _service._libraryGeneration) {
            await _fileStages.releaseInformationDraft(old.id);
            old._active = false;
            _informationFileDrafts.remove(old.id);
          }
        }
        if (_informationFileDrafts.length >= 32) {
          throw const AccessFailure('attachment_capacity_exceeded');
        }
        final draft = InformationFileDraft._(
          this,
          _service._libraryGeneration,
          _service._secret(),
        );
        _informationFileDrafts[draft.id] = draft;
        return draft;
      });

  void _checkInformationFileDraft(InformationFileDraft draft) {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    if (!identical(draft._owner, this) ||
        !draft._active ||
        !identical(_informationFileDrafts[draft.id], draft) ||
        draft._generation != _service._libraryGeneration) {
      throw const AccessFailure('stage_unavailable');
    }
  }

  /// The source path remains in this owner call only, never in the descriptor.
  /// A failed replacement leaves the previous stage and every other form field.
  Future<InformationFileStage> stageInformationFile(
    InformationFileDraft draft,
    String sourcePath, {
    String mediaType = 'application/octet-stream',
  }) => _serialize(() async {
    _checkInformationFileDraft(draft);
    await _purgeInformationAttachments();
    final file = File(sourcePath);
    final name = file.uri.pathSegments.lastOrNull ?? '';
    // Validate display metadata before reading or reserving any encrypted row.
    InformationFileStage(
      id: 'check',
      draftId: draft.id,
      originalName: name,
      mediaType: mediaType,
      byteLength: 0,
      sha256: '0' * 64,
    );
    final bytes = await _readInformationFileSource(file);
    _checkInformationFileDraft(draft);
    final stage = await _fileStages.stageInformationBytes(
      draftId: draft.id,
      stageId: _service._secret(),
      originalName: name,
      mediaType: mediaType,
      bytes: bytes,
    );
    // close() may have begun while the encrypted write was awaited. Its queued
    // draft cleanup owns that row; do not return a usable stage after shutdown.
    _checkInformationFileDraft(draft);
    return stage;
  });

  Future<void> releaseInformationStage(
    InformationFileDraft draft,
    InformationFileStage stage,
  ) => _serialize(() async {
    _checkInformationFileDraft(draft);
    if (stage.draftId != draft.id) {
      throw const AccessFailure('stage_unavailable');
    }
    await _fileStages.releaseInformationStage(draft.id, stage.id);
  });

  Future<void> releaseInformationFileDraft(InformationFileDraft draft) =>
      _serialize(() async {
        if (!identical(draft._owner, this)) {
          throw const AccessFailure('stage_unavailable');
        }
        if (!draft._active) return;
        // A stale pre-restore form can still cancel its own rows, never stage.
        await _fileStages.releaseInformationDraft(draft.id);
        draft._active = false;
        _informationFileDrafts.remove(draft.id);
      });

  Future<void> _releaseAllInformationFileDrafts() {
    // Keep the existing shutdown behavior when no file form owns resources.
    // Queuing an empty cleanup could otherwise wait behind an unrelated write
    // (and cross Flutter's real/fake async zones during ordinary widget close).
    if (_informationFileDrafts.isEmpty) return Future.value();
    return _serialize(() async {
      for (final draft in _informationFileDrafts.values.toList()) {
        await _fileStages.releaseInformationDraft(draft.id);
        draft._active = false;
        _informationFileDrafts.remove(draft.id);
      }
    });
  }
}

Future<Uint8List> _readInformationFileSource(File file) async {
  RandomAccessFile? reader;
  try {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const AccessFailure('file_read_failed');
    }
    final before = await file.stat();
    if (before.size > informationFileByteLimit) {
      throw const AccessFailure('attachment_too_large');
    }
    reader = await file.open();
    if (await reader.length() != before.size) {
      throw const AccessFailure('file_changed');
    }
    final buffer = BytesBuilder(copy: false);
    while (true) {
      final chunk = await reader.read(
        min(64 * 1024, informationFileByteLimit + 1 - buffer.length),
      );
      if (chunk.isEmpty) break;
      buffer.add(chunk);
      if (buffer.length > informationFileByteLimit) {
        throw const AccessFailure('attachment_too_large');
      }
    }
    final after = await file.stat();
    if (await reader.length() != before.size ||
        buffer.length != before.size ||
        after.type != FileSystemEntityType.file ||
        before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed) {
      throw const AccessFailure('file_changed');
    }
    return buffer.takeBytes();
  } on FileSystemException {
    // Paths and OS exception messages must not become public error text.
    throw const AccessFailure('file_read_failed');
  } finally {
    await reader?.close();
  }
}
