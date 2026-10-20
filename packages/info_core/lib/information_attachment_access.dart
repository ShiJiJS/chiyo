part of 'info_core.dart';

extension OwnerInformationAttachments on OwnerAccess {
  Future<InformationAttachmentUsage> informationAttachmentUsage() =>
      _serialize(() async {
        if (!serviceAvailable) throw const AccessFailure('service_unavailable');
        return _attachments.informationAttachmentUsage();
      });
  Future<void> purgeInformationAttachments() =>
      _serialize(_purgeInformationAttachments);
  Future<void> _purgeInformationAttachments() async {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    if (_service._repository case final InformationAttachmentRepository repo) {
      // Failed snapshot cleanup leaves original bytes pinned.
      await _purgeRecycle();
      await _purgeRevisions();
      await repo.reconcileInformationAttachments(_service._clock().toUtc());
    }
  }

  /// Explicit owner Save As, separate from managed Agent deliveries.
  /// Existing files (including publication races) are never replaced.
  Future<void> exportInformationFile(
    InformationAttachmentRef ref,
    String path,
  ) => _serialize(() async {
    await _purgeInformationAttachments();
    final repo = _attachments;
    final generation = _service._libraryGeneration;
    Directory? staging;
    RandomAccessFile? handle;
    try {
      final output = File(path).absolute;
      if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const AccessFailure('output_exists');
      }
      await repo.withInformationAttachment(ref, (version, chunks) async {
        staging = await output.parent.createTemp('.info-file-export-');
        final temporary = File('${staging!.path}/original.partial');
        await temporary.create(exclusive: true);
        handle = await temporary.open(mode: FileMode.writeOnly);
        final result = _InformationFileDigest();
        final hash = sha256.startChunkedConversion(result);
        var length = 0;
        try {
          await for (final bytes in chunks) {
            length += bytes.length;
            if (bytes.length > 1024 * 1024 || length > version.byteLength) {
              throw const AccessFailure('attachment_integrity_failed');
            }
            hash.add(bytes);
            await handle!.writeFrom(bytes);
          }
        } finally {
          hash.close();
        }
        if (length != version.byteLength ||
            result.value?.toString() != version.sha256) {
          throw const AccessFailure('attachment_integrity_failed');
        }
        await handle!.flush();
        await handle!.close();
        handle = null;
      });
      // Publish only after the source transaction has successfully ended.
      if (!serviceAvailable || generation != _service._libraryGeneration) {
        throw const AccessFailure('service_unavailable');
      }
      try {
        file_publication.publishNewFile(
          File('${staging!.path}/original.partial').absolute.path,
          output.path,
        );
      } on Object {
        if (await FileSystemEntity.type(output.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const AccessFailure('output_exists');
        }
        throw const AccessFailure('file_export_failed');
      }
    } on AccessFailure {
      rethrow;
    } on Object {
      throw const AccessFailure('file_export_failed');
    } finally {
      try {
        await handle?.close();
      } on Object {
        /* Preserve the original failure. */
      }
      if (staging != null) {
        // Known output and our empty folder only; never recursive traversal.
        try {
          final file = File('${staging!.path}/original.partial');
          if (await file.exists()) {
            await file.delete();
          }
        } on Object {
          /* Keep a failed partial in the owner-selected folder. */
        }
        try {
          await staging!.delete();
        } on Object {
          /* No path diagnostics. */
        }
      }
    }
  });
}

final class _InformationFileDigest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) {
    this.value = value;
  }

  @override
  void close() {}
}
