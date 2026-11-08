import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_workspace/credential_file_selection.dart';
import 'package:info_workspace/credential_transport.dart';
import 'package:info_workspace/owner_workspace_credentials.dart';
import 'package:info_workspace/workspace_source.dart';

/// Entered only after owner authentication, inside the runtime's existing
/// serialization queue. Staging stays in private memory; committed materials
/// use the original encrypted repository and mutation receipts.
final class OwnerCredentialRoutes {
  OwnerCredentialRoutes(OwnerAccess owner, {Duration Function()? elapsed})
    : source = OwnerWorkspaceCredentials(owner),
      _elapsed = elapsed ?? _clock();
  final OwnerWorkspaceCredentials source;
  final Duration Function() _elapsed;
  static const stagingLifetime = Duration(minutes: 30);
  static Duration Function() _clock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final _uploads =
      <String, ({String digest, String candidateId, Duration until})>{};
  final _cancelled = <String, Duration>{};
  void dispose() {
    source.dispose();
    _uploads.clear();
    _cancelled.clear();
  }

  bool get needsCleanup =>
      _uploads.values.any((s) => s.until <= _elapsed()) ||
      _cancelled.values.any((until) => until <= _elapsed());
  Future<void> cleanup() async {
    final now = _elapsed();
    for (final entry in _uploads.entries.toList()) {
      if (entry.value.until > now) continue;
      await source.releaseCandidate(entry.value.candidateId);
      _uploads.remove(entry.key);
    }
    _cancelled.removeWhere((_, until) => until <= now);
  }

  String _operation(Object? raw) {
    if (raw is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(raw)) {
      throw const FormatException();
    }
    return raw;
  }

  Map<String, Object?> _uploaded(String candidateId, String digest) => {
    'candidate': credentialCandidateToJson(
      source.staging.candidate(candidateId),
    ),
    'inputHash': digest,
  };
  Future<Map<String, Object?>> upload(Map<String, dynamic> body) async {
    final file = body['form'] == 'file';
    final keys = {
      'operationId',
      'form',
      if (file) ...['filename', 'bytes'] else 'secret',
    };
    if (body.length != keys.length ||
        body.keys.any((k) => !keys.contains(k)) ||
        !{'file', 'string'}.contains(body['form']))
      throw const FormatException();
    final op = _operation(body['operationId']);
    if (_cancelled.containsKey(op))
      throw const WorkspaceFailure('selection_expired', '这次凭据输入已取消，请重新输入。');
    final List<int> bytes;
    final String? filename;
    if (file) {
      final encoded = body['bytes'] as String;
      if (encoded.length > ((1048576 + 2) ~/ 3) * 4)
        throw const FormatException();
      bytes = base64Decode(encoded);
      filename = body['filename'] as String;
    } else {
      bytes = utf8.encode(body['secret'] as String);
      filename = null;
    }
    if (bytes.isEmpty || bytes.length > (file ? 1048576 : 65536))
      throw const FormatException();
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              body['form'],
              filename,
              sha256.convert(bytes).toString(),
            ]),
          ),
        )
        .toString();
    final previous = _uploads[op];
    if (previous != null) {
      if (previous.digest != digest)
        throw const WorkspaceFailure('operation_conflict', '原操作编号不能用于另一份凭据输入。');
      return _uploaded(previous.candidateId, digest);
    }
    if (_uploads.length >= 512)
      throw const WorkspaceFailure('capacity', '请先完成或取消已有凭据输入。');
    final candidate = file
        ? source.staging.file(SelectedCredentialFile(filename!, bytes))
        : source.staging.string(body['secret'] as String);
    _uploads[op] = (
      digest: digest,
      candidateId: candidate.id,
      until: _elapsed() + stagingLifetime,
    );
    return _uploaded(candidate.id, digest);
  }

  Future<void> _cancel(String op) async {
    if (_cancelled.length >= 512 && !_cancelled.containsKey(op))
      throw const WorkspaceFailure('capacity', '待清理的凭据输入较多，请稍后重试。');
    _cancelled[op] = _elapsed() + stagingLifetime;
    final found = _uploads[op];
    if (found != null) await source.releaseCandidate(found.candidateId);
  }

  Future<(int, Object)> dispatch(
    String method,
    List<String> path,
    Map<String, dynamic>? body,
  ) async {
    await cleanup();
    if (path.length == 4 && path.last == 'inputs' && method == 'POST')
      return (200, await upload(body!));
    if (path.length == 5 && path[3] == 'inputs') {
      final op = _operation(path.last);
      if (method == 'DELETE') {
        await _cancel(op);
        return (200, {'status': 'ok'});
      }
      if (method == 'GET') {
        final selected = _uploads[op];
        if (selected == null || _cancelled.containsKey(op))
          return (404, {'error': 'selection_expired'});
        return (200, _uploaded(selected.candidateId, selected.digest));
      }
    }
    if (path.length == 5 && path[3] == 'candidates' && method == 'DELETE') {
      await source.releaseCandidate(path.last);
      return (200, {'status': 'ok'});
    }
    if (path.length == 4 && path.last == 'save' && method == 'POST') {
      return (
        200,
        credentialReceiptToJson(
          await source.save(credentialWriteFromJson(body)),
        ),
      );
    }
    if (path.length == 4 && path.last == 'enabled' && method == 'POST') {
      return (
        200,
        credentialReceiptToJson(
          await source.setEnabled(credentialToggleFromJson(body)),
        ),
      );
    }
    if (path.length == 5 && path[3] == 'operations' && method == 'GET') {
      final receipt = await source.receipt(path.last);
      return receipt == null
          ? (404, {'error': 'operation_not_found'})
          : (200, credentialReceiptToJson(receipt));
    }
    if (path.length == 4 && method == 'GET') {
      return (
        200,
        credentialDetailToJson(
          await source.read(
            WorkspaceRecordRef(WorkspaceRecordKind.credential, path.last),
          ),
        ),
      );
    }
    if (path.length == 5 && path.last == 'materials' && method == 'GET') {
      return (
        200,
        credentialMaterialsToJson(
          await source.materials(
            WorkspaceRecordRef(WorkspaceRecordKind.credential, path[3]),
          ),
        ),
      );
    }
    return (404, {'error': 'not_found'});
  }
}
