export 'package:info_workspace/information_file_messages.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'information_editor_draft.dart';

/// Paths only cross this local picker/Owner boundary, never the form payload.
abstract interface class InformationFilePicker {
  Future<String?> choose();
  Future<String?> saveAs(String originalName);
}

class InformationExportStaging {
  const InformationExportStaging(this.directory, this.token);
  final String directory, token;
}

/// A Save panel grants its selected file, not arbitrary sibling paths. The
/// native provider owns a same-volume replacement directory for publication.
abstract interface class InformationExportStagingProvider {
  Future<InformationExportStaging?> prepareExport(String output);
  Future<void> releaseExport(InformationExportStaging staging);
}

class NativeInformationFilePicker
    implements InformationFilePicker, InformationExportStagingProvider {
  const NativeInformationFilePicker();
  static const _channel = MethodChannel('agent_info_manage/backup_files');
  @override
  Future<String?> choose() =>
      _channel.invokeMethod<String>('informationFileInput');
  @override
  Future<String?> saveAs(String originalName) =>
      _channel.invokeMethod<String>('informationFileOutput', originalName);
  @override
  Future<InformationExportStaging?> prepareExport(String output) async {
    if (!Platform.isMacOS) return null;
    final value = await _channel.invokeMapMethod<String, String>(
      'prepareInformationStaging',
      output,
    );
    if (value?['directory'] == null || value?['token'] == null) {
      throw const AccessFailure('file_export_failed');
    }
    return InformationExportStaging(value!['directory']!, value['token']!);
  }

  @override
  Future<void> releaseExport(InformationExportStaging staging) =>
      _channel.invokeMethod<void>('releaseInformationStaging', staging.token);
}

/// Owns one real form lifetime. All operations finish before cancellation; a
/// failed save retains its stages and exact operation ID for an explicit retry.
class OwnerInformationEditorSession {
  OwnerInformationEditorSession(this.owner, this.files);
  final OwnerAccess owner;
  final InformationFilePicker files;
  InformationFileDraft? _draft;
  Future<void> _tail = Future.value();
  Future<void>? _closing;
  bool _closed = false;
  String? _lastInput;
  int _operation = 0;

  Future<T> _run<T>(Future<T> Function() action) {
    if (_closed || _closing != null) {
      return Future.error(const AccessFailure('stage_unavailable'));
    }
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<InformationFileDraft> _form() async =>
      _draft ??= await owner.beginInformationFileDraft();

  Future<bool> choose(EditableInformationField field) => _run(() async {
    final path = await files.choose();
    if (path == null) return false;
    final form = await _form();
    final next = await owner.stageInformationFile(
      form,
      path,
      mediaType: informationFileMediaType(path),
    );
    final previous = field.stage;
    if (previous != null) {
      try {
        await owner.releaseInformationStage(form, previous);
      } catch (_) {
        // A failed replacement preserves the previous visible choice. The
        // whole form still owns any stage whose release could not complete.
        try {
          await owner.releaseInformationStage(form, next);
        } catch (_) {
          /* close/reset retains responsibility for this reservation. */
        }
        rethrow;
      }
    }
    field.stage = next;
    return true;
  });

  Future<void> release(EditableInformationField field) => _run(() async {
    final stage = field.stage;
    if (stage == null) return;
    await owner.releaseInformationStage(await _form(), stage);
    field.stage = null;
  });

  Future<void> reset() => _run(() async {
    if (_draft case final form?) {
      await owner.releaseInformationFileDraft(form);
      _draft = null;
      _lastInput = null;
    }
  });

  Future<InformationItem> save(InformationEditorDraft draft) => _run(() async {
    final input = draft.completeInput;
    final encoded = jsonEncode(input.toPrivateJson());
    if (encoded != _lastInput) {
      _lastInput = encoded;
      _operation++;
    }
    return owner.commitInformationDraft(
      await _form(),
      'save-$_operation',
      input,
    );
  });

  Future<void> close() {
    if (_closed) return Future.value();
    if (_closing case final closing?) return closing;
    return _closing = _tail
        .then((_) async {
          if (_draft case final form?) {
            await owner.releaseInformationFileDraft(form);
            _draft = null;
          }
          _closed = true;
        })
        .whenComplete(() => _closing = null);
  }
}

String informationFileMediaType(String path) => switch (path
    .split(RegExp(r'[/\\]'))
    .last
    .split('.')
    .last
    .toLowerCase()) {
  'pdf' => 'application/pdf',
  'docx' =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'doc' => 'application/msword',
  'txt' || 'md' => 'text/plain',
  'png' => 'image/png',
  'webp' => 'image/webp',
  'jpg' || 'jpeg' => 'image/jpeg',
  _ => 'application/octet-stream',
};

String informationFileSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
