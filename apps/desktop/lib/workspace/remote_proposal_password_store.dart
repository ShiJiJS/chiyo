import 'dart:convert';
import 'package:info_core/info_core.dart' as core;
import 'package:info_remote/owner_client.dart';
import 'workspace_source.dart';

/// Trusted Host channel only. Private values never enter proposal DTOs or
/// ordinary mutation commands. Retry metadata contains no plaintext.
final class RemoteProposalPasswordStore {
  RemoteProposalPasswordStore(this.client);
  final OwnerClient client;
  final _pending = <(String, int), core.OwnerPasswordFillReceipt>{};
  final _knownAbsent = <(String, int)>{};
  String _path(String proposal) =>
      '/v1/owner/proposals/${Uri.encodeComponent(proposal)}/passwords';
  WorkspaceFailure _failure(Object error, {bool writing = false}) {
    if (error is WorkspaceFailure) return error;
    if (error is RemoteFailure) {
      if (error.code == 'invalid_credential_content') {
        return const WorkspaceFailure(
          'validation',
          '密码不能为空，不能超过65536字节或包含空字符。输入仍保留。',
        );
      }
      if ({
        'proposal_changed',
        'invalid_credential_input',
        'operation_conflict',
      }.contains(error.code)) {
        return const WorkspaceFailure('conflict', '提案或密码填写已变化，输入仍保留，请重新核对。');
      }
      if ({
        'unauthorized',
        'library_changed',
        'server_changed',
      }.contains(error.code)) {
        return const WorkspaceFailure(
          'library_changed',
          '连接身份或服务器已变化，密码没有交给其他服务器。',
        );
      }
    }
    return WorkspaceFailure(
      writing ? 'unknown_outcome' : 'unavailable',
      writing ? '密码填写结果尚未确认，输入仍保留，请核对原操作。' : '密码暂时无法读取，请检查连接后重试。',
    );
  }

  Future<String> read(String proposal, int version, String itemKey) async {
    try {
      final response = await client.request('POST', '${_path(proposal)}/read', {
        'version': version,
        'itemKey': itemKey,
      });
      final value = response['value'];
      if (response.length != 1 ||
          value is! String ||
          utf8.encode(value).length > 65536 ||
          value.contains('\x00')) {
        throw const FormatException();
      }
      return value;
    } catch (e) {
      throw _failure(e);
    }
  }

  core.OwnerPasswordFillReceipt _check(
    Object? response,
    core.OwnerPasswordFillReceipt expected,
  ) {
    final receipt = core.OwnerPasswordFillReceipt.fromPrivateJson(
      Map<String, dynamic>.from(response as Map),
    );
    if (jsonEncode(receipt.toPrivateJson()) !=
        jsonEncode(expected.toPrivateJson())) {
      throw const WorkspaceFailure(
        'unknown_outcome',
        '密码填写回执不匹配，输入仍保留，请核对原操作。',
      );
    }
    return receipt;
  }

  Future<core.OwnerPasswordFillReceipt?> reconcile(
    String proposal,
    int version,
  ) async {
    final key = (proposal, version), expected = _pending[(proposal, version)];
    if (expected == null) return null;
    try {
      final result = await client.request(
        'GET',
        '/v1/owner/proposals/password-operations/${Uri.encodeComponent(expected.operationId)}',
      );
      final receipt = _check(result['operation'], expected);
      _knownAbsent.remove(key);
      return receipt;
    } on RemoteFailure catch (e) {
      if (e.code == 'operation_not_found') {
        _knownAbsent.add(key);
        return null;
      }
      throw _failure(e, writing: true);
    } on Object catch (e) {
      throw _failure(e, writing: true);
    }
  }

  Future<core.OwnerPasswordFillReceipt> fill(
    String proposal,
    int version,
    Map<String, String> values,
  ) async {
    final frozen = Map<String, String>.unmodifiable(values);
    try {
      if (frozen.isEmpty || frozen.length > 20) throw const FormatException();
      for (final value in frozen.values) {
        core.CredentialImportInput.owner().withOwnerSecret(value);
      }
    } on Object {
      throw const WorkspaceFailure(
        'validation',
        '请填写完整的密码，内容不能超过65536字节或包含空字符。',
      );
    }
    final key = (proposal, version);
    var expected = _pending[key];
    if (expected != null &&
        expected.inputDigest !=
            core.OwnerPasswordFillReceipt.digest(
              expected.operationId,
              proposal,
              version,
              frozen,
            )) {
      if (!_knownAbsent.contains(key)) {
        throw const WorkspaceFailure(
          'unknown_outcome',
          '上次密码填写还未核对，暂不能替换这份输入。',
        );
      }
      _pending.remove(key);
      expected = null;
    }
    if (expected != null) {
      final prior = await reconcile(proposal, version);
      if (prior != null) return prior;
    } else {
      final op = workspaceOperationId();
      expected = core.OwnerPasswordFillReceipt(
        op,
        proposal,
        version,
        version + 1,
        core.OwnerPasswordFillReceipt.digest(op, proposal, version, frozen),
        frozen.keys.toList()..sort(),
      );
      _pending[key] = expected;
    }
    _knownAbsent.remove(key);
    try {
      final result = await client.request('POST', '${_path(proposal)}/fill', {
        'operationId': expected.operationId,
        'version': version,
        'values': frozen,
      });
      return _check(result['operation'], expected);
    } catch (error) {
      if (error is RemoteFailure &&
          const {
            'invalid_credential_content',
            'invalid_credential_input',
            'proposal_changed',
            'operation_conflict',
            'invalid_password_operation',
            'invalid_request',
            'unauthorized',
            'server_changed',
            'library_changed',
            'operation_capacity',
          }.contains(error.code)) {
        _pending.remove(key);
        throw _failure(error, writing: true);
      }
      // Often the commit succeeded and only the response disappeared. Query
      // automatically once, without resending or re-approving anything.
      try {
        final receipt = await reconcile(proposal, version);
        if (receipt != null) return receipt;
      } on Object {
        /* Preserve the original exact operation and input. */
      }
      throw _failure(error, writing: true);
    }
  }

  void clear(String proposal) {
    _pending.removeWhere((key, _) => key.$1 == proposal);
    _knownAbsent.removeWhere((key) => key.$1 == proposal);
  }

  void dispose() {
    _pending.clear();
    _knownAbsent.clear();
  }
}
