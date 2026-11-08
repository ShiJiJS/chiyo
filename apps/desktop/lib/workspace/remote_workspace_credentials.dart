import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_remote/owner_client.dart';
import 'package:info_workspace/credential_transport.dart';
import 'package:info_workspace/history_transport.dart';
import '../credential_files.dart';
import 'unavailable_workspace_sources.dart';
import 'workspace_source.dart';

/// Dedicated trusted owner input and metadata adapter. No plaintext enters
/// WorkspaceCredentialWrite or ordinary detail/receipt projections.
class RemoteWorkspaceCredentials extends UnavailableWorkspaceCredential
    implements CredentialInputStaging {
  RemoteWorkspaceCredentials(this.client, {required this.changed});
  final OwnerClient client;
  final void Function() changed;
  static const _prefix = '/v1/owner/credentials';
  bool _closed = false;
  int _generation = 0;
  ({String op, String digest})? _pending;
  final _selected = <String>{};
  final _writes = <String, String>{};
  @override
  void check() {
    if (_closed) {
      throw const WorkspaceFailure('library_changed', '连接已关闭，请重新打开凭据。');
    }
  }

  WorkspaceFailure _failure(Object error, {bool writing = false}) {
    if (error is WorkspaceFailure) return error;
    if (error is RemoteFailure &&
        const {
          'conflict',
          'validation',
          'operation_conflict',
          'selection_expired',
          'capacity',
          'busy',
          'invalid_request',
          'unauthorized',
          'server_changed',
          'library_changed',
          'not_found',
        }.contains(error.code)) {
      return WorkspaceFailure(error.code, switch (error.code) {
        'selection_expired' => '凭据输入已失效，请重新输入或选择。',
        'conflict' || 'operation_conflict' => '凭据或原操作已变化，请先核对原结果。',
        'capacity' || 'busy' => '请先完成或取消已有凭据输入。',
        'unauthorized' ||
        'server_changed' ||
        'library_changed' => '连接身份或服务器已变化，请重新连接。',
        'not_found' => '凭据已回收或不存在。',
        _ => '请核对凭据名称、用途、版本、关联及输入材料。',
      }, fieldErrors: error.fieldErrors);
    }
    return WorkspaceFailure(
      writing ? 'unknown_outcome' : 'unavailable',
      writing ? '凭据操作结果尚未确认，请保留输入并核对原操作。' : '凭据暂时无法读取，请检查连接后重试。',
    );
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    check();
    try {
      final result = await action();
      check();
      return result;
    } catch (e) {
      throw _failure(e);
    }
  }

  String _record(WorkspaceRecordRef ref) {
    if (ref.kind != WorkspaceRecordKind.credential) {
      throw const WorkspaceFailure('invalid_reference', '请选择凭据。');
    }
    return '$_prefix/${Uri.encodeComponent(ref.id)}';
  }

  @override
  Future<WorkspaceCredentialDetail> read(WorkspaceRecordRef ref) => _read(
    () async =>
        credentialDetailFromJson(await client.request('GET', _record(ref))),
  );
  @override
  Future<WorkspaceCredentialMaterialHistory> materials(
    WorkspaceRecordRef ref,
  ) => _read(
    () async => credentialMaterialsFromJson(
      await client.request('GET', '${_record(ref)}/materials'),
    ),
  );
  @override
  Future<WorkspaceCredentialCandidate> string(String secret) async {
    final bytes = utf8.encode(secret);
    if (bytes.isEmpty || bytes.length > 65536 || secret.contains('\x00')) {
      throw const WorkspaceFailure('validation', '密码或凭据内容须为1–65536字节且不含空字符。');
    }
    return _upload({'form': 'string', 'secret': secret}, bytes);
  }

  @override
  Future<WorkspaceCredentialCandidate> file(
    SelectedCredentialFile selected,
  ) async {
    if (selected.bytes.isEmpty ||
        selected.bytes.length > 1048576 ||
        selected.name.isEmpty ||
        selected.name.length > 255 ||
        selected.name.contains(RegExp(r'[/\\\x00]'))) {
      throw const WorkspaceFailure('validation', '凭据文件无效或超过1MiB，尚未保存。');
    }
    return _upload({
      'form': 'file',
      'filename': selected.name,
      'bytes': base64Encode(selected.bytes),
    }, selected.bytes);
  }

  Future<WorkspaceCredentialCandidate> _upload(
    Map<String, Object?> body,
    List<int> bytes,
  ) async {
    check();
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              body['form'],
              body['filename'],
              sha256.convert(bytes).toString(),
            ]),
          ),
        )
        .toString();
    final previous = _pending;
    if (previous != null && previous.digest != digest) {
      throw const WorkspaceFailure('busy', '上一份凭据输入尚未核对，请先重试或取消。');
    }
    final op = previous?.op ?? workspaceOperationId();
    final generation = _generation;
    _pending = (op: op, digest: digest);
    try {
      Map<String, dynamic>? result;
      if (previous != null) {
        try {
          result = await client.request(
            'GET',
            '$_prefix/inputs/${Uri.encodeComponent(op)}',
          );
        } on RemoteFailure catch (e) {
          if (e.code != 'selection_expired') rethrow;
        }
      }
      // Reuse the exact input operation after confirmed absence; no new secret
      // or candidate replaces a result that is merely unknown.
      result ??= await client.request('POST', '$_prefix/inputs', {
        'operationId': op,
        ...body,
      });
      final candidate = credentialCandidateFromJson(result['candidate']);
      if (result['inputHash'] != digest) throw const FormatException();
      if (_closed || generation != _generation) {
        await client.request(
          'DELETE',
          '$_prefix/inputs/${Uri.encodeComponent(op)}',
        );
        throw const WorkspaceFailure('library_changed', '凭据输入已关闭，没有保存。');
      }
      _selected.add(candidate.id);
      _pending = null;
      return candidate;
    } catch (e) {
      if (e is RemoteFailure &&
          const {
            'selection_expired',
            'validation',
            'invalid_request',
            'capacity',
          }.contains(e.code) &&
          _pending?.op == op) {
        _pending = null;
      }
      throw _failure(e, writing: true);
    }
  }

  @override
  Future<void> cancelPending() async {
    _generation++;
    final pending = _pending;
    if (pending == null) return;
    await client.request(
      'DELETE',
      '$_prefix/inputs/${Uri.encodeComponent(pending.op)}',
    );
    if (_pending?.op == pending.op) _pending = null;
  }

  @override
  Future<void> release(String id) => releaseCandidate(id);
  @override
  Future<void> releaseCandidate(String candidateId) async {
    await client.request(
      'DELETE',
      '$_prefix/candidates/${Uri.encodeComponent(candidateId)}',
    );
    _selected.remove(candidateId);
  }

  Future<WorkspaceCredentialReceipt> _write(
    String action,
    WorkspaceCredentialCommand command,
    Map<String, Object?> body,
  ) async {
    check();
    final previous = _writes[command.operationId];
    if (previous != null && previous != command.commandDigest) {
      throw const WorkspaceFailure('conflict', '原操作编号不能用于另一份凭据修改。');
    }
    _writes[command.operationId] = command.commandDigest;
    try {
      final result = credentialReceiptFromJson(
        await client.request('POST', '$_prefix/$action', body),
      );
      if (result.commandDigest != command.commandDigest) {
        throw const FormatException();
      }
      _writes.remove(command.operationId);
      if (command is WorkspaceCredentialWrite && command.candidateId != null) {
        _selected.remove(command.candidateId);
      }
      changed();
      return result;
    } catch (e) {
      throw _failure(e, writing: true);
    }
  }

  @override
  Future<WorkspaceCredentialRecycled> readRecycled(String entryId) => _read(
    () async => recycledCredentialFromJson(
      await client.request(
        'GET',
        '$_prefix/recycled/${Uri.encodeComponent(entryId)}',
      ),
    ),
  );
  @override
  Future<WorkspaceCredentialReceipt> change(WorkspaceCredentialChange change) =>
      _write('changes', change, credentialLifecycleToJson(change));
  @override
  Future<WorkspaceCredentialReceipt> save(WorkspaceCredentialWrite write) =>
      _write('save', write, credentialWriteToJson(write));
  @override
  Future<WorkspaceCredentialReceipt> setEnabled(
    WorkspaceCredentialToggle change,
  ) => _write('enabled', change, credentialToggleToJson(change));
  @override
  Future<WorkspaceCredentialReceipt?> receipt(String operationId) async {
    check();
    try {
      final result = credentialReceiptFromJson(
        await client.request(
          'GET',
          '$_prefix/operations/${Uri.encodeComponent(operationId)}',
        ),
      );
      if (_writes[operationId] != null &&
          _writes[operationId] != result.commandDigest) {
        throw const WorkspaceFailure('unknown_outcome', '原凭据回执不匹配，请保留当前输入。');
      }
      _writes.remove(operationId);
      changed();
      return result;
    } on RemoteFailure catch (e) {
      if (e.code == 'operation_not_found') {
        _writes.remove(operationId);
        return null;
      }
      throw _failure(e, writing: true);
    } on Object catch (e) {
      throw _failure(e, writing: true);
    }
  }

  Future<void> dispose() async {
    _closed = true;
    final results = await Future.wait([
      Future<void>.sync(
        cancelPending,
      ).then<Object?>((_) => null, onError: (Object e) => e),
      for (final id in _selected.toList())
        releaseCandidate(
          id,
        ).then<Object?>((_) => null, onError: (Object e) => e),
    ]);
    // The server's bounded expiry still owns failed remote releases. Keeping
    // the exact pending operation permits an in-flight input to finish cancel.
    if (results.every((e) => e == null)) _selected.clear();
    _writes.clear();
  }
}
