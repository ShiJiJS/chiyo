import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/host_transport.dart';
import 'package:info_workspace/owner_workspace_hosts.dart';
import 'package:info_workspace/workspace_source.dart';

/// Owner-only trust management, using the original shared projection. Only
/// explicit public known_hosts bytes may be staged; the server probes no host.
final class OwnerHostRoutes {
  OwnerHostRoutes(OwnerAccess owner, {Duration Function()? elapsed})
    : source = OwnerWorkspaceHosts(owner: owner, changed: () {}),
      _elapsed = elapsed ?? _clock();
  final OwnerWorkspaceHosts source;
  final Duration Function() _elapsed;
  static const lifetime = Duration(minutes: 30);
  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  final _inputs =
      <String, ({String digest, WorkspaceHostFile file, Duration until})>{};
  final _cancelled = <String, Duration>{};
  String _id(Object? raw) {
    if (raw is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(raw))
      throw const FormatException();
    return raw;
  }

  bool get needsCleanup =>
      _inputs.values.any((e) => e.until <= _elapsed()) ||
      _cancelled.values.any((e) => e <= _elapsed());
  Future<void> cleanup() async {
    final now = _elapsed();
    for (final entry in _inputs.entries.toList()) {
      if (entry.value.until > now) continue;
      await source.releaseImport(entry.value.file.selectionId);
      _inputs.remove(entry.key);
    }
    _cancelled.removeWhere((_, until) => until <= now);
  }

  void dispose() {
    source.dispose();
    _inputs.clear();
    _cancelled.clear();
  }

  void _shape(Map<String, dynamic> j, Set<String> keys) {
    if (j.length != keys.length || !j.keys.toSet().containsAll(keys))
      throw const FormatException();
  }

  Map<String, Object?> _uploaded(WorkspaceHostFile file) => {
    'version': 1,
    'file': hostFileToJson(file),
  };
  Future<Map<String, Object?>> upload(Map<String, dynamic> j) async {
    _shape(j, {'version', 'operationId', 'name', 'bytes'});
    if (j['version'] != 1 ||
        j['name'] is! String ||
        j['bytes'] is! String ||
        (j['bytes'] as String).length > ((1048576 + 2) ~/ 3) * 4)
      throw const FormatException();
    final op = _id(j['operationId']);
    if (_cancelled.containsKey(op))
      throw const WorkspaceFailure('selection_expired', '这次文件选择已取消，请重新选择。');
    final bytes = base64Decode(j['bytes'] as String);
    if (bytes.isEmpty || bytes.length > 1048576) throw const FormatException();
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([j['name'], sha256.convert(bytes).toString()]),
          ),
        )
        .toString();
    final old = _inputs[op];
    if (old != null) {
      if (old.digest != digest)
        throw const WorkspaceFailure('operation_conflict', '原文件选择编号不能用于另一份内容。');
      return _uploaded(old.file);
    }
    if (_inputs.length >= 512)
      throw const WorkspaceFailure('selection_busy', '请先完成已有文件预览。');
    final file = await source.stage(j['name'] as String, bytes);
    _inputs[op] = (digest: digest, file: file, until: _elapsed() + lifetime);
    return _uploaded(file);
  }

  Future<void> _release(String selectionId) async {
    for (final entry
        in _inputs.entries
            .where((e) => e.value.file.selectionId == selectionId)
            .toList()) {
      if (_cancelled.length >= 512 && !_cancelled.containsKey(entry.key))
        throw const WorkspaceFailure('selection_busy', '请稍后重试文件清理。');
      _cancelled[entry.key] = _elapsed() + lifetime;
      _inputs.remove(entry.key);
    }
    await source.releaseImport(selectionId);
  }

  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    await cleanup();
    if (path.length == 3 && method == 'GET') {
      final imported = await source.importedFile();
      return (
        200,
        {
          'version': 1,
          'hosts': [for (final h in await source.load()) hostIdentityToJson(h)],
          'imported': imported == null
              ? null
              : hostImportStatusToJson(imported),
        },
      );
    }
    if (path.length == 4 && path.last == 'inputs' && method == 'POST')
      return (200, await upload(body!));
    if (path.length == 5 && path[3] == 'inputs' && method == 'GET') {
      final input = _inputs[_id(path.last)];
      return input == null
          ? (404, {'error': 'selection_not_found'})
          : (200, _uploaded(input.file));
    }
    if (path.length == 5 && path[3] == 'selections' && method == 'DELETE') {
      await _release(_id(path.last));
      return (200, {'status': 'released'});
    }
    if (path.length == 5 && path[3] == 'previews' && method == 'GET')
      return (
        200,
        {
          'version': 1,
          'preview': hostImportPreviewToJson(
            await source.previewImport(_id(path.last)),
          ),
        },
      );
    if (path.length == 4 && path.last == 'imports' && method == 'POST')
      return (
        200,
        hostImportReceiptToJson(
          await source.importFile(hostImportChangeFromJson(body!)),
        ),
      );
    if (path.length == 5 && path[3] == 'import-operations' && method == 'GET') {
      final receipt = await source.importReceipt(_id(path.last));
      return receipt == null
          ? (404, {'error': 'operation_not_found'})
          : (200, hostImportReceiptToJson(receipt));
    }
    if (path.length == 4 && path.last == 'read' && method == 'POST') {
      _shape(body!, {'version', 'target'});
      if (body['version'] != 1) throw const FormatException();
      return (
        200,
        {
          'version': 1,
          'host': hostIdentityToJson(
            await source.read(hostTargetFromJson(body['target'])),
          ),
        },
      );
    }
    if (path.length == 4 && path.last == 'changes' && method == 'POST')
      return (
        200,
        hostReceiptToJson(await source.change(hostChangeFromJson(body!))),
      );
    if (path.length == 5 && path[3] == 'operations' && method == 'GET') {
      final receipt = await source.receipt(_id(path.last));
      return receipt == null
          ? (404, {'error': 'operation_not_found'})
          : (200, hostReceiptToJson(receipt));
    }
    return (404, {'error': 'not_found'});
  }
}
