import 'dart:convert';
import 'dart:typed_data';
import 'package:info_core/info_core.dart' as core;
import '../credential_files.dart';
import 'workspace_source.dart';

/// Trusted Host state, never a generic workspace resource or portable record.
/// Closing clears buffers owned here; no claim is made about copies held by
/// the native editor, immutable Dart strings, OS memory or committed SQLCipher.
class OwnerCredentialStage {
  OwnerCredentialStage(this.metadata, List<int> bytes)
    : bytes = Uint8List.fromList(bytes);
  final WorkspaceCredentialCandidate metadata;
  final Uint8List bytes;
  bool formOwned = true;
  final operations = <String>{};
  void clear() => bytes.fillRange(0, bytes.length, 0);
}

class OwnerCredentialStaging {
  OwnerCredentialStaging(this.owner) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final core.OwnerLibraryScope _scope;
  final _stages = <String, OwnerCredentialStage>{};
  bool _closed = false;
  void check() {
    if (!_scope.isCurrent) {
      dispose();
      throw const WorkspaceFailure('library_changed', '资料库已替换，请重新输入凭据。');
    }
    if (_closed || !owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '凭据输入已关闭。');
    }
  }

  WorkspaceCredentialCandidate string(String secret) {
    final bytes = utf8.encode(secret);
    if (bytes.isEmpty || bytes.length > 65536 || secret.contains('\u0000')) {
      throw const WorkspaceFailure('validation', '字符串内容须为1–65536字节且不含空字符。');
    }
    return _add(WorkspaceCredentialForm.string, bytes, null);
  }

  WorkspaceCredentialCandidate file(SelectedCredentialFile file) {
    if (file.bytes.isEmpty ||
        file.bytes.length > 1048576 ||
        file.bytes.any((v) => v < 0 || v > 255) ||
        file.name.isEmpty ||
        file.name.length > 255 ||
        file.name.contains(RegExp(r'[/\\\x00]'))) {
      throw const WorkspaceFailure('validation', '凭据文件无效或超过1MiB，尚未保存。');
    }
    return _add(WorkspaceCredentialForm.file, file.bytes, file.name);
  }

  WorkspaceCredentialCandidate _add(
    WorkspaceCredentialForm form,
    List<int> bytes,
    String? filename,
  ) {
    check();
    if (_stages.length >= 16 ||
        _stages.values.fold(0, (n, s) => n + s.bytes.length) + bytes.length >
            16 * 1048576) {
      throw const WorkspaceFailure('capacity', '请先完成或取消已有的凭据输入。');
    }
    final isFile = form == WorkspaceCredentialForm.file;
    final metadata = WorkspaceCredentialCandidate(
      id: workspaceOperationId(),
      label: filename ?? '凭据字符串',
      form: form,
      format: isFile ? '凭据文件' : '凭据字符串',
      filename: filename,
      delivery: isFile
          ? WorkspaceCredentialDelivery.file
          : WorkspaceCredentialDelivery.environment,
      binding: isFile ? 'CREDENTIAL_FILE' : 'SERVICE_TOKEN',
    );
    _stages[metadata.id] = OwnerCredentialStage(metadata, bytes);
    return metadata;
  }

  OwnerCredentialStage claim(String id, String operationId) {
    check();
    final stage = _stages[id];
    if (stage == null ||
        (!stage.formOwned && !stage.operations.contains(operationId))) {
      throw const WorkspaceFailure('selection_expired', '凭据输入已失效，请重新输入或选择。');
    }
    if (stage.operations.isNotEmpty &&
        !stage.operations.contains(operationId)) {
      throw const WorkspaceFailure('busy', '这份凭据输入还有待核对的操作，请先核对原结果。');
    }
    stage.operations.add(operationId);
    return stage;
  }

  void release(String id) {
    final stage = _stages[id];
    if (stage == null) return;
    stage.formOwned = false;
    _discardUnused(id, stage);
  }

  void resolve(String operationId, {required bool committed}) {
    for (final entry in _stages.entries.toList()) {
      if (!entry.value.operations.remove(operationId)) continue;
      if (committed) {
        // The durable vault/receipt owns the result; this candidate cannot
        // silently become material for a new logical operation.
        entry.value.formOwned = false;
      }
      _discardUnused(entry.key, entry.value);
    }
  }

  void _discardUnused(String id, OwnerCredentialStage stage) {
    if (!stage.formOwned && stage.operations.isEmpty) {
      stage.clear();
      _stages.remove(id);
    }
  }

  void dispose() {
    _closed = true;
    for (final stage in _stages.values) {
      stage.clear();
    }
    _stages.clear();
  }
}
