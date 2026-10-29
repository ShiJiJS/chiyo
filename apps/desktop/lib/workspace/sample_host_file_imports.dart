import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' show validateSshKnownHosts;
import 'workspace_source.dart';

/// In-memory file-import facts. No file system, network or production trust store.
class SampleHostFileImports {
  SampleHostFileImports({
    required this.readable,
    required this.beforeWrite,
    required this.changed,
    required this.version,
    required this.commitVersion,
    required this.pluginVersion,
    required this.pluginEnabled,
  });
  final Future<void> Function() readable;
  final void Function() beforeWrite, changed;
  final int Function() version, commitVersion, pluginVersion;
  final bool Function() pluginEnabled;
  final _files = <String, ({WorkspaceHostFile file, List<int> bytes})>{};
  final _operations = <String, WorkspaceHostImportReceipt>{};
  ({WorkspaceHostImportStatus status, List<int> bytes})? _confirmed;
  WorkspaceHostImportStatus? get current => _confirmed?.status;
  bool loseNextReply = false;

  List<WorkspaceHostFile> choices() {
    if (_files.length > 96) {
      throw const WorkspaceFailure('selection_busy', '待核对的文件过多，请先关闭已有表单。');
    }
    // A structurally valid, deliberately synthetic ed25519 public-key blob.
    final key = base64Encode([
      0,
      0,
      0,
      11,
      ...ascii.encode('ssh-ed25519'),
      0,
      0,
      0,
      32,
      ...List.generate(32, (i) => i),
    ]);
    final inputs = {
      '合成主机记录.known_hosts': utf8.encode(
        '# Synthetic public host keys only\n[demo-import.example]:2222 ssh-ed25519 $key\ndemo-second.example ssh-ed25519 $key\n',
      ),
      '格式错误的主机记录.known_hosts': utf8.encode(
        'demo-import.example this-is-not-a-key\n',
      ),
    };
    return [for (final input in inputs.entries) _stage(input.key, input.value)];
  }

  WorkspaceHostFile _stage(String name, List<int> bytes) {
    final file = WorkspaceHostFile(workspaceOperationId(), name, bytes.length);
    _files[file.selectionId] = (file: file, bytes: List.unmodifiable(bytes));
    return file;
  }

  void reset() {
    _confirmed = null;
    _files.clear();
    _operations.clear();
    loseNextReply = false;
  }

  void release(String id) => _files.remove(id);

  Future<WorkspaceHostImportPreview> preview(String id) async {
    await readable();
    if (!pluginEnabled()) {
      throw const WorkspaceFailure('unavailable', '请先启用服务器插件，再核对导入文件。');
    }
    final selection = _files[id];
    if (selection == null) {
      throw const WorkspaceFailure('selection_unavailable', '文件选择已失效，请重新选择。');
    }
    try {
      validateSshKnownHosts(selection.file.name, selection.bytes);
    } catch (_) {
      throw const WorkspaceFailure(
        'invalid_ssh_known_hosts',
        '主机记录格式无效，原文件记录保持不变。',
      );
    }
    final entries = <WorkspaceHostFileEntry>[];
    for (final raw in const LineSplitter().convert(
      utf8.decode(selection.bytes),
    )) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'\s+')),
          offset = line.startsWith('@') ? 1 : 0;
      final fingerprint = base64Encode(
        sha256.convert(base64Decode(parts[offset + 2])).bytes,
      ).replaceAll('=', '');
      entries.add(
        WorkspaceHostFileEntry(
          parts[offset],
          parts[offset + 1],
          'SHA256:$fingerprint',
          offset == 0 ? null : parts.first,
        ),
      );
    }
    return WorkspaceHostImportPreview(
      file: selection.file,
      digest: sha256.convert(selection.bytes).toString(),
      version: version(),
      pluginVersion: pluginVersion(),
      entries: entries,
      previous: current,
    );
  }

  Future<WorkspaceHostImportReceipt> apply(WorkspaceHostImportChange c) async {
    await readable();
    final p = c.preview;
    if (c.operationId.isEmpty) {
      throw const WorkspaceFailure('validation', '操作身份不能为空。');
    }
    if (_operations[c.operationId] case final old?) {
      if (!old.matches(c)) {
        throw const WorkspaceFailure(
          'operation_conflict',
          '同一操作不能用于另一份文件或核对范围。',
        );
      }
      return old;
    }
    final now = await preview(p.file.selectionId);
    if (now.version != p.version ||
        now.pluginVersion != p.pluginVersion ||
        now.digest != p.digest ||
        now.file.name != p.file.name ||
        now.entries.length != p.entries.length) {
      throw const WorkspaceFailure('conflict', '主机记录、文件或插件已变化，请重新读取并核对。');
    }
    beforeWrite();
    final result = WorkspaceHostImportStatus(
      name: now.file.name,
      digest: now.digest,
      entryCount: now.entries.length,
      version: commitVersion(),
    );
    final receipt = WorkspaceHostImportReceipt(
      operationId: c.operationId,
      selectionId: p.file.selectionId,
      expectedVersion: p.version,
      expectedPluginVersion: p.pluginVersion,
      result: result,
    );
    _confirmed = (
      status: result,
      bytes: List.unmodifiable(_files[p.file.selectionId]!.bytes),
    );
    _operations[c.operationId] = receipt;
    changed();
    if (loseNextReply) {
      loseNextReply = false;
      throw const WorkspaceFailure('unknown_outcome', '导入结果暂时无法确认，请先核对本次操作。');
    }
    return receipt;
  }

  Future<WorkspaceHostImportReceipt?> receipt(String id) async {
    await readable();
    return _operations[id];
  }
}
