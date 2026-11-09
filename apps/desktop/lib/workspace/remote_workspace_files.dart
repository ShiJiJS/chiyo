import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/file_transport.dart';
import 'package:info_workspace/workspace_transport.dart';
import '../information_files.dart';
import 'workspace_attachment_renderer.dart';
import 'workspace_source.dart';

/// Device-only picker and renderer; all record/attachment versions live on the
/// host. A lost upload retains its exact operation until that outcome resolves.
class RemoteWorkspaceFiles {
  RemoteWorkspaceFiles(
    this.client, {
    required this.changed,
    this.picker = const NativeInformationFilePicker(),
    this.renderer = const WorkspaceAttachmentRenderer(),
  });
  final OwnerClient client;
  final void Function() changed;
  final InformationFilePicker picker;
  final WorkspaceAttachmentRenderer renderer;
  final _selected = <String>{};
  ({String op, Map<String, Object?> body})? _pending;
  bool _closed = false, _choosing = false;
  void _check() {
    if (_closed) {
      throw const WorkspaceFailure('library_changed', '连接已关闭，请重新打开文件。');
    }
  }

  WorkspaceFailure _failure(Object error, {bool writing = false}) {
    if (error is WorkspaceFailure) return error;
    if (error is core.AccessFailure) {
      return WorkspaceFailure(error.status, informationFileError(error));
    }
    if (error is RemoteFailure) {
      if (const {
        'conflict',
        'validation',
        'operation_conflict',
        'selection_expired',
        'version_conflict',
        'stage_unavailable',
        'attachment_missing',
        'invalid_request',
        'unauthorized',
        'server_changed',
        'library_changed',
        'invalid_information_file',
        'attachment_too_large',
        'capacity',
        'busy',
      }.contains(error.code)) {
        return WorkspaceFailure(error.code, switch (error.code) {
          'conflict' || 'version_conflict' => '资料或文件版本已变化，请重新读取后核对。',
          'selection_expired' || 'stage_unavailable' => '文件选择已失效，请重新选择。',
          'operation_conflict' => '原操作编号不能用于其他文件或内容。',
          'capacity' || 'busy' => '请先完成或取消已有文件操作，稍后重试。',
          'attachment_too_large' => '文件超过支持的大小，请选择较小的文件。',
          'unauthorized' || 'server_changed' => '连接身份或服务器已变化，请重新连接。',
          _ => '文件操作未完成，请核对文件和当前资料。',
        }, fieldErrors: error.fieldErrors);
      }
    }
    return WorkspaceFailure(
      writing ? 'unknown_outcome' : 'unavailable',
      writing ? '文件操作结果尚未确认，请先核对原操作，不要重复添加。' : '文件暂时无法读取，请检查服务器连接后重试。',
    );
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    _check();
    try {
      return await action();
    } catch (e) {
      throw _failure(e);
    }
  }

  Future<T> _write<T>(Future<T> Function() action) async {
    _check();
    try {
      final result = await action();
      changed();
      return result;
    } catch (e) {
      throw _failure(e, writing: true);
    }
  }

  WorkspaceFileCandidate _accept(Map<String, dynamic> response) {
    final pending = _pending!;
    final candidate = fileCandidateFromJson(response['candidate']);
    final bytes = base64Decode(pending.body['bytes'] as String);
    if (candidate.filename != pending.body['originalName'] ||
        candidate.mediaType != pending.body['mediaType'] ||
        candidate.byteLength != bytes.length ||
        response['sha256'] != sha256.convert(bytes).toString()) {
      throw const FormatException('Mismatched uploaded file');
    }
    _selected.add(candidate.selectionId);
    _pending = null;
    return candidate;
  }

  Future<WorkspaceFileCandidate?> pick() async {
    _check();
    if (_choosing) throw const WorkspaceFailure('busy', '请先完成当前文件选择。');
    _choosing = true;
    try {
      if (_pending == null) {
        final path = await picker.choose();
        _check();
        if (path == null) return null;
        final bytes = await core.readInformationFileSource(path);
        _check();
        final op = workspaceFileOperationId();
        _pending = (
          op: op,
          body: {
            'operationId': op,
            'originalName': File(path).uri.pathSegments.last,
            'mediaType': informationFileMediaType(path),
            'bytes': base64Encode(bytes),
          },
        );
      }
      final pending = _pending!;
      try {
        // Reuse the same operation on a subsequent explicit retry. The server
        // cannot turn it into a second selection with different content.
        final response = await client.request(
          'POST',
          '/v1/owner/files/uploads',
          pending.body,
        );
        _check();
        return _accept(response);
      } catch (error) {
        try {
          final response = await client.request(
            'GET',
            '/v1/owner/files/uploads/${Uri.encodeComponent(pending.op)}',
          );
          _check();
          return _accept(response);
        } on RemoteFailure catch (lookup) {
          if (lookup.code == 'operation_not_found' &&
              error is RemoteFailure &&
              const {
                'invalid_request',
                'validation',
                'selection_expired',
                'operation_conflict',
                'attachment_too_large',
                'invalid_information_file',
                'capacity',
                'busy',
              }.contains(error.code)) {
            _pending = null;
          }
        } on Object {
          /* No receipt is not the same as a failed receipt read. */
        }
        throw _failure(error, writing: true);
      }
    } catch (e) {
      throw _failure(e, writing: _pending != null);
    } finally {
      _choosing = false;
    }
  }

  Future<void> release(String selectionId) async {
    try {
      await client.request(
        'DELETE',
        '/v1/owner/files/selections/${Uri.encodeComponent(selectionId)}',
      );
      _selected.remove(selectionId);
    } catch (e) {
      throw _failure(e, writing: true);
    }
  }

  void committed(Iterable<String> selectionIds) =>
      _selected.removeAll(selectionIds);

  Future<WorkspaceFileHistory> history(WorkspaceRecordRef record, String key) =>
      _read(
        () async => fileHistoryFromJson(
          await client.request('POST', '/v1/owner/files/history', {
            'record': recordRefToJson(record),
            'fieldKey': key,
          }),
        ),
      );
  Future<WorkspaceFileOriginal> original(
    WorkspaceRecordRef record,
    String key,
    int? version,
  ) => _read(() async {
    final original = fileOriginalFromJson(
      await client.request('POST', '/v1/owner/files/read', {
        'record': recordRefToJson(record),
        'fieldKey': key,
        'version': version,
      }),
    );
    if (version != null && original.file.ref.version != version) {
      throw const FormatException('Mismatched original version');
    }
    return original;
  });
  Future<WorkspaceFilePreview> preview(
    WorkspaceRecordRef record,
    String key, {
    int? version,
    int page = 0,
  }) => _read(() async {
    final content = await original(record, key, version);
    return renderer.renderContent(content.file, content.bytes, page: page);
  });
  Future<WorkspaceRecordRef> importFile(WorkspaceFileImport input) =>
      _write(() async {
        final response = await client.request(
          'POST',
          '/v1/owner/files/import',
          fileImportToJson(input),
        );
        final record = recordRefFromJson(response['record']),
            receipt = fileReceiptFromJson(response['receipt']);
        if (receipt.record != record || receipt.commandDigest != input.digest) {
          throw const FormatException('Mismatched file import');
        }
        _selected.remove(input.selectionId);
        return record;
      });
  Future<WorkspaceFileRef> change(WorkspaceFileChange change) =>
      _write(() async {
        final receipt = fileReceiptFromJson(
          await client.request(
            'POST',
            '/v1/owner/files/changes',
            fileChangeToJson(change),
          ),
        );
        if (receipt.record != change.record ||
            receipt.commandDigest != change.digest ||
            receipt.file == null) {
          throw const FormatException('Mismatched file change');
        }
        if (change.selectionId != null) _selected.remove(change.selectionId);
        return receipt.file!;
      });
  Future<WorkspaceFileOperationReceipt?> receipt(String id) => _read(() async {
    try {
      return fileReceiptFromJson(
        await client.request(
          'GET',
          '/v1/owner/files/operations/${Uri.encodeComponent(id)}',
        ),
      );
    } on RemoteFailure catch (e) {
      if (e.code == 'operation_not_found') return null;
      rethrow;
    }
  });
  Future<void> dispose() async {
    _closed = true;
    final pending = _pending;
    _pending = null;
    if (pending != null || _selected.isNotEmpty) {
      try {
        await client.request('POST', '/v1/owner/files/release', {
          'uploads': [if (pending != null) pending.op],
          'selections': _selected.toList(),
        });
      } on Object {
        /* Host sweeps abandoned encrypted uploads after their staging lifetime. */
      }
    }
    _selected.clear();
  }
}
